"""Offline bootstrap checks and actual loopback routing; no real provider calls."""

from contextlib import redirect_stderr, redirect_stdout
from datetime import datetime, timedelta, timezone
import importlib
import io
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from uuid import uuid4

from aiohttp import ClientSession, web
from aiohttp.test_utils import TestServer
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import run_subscription_gateway as entry
from subscription_environments import SubscriptionEnvironments
from subscription_gateway import CommercialGatewaySettings, create_subscription_gateway
from test_gateway import decision, explanation
from test_subscription_environments import services, hint
from test_subscription_gateway import decision_response, good_stream


class SubscriptionBootstrapTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="pinpin-commercial-bootstrap-")
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.roots = self.directory / "provisioned-roots"
        self.roots.mkdir()
        key = ec.generate_private_key(ec.SECP256R1())
        name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "Synthetic bootstrap fixture only")])
        now = datetime.now(timezone.utc)
        cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(key.public_key())
                .serial_number(1).not_valid_before(now-timedelta(days=1)).not_valid_after(now+timedelta(days=1))
                .add_extension(x509.BasicConstraints(ca=True, path_length=None), True).sign(key, hashes.SHA256()))
        (self.roots / "fixture.der").write_bytes(cert.public_bytes(serialization.Encoding.DER))
        self.database_directory = self.directory / "commercial-state"
        self.environment = {"BEATAPI_API_KEY": "fixture-beat-secret", "PINPIN_COMMERCIAL_API_KEY": "fixture-commercial-secret",
            "PINPIN_APP_APPLE_ID": "1234", "PINPIN_APPLE_ROOTS_DIR": str(self.roots),
            "PINPIN_SUBSCRIPTION_DB_DIR": str(self.database_directory)}

    def test_import_and_check_config_do_not_create_state_or_call_network(self):
        with patch.dict(os.environ, {}, clear=True), patch("sqlite3.connect", side_effect=AssertionError("database during import")):
            importlib.reload(entry)
        output = io.StringIO()
        with patch.dict(os.environ, self.environment, clear=True), redirect_stdout(output), \
                patch("sqlite3.connect", side_effect=AssertionError("database during check")), \
                patch("appstoreserverlibrary.signed_data_verifier.requests.post", side_effect=AssertionError("network during check")), \
                patch.object(entry, "build_application", side_effect=AssertionError("application during check")):
            self.assertEqual(entry.main(["--check-config"]), 0)
        self.assertFalse(self.database_directory.exists())
        self.assertNotIn("secret", output.getvalue())
        self.assertEqual(entry.load_config(self.environment).port, 8790)

    def test_missing_configuration_fails_with_field_name_and_no_secret_values(self):
        for name in self.environment:
            environment = {key: value for key, value in self.environment.items() if key != name}
            environment.update({"AGENT_API_KEY": "private-plan-secret", "PINPIN_ACCESS_TOKEN": "legacy-shared-secret"})
            error = io.StringIO()
            with patch.dict(os.environ, environment, clear=True), redirect_stderr(error):
                self.assertEqual(entry.main(["--check-config"]), 2)
            self.assertIn(name, error.getvalue())
            for value in self.environment.values():
                self.assertNotIn(value, error.getvalue())
            self.assertNotIn("private-plan-secret", error.getvalue())
            self.assertNotIn("legacy-shared-secret", error.getvalue())

    def test_check_config_runs_as_cli_without_creating_database_directory(self):
        command = [sys.executable, str(Path(entry.__file__)), "--check-config"]
        environment = {**self.environment, "PATH": os.environ.get("PATH", ""), "PYTHONDONTWRITEBYTECODE": "1"}
        result = subprocess.run(command, env=environment, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Configuration valid", result.stdout)
        self.assertFalse(self.database_directory.exists())
        del environment["PINPIN_COMMERCIAL_API_KEY"]
        environment["AGENT_API_KEY"] = "fixture-private-plan-secret"
        result = subprocess.run(command, env=environment, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 2)
        self.assertIn("PINPIN_COMMERCIAL_API_KEY", result.stderr)
        self.assertNotIn("secret", result.stdout+result.stderr)

    def test_invalid_app_id_roots_port_and_linked_database_fail_offline(self):
        for name, value in (("PINPIN_APP_APPLE_ID", "0"), ("PINPIN_APP_APPLE_ID", "9"*5000),
                            ("PINPIN_SUBSCRIPTION_PORT", "0"), ("PINPIN_SUBSCRIPTION_PORT", "65536")):
            with self.assertRaises(entry.ConfigurationError):
                entry.load_config({**self.environment, name: value})
        (self.roots / "fixture.der").write_bytes(b"not a CA")
        with self.assertRaises(entry.ConfigurationError):
            entry.load_config(self.environment)
        self.assertFalse(self.database_directory.exists())

    async def test_runtime_build_uses_dual_private_state_and_fixed_loopback_binding(self):
        config = entry.load_config(self.environment)
        previous = os.umask(0o022)
        try:
            app = entry.build_application(config)
            server = TestServer(app)
            await server.start_server()
            try:
                self.assertEqual(stat.S_IMODE(self.database_directory.stat().st_mode), 0o700)
                for name in entry.DATABASE_NAMES:
                    self.assertEqual(stat.S_IMODE((self.database_directory/name).stat().st_mode), 0o600)
                async with ClientSession() as client:
                    response = await client.get(server.make_url("/pinpin/health"))
                    self.assertEqual(response.status, 200)
                    await response.read()
                    response = await client.get(server.make_url("/ping/health"))
                    self.assertEqual(response.status, 404)
                    await response.read()
            finally:
                await server.close()
            with patch.dict(os.environ, self.environment, clear=True), patch.object(entry, "web") as web_module:
                with patch.object(entry, "build_application", return_value="application"):
                    self.assertEqual(entry.main([]), 0)
                options = web_module.run_app.call_args.kwargs
                self.assertEqual((options["host"], options["port"], options["access_log"], options["print"]),
                                 ("127.0.0.1", 8790, None, None))
        finally:
            os.umask(previous)

    def test_config_rejects_database_symlinks_and_hardlinks_before_mutation(self):
        self.database_directory.mkdir()
        production = self.database_directory / entry.DATABASE_NAMES[0]
        sandbox = self.database_directory / entry.DATABASE_NAMES[1]
        production.write_bytes(b"untouched fixture")
        sandbox.symlink_to(production)
        with self.assertRaises(entry.ConfigurationError):
            entry.load_config(self.environment)
        sandbox.unlink()
        os.link(production, sandbox)
        with self.assertRaises(entry.ConfigurationError):
            entry.load_config(self.environment)
        self.assertEqual(production.read_bytes(), b"untouched fixture")


class SubscriptionPrefixHTTPTests(unittest.IsolatedAsyncioTestCase):
    async def test_commercial_prefix_routes_every_endpoint_and_rejects_legacy_paths_or_token(self):
        with tempfile.TemporaryDirectory(prefix="pinpin-commercial-prefix-") as directory:
            (production, prod_app), (sandbox, _) = services(directory)
            router = SubscriptionEnvironments(production=production, sandbox=sandbox)
            calls = []
            async def upstream(request):
                calls.append(request.path)
                if request.path == "/decision":
                    return web.json_response(decision_response(await request.json()))
                return web.Response(body=good_stream(), content_type="text/event-stream")
            upstream_app = web.Application()
            upstream_app.router.add_post("/{route}", upstream)
            upstream_server = TestServer(upstream_app)
            await upstream_server.start_server()
            try:
                urls = tuple(str(upstream_server.make_url("/"+route)) for route in ("decision", "explanation"))
                server = TestServer(create_subscription_gateway(CommercialGatewaySettings("fixture", "fixture"), router,
                                                               prefix="/pinpin/v1", _test_upstreams=urls))
                await server.start_server()
                try:
                    async with ClientSession() as client:
                        async def request(method, path, **kwargs):
                            response = await client.request(method, server.make_url(path), **kwargs)
                            return response.status, await response.json()
                        base = "/pinpin/v1"
                        self.assertEqual((await request("GET", "/pinpin/health"))[0], 200)
                        status, session = await request("POST", base+"/subscription/session", json={"signed_app_transaction": prod_app})
                        self.assertEqual(status, 200)
                        headers = {"Authorization": "Bearer "+session["access_token"]}
                        self.assertEqual((await request("GET", base+"/subscription/state", headers=headers))[0], 200)
                        self.assertEqual((await request("POST", base+"/subscription/transaction", headers=headers,
                                                        json={"signed_transaction": "unknown.fixture.jws"}))[0], 400)
                        self.assertEqual((await request("POST", base+"/subscription/apple-notifications",
                            json={"signedPayload": hint({"data":{"environment":"Production"}})}))[0], 400)
                        action = str(uuid4())
                        headers["X-PinPin-Action-ID"] = action
                        self.assertEqual((await request("POST", base+"/decision", headers=headers, json=decision()))[0], 200)
                        response = await client.post(server.make_url(base+"/explanation"), headers=headers, json=explanation())
                        self.assertIn(b"[DONE]", await response.read())
                        status, value = await request("POST", base+"/subscription/actions/cancel", headers=headers, json={"action_id":action})
                        self.assertEqual((status, value["state"]), (200, "committed"))
                        for path in ("/ping/health", "/ping/v1/subscription/session", "/ping/v1/subscription/state",
                                     "/ping/v1/decision", "/ping/v1/explanation"):
                            method = "GET" if path.endswith(("health", "state")) else "POST"
                            self.assertEqual((await request(method, path, headers=headers, json={}))[0], 404)
                        legacy = {"Authorization":"Bearer fixture-old-shared-token", "X-PinPin-Action-ID":str(uuid4())}
                        self.assertEqual((await request("POST", base+"/decision", headers=legacy, json=decision()))[0], 401)
                        self.assertEqual(len(calls), 2)
                finally:
                    await server.close()
            finally:
                await upstream_server.close()
