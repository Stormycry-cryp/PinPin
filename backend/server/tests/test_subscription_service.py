"""Business-state tests inject trusted records; these do not prove Apple purchases."""

from concurrent.futures import ThreadPoolExecutor
from contextlib import closing
from dataclasses import replace
from datetime import datetime, timedelta, timezone
import multiprocessing
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from apple_subscription_verifier import (
    MONTHLY_PRODUCT, SubscriptionError, VerifiedAppIdentity,
    VerifiedNotification, VerifiedStoreTransaction,
)
from subscription_service import SESSION_TTL, SubscriptionService

UTC = timezone.utc
NOW = datetime(2026, 10, 26, 12, tzinfo=UTC)


def ms(value):
    return int(value.timestamp() * 1000)


class TrustedFixtureVerifier:
    """In-process only: the HTTP request cannot choose this adapter or its records."""
    environment = "Sandbox"
    bundle_id = "com.pointout.app"

    def __init__(self):
        self.apps = {"app.alice.jws": VerifiedAppIdentity("app-alice", self.bundle_id, self.environment),
                     "app.bob.jws": VerifiedAppIdentity("app-bob", self.bundle_id, self.environment)}
        self.transactions = {}
        self.notifications = {}

    @staticmethod
    def lookup(mapping, value):
        if value not in mapping:
            raise SubscriptionError("invalid_signature", "Apple signature verification failed.")
        return mapping[value]

    def verify_app(self, signed):
        return self.lookup(self.apps, signed)

    def verify_transaction(self, signed):
        return self.lookup(self.transactions, signed)

    def verify_notification(self, signed):
        return self.lookup(self.notifications, signed)


def fixture_transaction(**changes):
    value = VerifiedStoreTransaction("t1", "o1", "app-alice", MONTHLY_PRODUCT,
                                     "com.pointout.app", "Sandbox", ms(NOW - timedelta(days=5)),
                                     ms(NOW + timedelta(days=25)), ms(NOW))
    return replace(value, **changes)


def process_restore(database, token, output):
    verifier = TrustedFixtureVerifier()
    verifier.transactions["transaction.fixture.jws"] = fixture_transaction()
    service = SubscriptionService(database, verifier, clock=lambda: NOW)
    output.put(service.submit_transaction(token, "transaction.fixture.jws"))


class ServiceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="pinpin-service-test-")
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "subscriptions.sqlite3"
        self.verifier = TrustedFixtureVerifier()
        self.now = NOW
        self.service = SubscriptionService(self.path, self.verifier, clock=lambda: self.now)
        self.session = self.service.create_session("app.alice.jws")
        self.token = self.session["access_token"]
        self.user = self.service.authenticate(self.token).user_id

    def submit(self, value=None, token=None):
        self.verifier.transactions["transaction.fixture.jws"] = value or fixture_transaction()
        return self.service.submit_transaction(token or self.token, "transaction.fixture.jws")

    def notify(self, value=None, kind="DID_RENEW", identity="notification-1"):
        self.verifier.notifications["notification.fixture.jws"] = VerifiedNotification(
            identity, kind, ms(self.now), value)
        return self.service.accept_notification("notification.fixture.jws")

    def rows(self, table):
        with closing(sqlite3.connect(self.path)) as db:
            return db.execute("SELECT * FROM " + table).fetchall()

    def test_sessions_are_stable_across_devices_restart_and_do_not_reset_free_usage(self):
        self.service.ledger.reserve(self.user, "free")
        self.service.ledger.commit(self.user, "free")
        second = self.service.create_session("app.alice.jws")
        restarted = SubscriptionService(self.path, self.verifier, clock=lambda: self.now)
        third = restarted.create_session("app.alice.jws")
        self.assertEqual(second["app_account_token"], self.session["app_account_token"])
        self.assertEqual(third["app_account_token"], self.session["app_account_token"])
        self.assertNotEqual(second["access_token"], self.token)
        self.assertEqual(restarted.authenticate(third["access_token"]).user_id, self.user)
        self.assertEqual(restarted.state(self.token)["remaining"], 19)
        self.assertEqual(len(self.rows("subscription_identities")), 1)
        for path in Path(self.temp.name).iterdir():
            if path.is_file():
                self.assertNotIn(self.token.encode(), path.read_bytes())
                self.assertNotIn(b"app.alice.jws", path.read_bytes())

    def test_expiry_and_bad_tokens(self):
        self.now += SESSION_TTL
        for token in (self.token, "bad", "x" * 1000):
            with self.assertRaises(SubscriptionError) as error:
                self.service.state(token)
            self.assertEqual(error.exception.status, 401)

    def test_parallel_sessions_use_one_identity_and_account_token(self):
        with ThreadPoolExecutor(max_workers=8) as pool:
            sessions = list(pool.map(lambda _: self.service.create_session("app.alice.jws"), range(8)))
        self.assertEqual({s["app_account_token"] for s in sessions}, {self.session["app_account_token"]})
        self.assertEqual(len(self.rows("subscription_identities")), 1)

    def test_malformed_app_and_database_scope_fail_closed(self):
        with self.assertRaises(SubscriptionError):
            self.service.create_session("unsigned")
        other = TrustedFixtureVerifier()
        other.environment = "Production"
        with self.assertRaises(ValueError):
            SubscriptionService(self.path, other)

    def test_purchase_restore_does_not_reset_spent_quota(self):
        self.assertEqual(self.submit()["limit"], 1000)
        self.service.ledger.reserve(self.user, "pro-action")
        self.service.ledger.commit(self.user, "pro-action")
        for _ in range(3):
            self.assertEqual(self.submit()["remaining"], 999)
        self.assertEqual(len(self.rows("subscription_projections")), 1)
        self.assertEqual(self.rows("subscription_projections")[0][1], 1)

    def test_ownership_and_original_transaction_cannot_be_rebound(self):
        bob = self.service.create_session("app.bob.jws")["access_token"]
        with self.assertRaises(SubscriptionError):
            self.submit(token=bob)
        self.submit()
        with self.assertRaises(SubscriptionError):
            self.submit(fixture_transaction(transaction_id="bob-t", app_transaction_id="app-bob"), bob)
        self.assertEqual(self.service.state(bob)["plan"], "free")
        with self.assertRaises(SubscriptionError):
            self.submit(fixture_transaction(app_account_token="wrong-account"))
        self.assertEqual(self.submit(fixture_transaction(app_account_token=self.session["app_account_token"]))["plan"], "pro")

    def test_duplicate_refund_and_old_jws_cannot_restore(self):
        purchase = fixture_transaction()
        self.submit(purchase)
        refund = replace(purchase, signed_ms=ms(NOW) + 1, revocation_ms=ms(NOW))
        self.notify(refund, "REFUND")
        self.notify(refund, "REFUND")
        self.assertEqual(self.submit(purchase)["plan"], "free")
        self.assertEqual(len(self.rows("subscription_notifications")), 1)
        self.assertEqual(self.rows("subscription_projections")[0][1], 2)

    def test_revocation_wins_equal_signed_date_in_both_orders(self):
        purchase = fixture_transaction()
        refund = replace(purchase, revocation_ms=ms(NOW))
        self.submit(purchase)
        self.notify(refund, "REFUND")
        self.assertEqual(self.submit(purchase)["plan"], "free")

    def test_late_old_refund_does_not_erase_new_cycle_or_block_next_cycle(self):
        older = fixture_transaction(purchase_ms=ms(NOW - timedelta(days=40)), expires_ms=ms(NOW - timedelta(days=10)))
        self.submit(older)
        current = fixture_transaction(transaction_id="t2", signed_ms=ms(NOW) - 1000)
        self.submit(current)
        self.notify(replace(older, signed_ms=ms(NOW), revocation_ms=ms(NOW)), "REFUND")
        self.assertEqual(self.service.state(self.token)["plan"], "pro")
        self.assertEqual(self.rows("subscription_projections")[0][2], "t2")

    def test_future_period_is_persisted_and_activates_only_when_effective(self):
        self.submit()
        self.service.ledger.reserve(self.user, "current-action")
        self.service.ledger.commit(self.user, "current-action")
        future_start = NOW + timedelta(days=25)
        future = fixture_transaction(transaction_id="t2", purchase_ms=ms(future_start),
                                     expires_ms=ms(future_start + timedelta(days=30)))
        self.assertEqual(self.submit(future)["remaining"], 999)
        self.now = future_start
        self.assertEqual(self.service.state(self.token)["remaining"], 1000)
        self.assertEqual(self.rows("subscription_projections")[0][2], "t2")

    def test_expiration_returns_to_original_free_quota(self):
        self.service.ledger.reserve(self.user, "free-before")
        self.service.ledger.commit(self.user, "free-before")
        self.submit(fixture_transaction(expires_ms=ms(NOW + timedelta(hours=1))))
        self.now += timedelta(hours=1)
        self.assertEqual(self.service.state(self.token)["remaining"], 19)

    def test_unknown_notification_creates_no_identity_but_keeps_refund_for_later_binding(self):
        orphan = fixture_transaction(app_transaction_id="app-bob", signed_ms=ms(NOW)+1, revocation_ms=ms(NOW))
        self.notify(orphan, "REFUND")
        self.assertEqual(len(self.rows("subscription_identities")), 1)
        self.assertEqual(len(self.rows("subscription_owners")), 0)
        bob = self.service.create_session("app.bob.jws")["access_token"]
        self.assertEqual(self.submit(replace(orphan, signed_ms=ms(NOW), revocation_ms=None), bob)["plan"], "free")

    def test_test_notification_and_unknown_product_do_not_grant(self):
        self.notify(fixture_transaction(), "TEST", "test-notification")
        self.notify(fixture_transaction(product_id="com.other.product"), "SUBSCRIBED", "unknown-product")
        self.assertEqual(self.rows("subscription_transactions"), [])
        self.assertEqual(self.service.state(self.token)["plan"], "free")
        with self.assertRaises(SubscriptionError):
            self.submit(fixture_transaction(product_id="com.other.product"))

    def test_conflicting_notification_id_and_transaction_period_are_rejected(self):
        self.submit()
        self.notify(fixture_transaction())
        with self.assertRaises(SubscriptionError):
            self.notify(replace(fixture_transaction(), revocation_ms=ms(NOW)), "REFUND")
        with self.assertRaises(SubscriptionError):
            self.submit(fixture_transaction(expires_ms=ms(NOW + timedelta(days=26))))

    def test_refund_reversal_requires_a_newer_signed_state_and_reuses_usage(self):
        self.submit()
        self.service.ledger.reserve(self.user, "spent")
        self.service.ledger.commit(self.user, "spent")
        self.notify(fixture_transaction(signed_ms=ms(NOW)+1, revocation_ms=ms(NOW)), "REFUND")
        self.notify(fixture_transaction(signed_ms=ms(NOW)+2), "REFUND_REVERSED", "reversal")
        self.assertEqual(self.service.state(self.token)["remaining"], 999)

    def test_projection_replays_after_crash_between_journal_and_ledger(self):
        with patch.object(self.service.ledger, "apply_verified_entitlement", side_effect=RuntimeError("simulated crash")):
            with self.assertRaises(RuntimeError):
                self.submit()
        restarted = SubscriptionService(self.path, self.verifier, clock=lambda: self.now)
        self.assertEqual(restarted.state(self.token)["plan"], "pro")
        self.assertEqual(self.rows("subscription_projections")[0][1], 1)

    def test_cross_process_duplicate_restore_is_atomic(self):
        context = multiprocessing.get_context("spawn")
        output = context.Queue()
        children = [context.Process(target=process_restore, args=(str(self.path), self.token, output)) for _ in range(2)]
        for process in children:
            process.start()
        for process in children:
            process.join(20)
            self.assertEqual(process.exitcode, 0)
            process.close()
        self.assertEqual([output.get(timeout=2)["remaining"] for _ in children], [1000, 1000])
        output.close()
        output.join_thread()
        self.assertEqual(self.rows("subscription_projections")[0][1], 1)
        self.assertEqual(len(self.rows("entitlement_events")), 1)

    def test_signed_extension_keeps_same_quota_and_old_replay_keeps_later_end(self):
        purchase = fixture_transaction()
        self.submit(purchase)
        self.service.ledger.reserve(self.user, "spent-before-extension")
        self.service.ledger.commit(self.user, "spent-before-extension")
        extension = replace(purchase, signed_ms=purchase.signed_ms+1000, expires_ms=purchase.expires_ms+86400000)
        self.notify(extension, "RENEWAL_EXTENDED")
        state = self.service.state(self.token)
        self.assertEqual(state["remaining"], 999)
        self.assertEqual(state["period_end"], datetime.fromtimestamp(extension.expires_ms/1000, UTC).isoformat().replace("+00:00", "Z"))
        self.assertEqual(self.submit(purchase), state)
        self.assertEqual(self.submit(replace(purchase, signed_ms=extension.signed_ms+1000)), state)
        self.assertEqual(self.rows("subscription_projections")[0][1], 2)

    def test_extended_transaction_refund_with_original_end_wins_and_start_remains_fixed(self):
        purchase = fixture_transaction()
        self.submit(purchase)
        extension = replace(purchase, signed_ms=purchase.signed_ms+1000, expires_ms=purchase.expires_ms+86400000)
        self.submit(extension)
        with self.assertRaises(SubscriptionError):
            self.submit(replace(extension, purchase_ms=extension.purchase_ms-1000, signed_ms=extension.signed_ms+1000))
        self.notify(replace(purchase, signed_ms=extension.signed_ms+1000, revocation_ms=purchase.signed_ms), "REFUND")
        self.assertEqual(self.submit(extension)["plan"], "free")
        self.assertEqual(self.rows("subscription_transactions")[0][5], extension.expires_ms)


if __name__ == "__main__":
    unittest.main()
