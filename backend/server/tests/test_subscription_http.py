"""Actual loopback HTTP with an explicitly injected trusted-fixture verifier."""

import asyncio
from dataclasses import replace
import json
from pathlib import Path
import sys
import tempfile
import threading
import unittest
from uuid import uuid4

from aiohttp import ClientSession, web
from aiohttp.test_utils import TestServer

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from subscription_http import MAX_BODY_BYTES, mount_subscription_routes
from subscription_service import SubscriptionService
from test_subscription_service import NOW, TrustedFixtureVerifier, fixture_transaction
from apple_subscription_verifier import VerifiedNotification

BASE = "/ping/v1/subscription/"


class SubscriptionHTTPTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="pinpin-http-test-")
        self.addCleanup(self.temp.cleanup)
        self.verifier = TrustedFixtureVerifier()
        self.service = SubscriptionService(Path(self.temp.name) / "ledger.db", self.verifier, clock=lambda: NOW)
        self.app = web.Application()
        self.routes = mount_subscription_routes(self.app, self.service, workers=2)
        self.server = TestServer(self.app)
        await self.server.start_server()
        self.client = ClientSession()
        self.addAsyncCleanup(self.server.close)
        self.addAsyncCleanup(self.client.close)

    async def post(self, endpoint, payload=None, **kwargs):
        response = await self.client.post(self.server.make_url(BASE + endpoint), json=payload, **kwargs)
        value = await response.json()
        self.assertEqual(response.headers["Cache-Control"], "no-store")
        return response.status, value

    async def session(self, person="alice"):
        status, value = await self.post("session", {"signed_app_transaction": f"app.{person}.jws"})
        self.assertEqual(status, 200)
        return value

    async def test_action_cancel_validation_auth_unknown_and_user_isolation(self):
        action = str(uuid4())
        self.assertEqual((await self.post("actions/cancel", {"action_id": action}))[0], 401)
        session = await self.session()
        other = await self.session("bob")
        headers = {"Authorization": "Bearer " + session["access_token"]}
        other_headers = {"Authorization": "Bearer " + other["access_token"]}
        for value in (None, 2, {}, "bad", "00000000-0000-0000-0000-000000000000"):
            self.assertEqual((await self.post("actions/cancel", {"action_id": value}, headers=headers))[0], 400)
        self.assertEqual((await self.post("actions/cancel", {"action_id": action, "environment": "Sandbox"}, headers=headers))[0], 400)
        self.assertEqual((await self.post("actions/cancel", {"action_id": action}, headers=headers))[0], 404)
        principal = self.service.authenticate(session["access_token"])
        self.service.ledger.reserve(principal.user_id, action)
        self.assertEqual((await self.post("actions/cancel", {"action_id": action}, headers=other_headers))[0], 404)
        self.assertEqual(self.service.ledger.snapshot(principal.user_id).reserved, 1)
        with self.service._connection() as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM actions").fetchone()[0], 1)
            self.assertEqual(db.execute("SELECT COUNT(*) FROM subscription_identities").fetchone()[0], 2)

    async def test_action_cancel_is_idempotent_durable_and_never_refunds_committed(self):
        session = await self.session()
        token = session["access_token"]
        headers = {"Authorization": "Bearer " + token}
        principal = self.service.authenticate(token)
        pending, completed = str(uuid4()), str(uuid4())
        for action in (pending, completed):
            self.service.ledger.reserve(principal.user_id, action)
        self.service.ledger.commit(principal.user_id, completed)
        results = await asyncio.gather(*(self.post("actions/cancel", {"action_id": pending}, headers=headers) for _ in range(3)))
        self.assertEqual([status for status, _ in results], [200, 200, 200])
        self.assertEqual([value["state"] for _, value in results], ["cancelled"] * 3)
        self.assertEqual((await self.post("actions/cancel", {"action_id": completed}, headers=headers))[1]["state"], "committed")
        await self.server.close()
        restarted = SubscriptionService(self.service.database, self.verifier, clock=lambda: NOW)
        app = web.Application()
        mount_subscription_routes(app, restarted, workers=2)
        self.server = TestServer(app)
        await self.server.start_server()
        self.addAsyncCleanup(self.server.close)
        for action, expected in ((pending, "cancelled"), (completed, "committed")):
            status, value = await self.post("actions/cancel", {"action_id": action}, headers=headers)
            self.assertEqual((status, value["state"]), (200, expected))
        self.assertEqual((restarted.state(token)["committed"], restarted.state(token)["reserved"]), (1, 0))

    async def test_action_cancel_racing_commit_has_one_persisted_terminal_result(self):
        session = await self.session()
        headers = {"Authorization": "Bearer " + session["access_token"]}
        principal = self.service.authenticate(session["access_token"])
        expected_committed = 0
        for _ in range(4):
            action = str(uuid4())
            self.service.ledger.reserve(principal.user_id, action)
            committed, cancelled = await asyncio.gather(
                asyncio.to_thread(self.service.ledger.commit, principal.user_id, action),
                self.post("actions/cancel", {"action_id": action}, headers=headers))
            self.assertEqual(cancelled[0], 200)
            self.assertEqual(committed.state, cancelled[1]["state"])
            expected_committed += committed.state == "committed"
        state = self.service.state(session["access_token"])
        self.assertEqual((state["committed"], state["reserved"]), (expected_committed, 0))

    async def test_session_state_purchase_restore_and_notification_over_http(self):
        session = await self.session()
        headers = {"Authorization": "Bearer " + session["access_token"]}
        response = await self.client.get(self.server.make_url(BASE + "state"), headers=headers)
        self.assertEqual((await response.json())["remaining"], 20)
        self.verifier.transactions["transaction.fixture.jws"] = fixture_transaction(app_account_token=session["app_account_token"])
        for _ in range(2):
            status, value = await self.post("transaction", {"signed_transaction": "transaction.fixture.jws"}, headers=headers)
            self.assertEqual(status, 200)
            self.assertEqual((value["plan"], value["limit"]), ("pro", 1000))
        refund = replace(self.verifier.transactions["transaction.fixture.jws"], revocation_ms=int(NOW.timestamp()*1000))
        self.verifier.notifications["notification.fixture.jws"] = VerifiedNotification("refund-1", "REFUND", refund.signed_ms, refund)
        for _ in range(2):
            self.assertEqual((await self.post("apple-notifications", {"signedPayload": "notification.fixture.jws"}))[0], 200)
        response = await self.client.get(self.server.make_url(BASE + "state"), headers=headers)
        self.assertEqual((await response.json())["plan"], "free")

    async def test_authorization_required_and_cross_identity_transaction_denied(self):
        response = await self.client.get(self.server.make_url(BASE + "state"))
        self.assertEqual(response.status, 401)
        self.assertEqual((await response.json())["error"]["code"], "unauthorized")
        session = await self.session("bob")
        self.verifier.transactions["transaction.fixture.jws"] = fixture_transaction()
        status, _ = await self.post("transaction", {"signed_transaction": "transaction.fixture.jws"},
                                    headers={"Authorization": "Bearer " + session["access_token"]})
        self.assertEqual(status, 403)
        response = await self.client.get(self.server.make_url(BASE + "state"), headers=[("Authorization", "Bearer x"), ("Authorization", "Bearer y")])
        self.assertEqual(response.status, 401)
        await response.read()

    async def test_invalid_signature_and_client_entitlement_or_environment_fields_denied(self):
        for payload in ({"signed_app_transaction": "forged.signature.value"},
                        {"signed_app_transaction": "app.alice.jws", "environment": "Xcode"},
                        {"signed_app_transaction": "app.alice.jws", "isPro": True},
                        {"signed_app_transaction": 123}, [], None):
            status, _ = await self.post("session", payload)
            self.assertEqual(status, 415 if payload is None else 400)

    async def test_body_size_chunked_duplicate_json_and_content_type_limits(self):
        async def large_chunks():
            for _ in range(20):
                yield b"x" * 8192

        for data, content_type, expected in (
            (b"x" * (MAX_BODY_BYTES+1), "application/json", 413),
            (large_chunks(), "application/json", 413),
            (b'{"signed_app_transaction":"app.alice.jws","signed_app_transaction":"app.bob.jws"}', "application/json", 400),
            (b"{}", "text/plain", 415),
            (b"{broken", "application/json", 400),
        ):
            response = await self.client.post(self.server.make_url(BASE + "session"), data=data,
                                              headers={"Content-Type": content_type})
            self.assertEqual(response.status, expected)
            self.assertIn("error", await response.json())

    async def test_slow_verifier_does_not_block_loop_and_worker_capacity_is_bounded(self):
        release = threading.Event()
        entered = threading.Barrier(3)
        original = self.verifier.verify_app

        def slow(signed):
            entered.wait(timeout=5)
            release.wait(timeout=5)
            return original(signed)

        self.verifier.verify_app = slow
        pending = [asyncio.create_task(self.post("session", {"signed_app_transaction": "app.alice.jws"})) for _ in range(2)]
        try:
            await asyncio.to_thread(entered.wait, 5)
            status, body = await asyncio.wait_for(self.post("session", {"signed_app_transaction": "app.alice.jws"}), 1)
            self.assertEqual((status, body["error"]["code"]), (503, "service_busy"))
        finally:
            release.set()
            results = await asyncio.gather(*pending)
        self.assertEqual([item[0] for item in results], [200, 200])

    async def test_cancelled_request_keeps_worker_slot_until_thread_finishes(self):
        release = threading.Event()
        entered = threading.Event()

        def blocking():
            entered.set()
            release.wait(timeout=5)
            return {}

        task = asyncio.create_task(self.routes._run(blocking))
        try:
            await asyncio.to_thread(entered.wait, 5)
            task.cancel()
            with self.assertRaises(asyncio.CancelledError):
                await task
            self.assertEqual(self.routes._slots.qsize(), 1)
        finally:
            release.set()
            await asyncio.gather(*self.routes._futures)
        await asyncio.sleep(0)
        self.assertEqual(self.routes._slots.qsize(), 2)

    async def test_internal_error_never_echoes_or_logs_credentials(self):
        secret = "private.raw.payload"

        def broken(signed):
            raise ValueError("sensitive " + signed)

        self.verifier.verify_app = broken
        with self.assertLogs("subscription_http", level="ERROR") as captured:
            status, value = await self.post("session", {"signed_app_transaction": secret})
        self.assertEqual(status, 500)
        self.assertNotIn(secret, json.dumps(value))
        self.assertNotIn(secret, "".join(captured.output))


if __name__ == "__main__":
    unittest.main()
