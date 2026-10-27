"""Dual-environment routing with loopback HTTP and explicit trusted fixtures."""

import base64
from dataclasses import replace
import json
from pathlib import Path
import sys
import tempfile
import unittest
from uuid import uuid4

from aiohttp import ClientSession, web
from aiohttp.test_utils import TestServer

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from apple_subscription_verifier import SubscriptionError, VerifiedAppIdentity, VerifiedNotification
from subscription_environments import SubscriptionEnvironments
from subscription_gateway import CommercialGatewaySettings, create_subscription_gateway
from subscription_http import mount_subscription_routes
from subscription_service import SubscriptionService
from test_subscription_service import NOW, TrustedFixtureVerifier, fixture_transaction
from test_subscription_gateway import good_stream, decision_response
from test_gateway import decision, explanation


def hint(payload):
    return "e30." + base64.urlsafe_b64encode(json.dumps(payload).encode()).decode().rstrip("=") + ".fixture"


def services(directory):
    result = []
    for environment in ("Production", "Sandbox"):
        verifier = TrustedFixtureVerifier()
        verifier.environment = environment
        app = hint({"receiptType": environment})
        verifier.apps = {app: VerifiedAppIdentity("same-app-id", verifier.bundle_id, environment)}
        service = SubscriptionService(Path(directory) / (environment + ".sqlite"), verifier, clock=lambda: NOW)
        result.append((service, app))
    return result


class SubscriptionEnvironmentTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="pinpin-dual-env-test-")
        self.addCleanup(self.temp.cleanup)
        (self.production, self.prod_app), (self.sandbox, self.sandbox_app) = services(self.temp.name)
        self.router = SubscriptionEnvironments(production=self.production, sandbox=self.sandbox)

    def test_explicit_scope_and_distinct_database_required(self):
        with self.assertRaises(ValueError):
            SubscriptionEnvironments(production=self.sandbox, sandbox=self.production)
        self.sandbox.verifier.bundle_id = "other.app"
        with self.assertRaises(ValueError):
            SubscriptionEnvironments(production=self.production, sandbox=self.sandbox)

    def test_same_apple_identity_has_independent_sessions_quota_and_transaction_ownership(self):
        sessions = [self.router.create_session(app) for app in (self.prod_app, self.sandbox_app)]
        principals = [service.authenticate(session["access_token"])
                      for service, session in zip((self.production, self.sandbox), sessions)]
        self.assertNotEqual(principals[0].user_id, principals[1].user_id)
        self.assertNotEqual(sessions[0]["app_account_token"], sessions[1]["app_account_token"])
        for service, session in zip((self.production, self.sandbox), sessions):
            service.verifier.transactions["transaction.fixture.jws"] = fixture_transaction(
                app_transaction_id="same-app-id", environment=service.verifier.environment,
                app_account_token=session["app_account_token"])
        self.router.submit_transaction(sessions[0]["access_token"], "transaction.fixture.jws")
        self.assertEqual(self.router.state(sessions[0]["access_token"])["limit"], 1000)
        self.assertEqual(self.router.state(sessions[1]["access_token"])["limit"], 20)
        self.router.submit_transaction(sessions[1]["access_token"], "transaction.fixture.jws")
        for service, principal in zip((self.production, self.sandbox), principals):
            action = service.ledger.reserve(principal.user_id, "same-action")
            self.assertTrue(action.can_execute)
            service.ledger.commit(principal.user_id, "same-action")
        self.assertEqual([self.router.state(s["access_token"])["committed"] for s in sessions], [1, 1])

    def test_unknown_or_forged_hint_never_falls_back_or_creates_identity(self):
        for environment in ("Xcode", "LocalTesting", "sandbox", "Unknown", None):
            with self.assertRaises(SubscriptionError):
                self.router.create_session(hint({"receiptType": environment}))
        # Select Sandbox with a Production-only fixture payload; no fallback.
        with self.assertRaises(SubscriptionError):
            self.router.create_session(hint({"receiptType": "Sandbox", "forged": True}))
        for service in (self.production, self.sandbox):
            with service._connection() as db:
                self.assertEqual(db.execute("SELECT COUNT(*) FROM subscription_identities").fetchone()[0], 0)

    def test_cross_environment_transaction_is_rejected_by_session_scope(self):
        session = self.router.create_session(self.prod_app)
        self.production.verifier.transactions["cross.fixture.jws"] = fixture_transaction(
            app_transaction_id="same-app-id", environment="Sandbox")
        with self.assertRaises(SubscriptionError):
            self.router.submit_transaction(session["access_token"], "cross.fixture.jws")
        self.assertEqual(self.router.state(session["access_token"])["limit"], 20)

    def test_notification_scope_refund_and_replay_are_isolated(self):
        sessions = [self.router.create_session(app) for app in (self.prod_app, self.sandbox_app)]
        for service, session in zip((self.production, self.sandbox), sessions):
            transaction = fixture_transaction(app_transaction_id="same-app-id", environment=service.verifier.environment)
            service.verifier.transactions["transaction.fixture.jws"] = transaction
            self.router.submit_transaction(session["access_token"], "transaction.fixture.jws")
            signed = hint({"data": {"environment": service.verifier.environment}})
            service.verifier.notifications[signed] = VerifiedNotification(
                "same-notification", "REFUND", transaction.signed_ms,
                replace(transaction, revocation_ms=transaction.signed_ms))
        signed = hint({"data": {"environment": "Sandbox"}})
        self.router.accept_notification(signed)
        self.router.accept_notification(signed)
        self.assertEqual([self.router.state(s["access_token"])["plan"] for s in sessions], ["pro", "free"])
        for value in ({"data": {"environment": "LocalTesting"}}, {},
                      {"data": {"environment": "Sandbox"}, "appData": {"environment": "Production"}}):
            with self.assertRaises(SubscriptionError):
                self.router.accept_notification(hint(value))

    def test_formal_gateway_requires_real_verifiers_for_both_environments(self):
        with self.assertRaises(ValueError):
            create_subscription_gateway(CommercialGatewaySettings("test", "test"), self.router)


class SubscriptionEnvironmentHTTPTests(unittest.IsolatedAsyncioTestCase):
    async def test_authenticated_cancel_cannot_change_other_environment(self):
        with tempfile.TemporaryDirectory(prefix="pinpin-dual-env-cancel-") as directory:
            (production, prod_app), (sandbox, sandbox_app) = services(directory)
            router = SubscriptionEnvironments(production=production, sandbox=sandbox)
            prod_session, sandbox_session = [router.create_session(app) for app in (prod_app, sandbox_app)]
            action, prod_only = str(uuid4()), str(uuid4())
            for service, session in ((production, prod_session), (sandbox, sandbox_session)):
                service.ledger.reserve(service.authenticate(session["access_token"]).user_id, action)
            production.ledger.reserve(production.authenticate(prod_session["access_token"]).user_id, prod_only)
            app = web.Application()
            mount_subscription_routes(app, router)
            server = TestServer(app)
            await server.start_server()
            try:
                async with ClientSession() as client:
                    async def cancel(session, identifier):
                        response = await client.post(server.make_url("/ping/v1/subscription/actions/cancel"),
                            json={"action_id": identifier}, headers={"Authorization": "Bearer " + session["access_token"]})
                        return response.status, await response.json()
                    self.assertEqual((await cancel(sandbox_session, prod_only))[0], 404)
                    self.assertEqual((await cancel(sandbox_session, action))[1]["state"], "cancelled")
                    self.assertEqual(router.state(prod_session["access_token"])["reserved"], 2)
                    self.assertEqual(router.state(sandbox_session["access_token"])["reserved"], 0)
                    self.assertEqual((await cancel(prod_session, action))[1]["state"], "cancelled")
                    self.assertEqual(router.state(prod_session["access_token"])["reserved"], 1)
            finally:
                await server.close()

    async def test_fixed_api_url_accepts_both_environments_and_model_settlement_isolated(self):
        with tempfile.TemporaryDirectory(prefix="pinpin-dual-env-http-") as directory:
            (production, prod_app), (sandbox, sandbox_app) = services(directory)
            router = SubscriptionEnvironments(production=production, sandbox=sandbox)
            calls = []

            async def upstream(request):
                body = await request.json()
                calls.append(request.path)
                if request.path == "/decision":
                    return web.json_response(decision_response(body))
                return web.Response(body=good_stream(), content_type="text/event-stream")

            upstream_app = web.Application()
            upstream_app.router.add_post("/{route}", upstream)
            upstream_server = TestServer(upstream_app)
            await upstream_server.start_server()
            try:
                urls = tuple(str(upstream_server.make_url("/" + route)) for route in ("decision", "explanation"))
                gateway = TestServer(create_subscription_gateway(CommercialGatewaySettings("test", "test"),
                                                                router, _test_upstreams=urls))
                await gateway.start_server()
                try:
                    async with ClientSession() as client:
                        sessions = []
                        for app in (prod_app, sandbox_app):
                            response = await client.post(gateway.make_url("/ping/v1/subscription/session"),
                                                         json={"signed_app_transaction": app})
                            self.assertEqual(response.status, 200)
                            sessions.append(await response.json())
                        action = str(uuid4())
                        for index, session in enumerate(sessions):
                            headers = {"Authorization": "Bearer " + session["access_token"], "X-PinPin-Action-ID": action}
                            for route, body in (("decision", decision()), ("explanation", explanation())):
                                response = await client.post(gateway.make_url("/ping/v1/" + route), headers=headers, json=body)
                                self.assertEqual(response.status, 200)
                                self.assertTrue(await response.read())
                            # The same action ID in each ledger commits once.
                            states = [router.state(s["access_token"])["committed"] for s in sessions]
                            self.assertEqual(states, [1, int(index == 1)])
                        self.assertEqual(len(calls), 4)
                        bad = await client.post(gateway.make_url("/ping/v1/subscription/session"),
                                                json={"signed_app_transaction": prod_app, "environment": "Sandbox"})
                        self.assertEqual(bad.status, 400)
                finally:
                    await gateway.close()
            finally:
                await upstream_server.close()
