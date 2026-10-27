"""Private temporary SQLite databases only; no network, payments or real user data."""

from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from pathlib import Path
import sqlite3
import sys
import tempfile
import threading
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from subscriptions import (DEFAULT_LEASE, FREE_MONTHLY_LIMIT, MAX_LEASE,
                           PRO_MONTHLY_LIMIT, SubscriptionLedger, VerifiedEntitlementEvent)

UTC = timezone.utc


def instant(value):
    return datetime.fromisoformat(value).astimezone(UTC)


class LedgerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="pinpin-subscription-test-")
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "ledger.sqlite3"
        self.now = instant("2026-01-31T10:20:30+00:00")
        self.ledger = SubscriptionLedger(self.path, clock=lambda: self.now)

    def event(self, *, user="alice", event="purchase-1", revision=1,
              start="2026-01-31T10:20:30+00:00", end="2026-02-28T10:20:30+00:00",
              transaction="transaction-1",
              revoked=False):
        return VerifiedEntitlementEvent(user, event, revision, transaction,
                                        instant(start), instant(end), revoked)

    def use(self, count, user="alice", prefix="action"):
        for number in range(count):
            action = f"{prefix}-{number}"
            self.assertTrue(self.ledger.reserve(user, action).can_execute)
            self.assertEqual(self.ledger.commit(user, action).state, "committed")

    def test_free_20_and_pro_1000_are_enforced_by_reservations_and_commits(self):
        self.use(FREE_MONTHLY_LIMIT)
        self.assertEqual(self.ledger.snapshot("alice").remaining, 0)
        self.assertEqual(self.ledger.reserve("alice", "free-over").state, "quota_exceeded")
        self.assertTrue(self.ledger.apply_verified_entitlement(self.event()))
        self.use(PRO_MONTHLY_LIMIT - 1, prefix="pro")
        last = self.ledger.reserve("alice", "pro-last")
        self.assertTrue(last.can_execute)
        self.assertEqual(self.ledger.snapshot("alice").committed, 999)
        self.assertEqual(self.ledger.snapshot("alice").reserved, 1)
        self.assertEqual(self.ledger.reserve("alice", "pro-over").state, "quota_exceeded")
        self.assertEqual(self.ledger.commit("alice", "pro-last").state, "committed")
        self.assertEqual(self.ledger.snapshot("alice").committed, 1000)
        self.assertEqual(self.ledger.snapshot("alice").remaining, 0)

    def test_two_devices_compete_atomically_for_last_slot(self):
        self.use(19)
        other = SubscriptionLedger(self.path, clock=lambda: self.now)
        gate = threading.Barrier(2)

        def reserve(item):
            ledger, action = item
            gate.wait(timeout=5)
            return ledger.reserve("alice", action)

        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(reserve, [(self.ledger, "device-1"), (other, "device-2")]))
        self.assertEqual(sum(result.can_execute for result in results), 1)
        self.assertEqual(sorted(result.state for result in results), ["quota_exceeded", "reserved"])
        self.assertEqual(self.ledger.snapshot("alice").remaining, 0)

    def test_parallel_duplicate_action_grants_execution_once(self):
        other = SubscriptionLedger(self.path, clock=lambda: self.now)
        gate = threading.Barrier(2)

        def reserve(ledger):
            gate.wait(timeout=5)
            return ledger.reserve("alice", "same-action")

        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(reserve, [self.ledger, other]))
        self.assertEqual(sum(result.can_execute for result in results), 1)
        self.assertEqual(self.ledger.snapshot("alice").reserved, 1)
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda ledger: ledger.commit("alice", "same-action"),
                                    [self.ledger, other]))
        self.assertEqual([result.state for result in results], ["committed", "committed"])
        self.assertEqual(self.ledger.snapshot("alice").committed, 1)

    def test_commit_cancel_and_reserve_replays_never_execute_or_charge_twice(self):
        self.assertTrue(self.ledger.reserve("alice", "ok").can_execute)
        self.assertFalse(self.ledger.reserve("alice", "ok").can_execute)
        for _ in range(3):
            self.assertEqual(self.ledger.commit("alice", "ok").state, "committed")
            self.assertEqual(self.ledger.cancel("alice", "ok").state, "committed")
        self.assertFalse(self.ledger.reserve("alice", "ok").can_execute)
        self.assertEqual(self.ledger.snapshot("alice").committed, 1)
        self.ledger.reserve("alice", "error")
        for _ in range(3):
            self.assertEqual(self.ledger.cancel("alice", "error").state, "cancelled")
            self.assertEqual(self.ledger.commit("alice", "error").state, "cancelled")
        self.assertFalse(self.ledger.reserve("alice", "error").can_execute)
        self.assertEqual(self.ledger.snapshot("alice").remaining, 19)

    def test_quota_denial_is_also_idempotent_after_capacity_frees(self):
        reservations = [self.ledger.reserve("alice", str(i)) for i in range(20)]
        self.assertEqual(self.ledger.reserve("alice", "denied").state, "quota_exceeded")
        self.ledger.cancel("alice", reservations[0].action_id)
        self.assertEqual(self.ledger.reserve("alice", "denied").state, "quota_exceeded")
        self.assertTrue(self.ledger.reserve("alice", "fresh-action").can_execute)

    def test_expired_lease_releases_capacity_and_cannot_be_reused(self):
        for i in range(20):
            self.ledger.reserve("alice", str(i), lease=timedelta(seconds=3))
        self.now += timedelta(seconds=3)
        snapshot = self.ledger.snapshot("alice")
        self.assertEqual((snapshot.committed, snapshot.reserved, snapshot.remaining), (0, 0, 20))
        self.assertEqual(self.ledger.commit("alice", "0").state, "expired")
        self.assertFalse(self.ledger.reserve("alice", "0").can_execute)
        self.assertTrue(self.ledger.reserve("alice", "after-expiry").can_execute)

    def test_free_cycle_uses_utc_and_old_result_does_not_charge_new_month(self):
        self.now = instant("2026-01-31T23:59:59+00:00")
        reservation = self.ledger.reserve("alice", "old-month")
        self.assertEqual(reservation.expires_at, instant("2026-02-01T00:00:00+00:00"))
        self.now = datetime.fromisoformat("2026-02-01T08:00:00+08:00")
        self.assertEqual(self.ledger.commit("alice", "old-month").state, "expired")
        snapshot = self.ledger.snapshot("alice")
        self.assertEqual(snapshot.period_start, instant("2026-02-01T00:00:00+00:00"))
        self.assertEqual((snapshot.committed, snapshot.remaining), (0, 20))
        self.assertFalse(self.ledger.reserve("alice", "old-month").can_execute)

    def test_actual_verified_period_ends_without_inventing_another_pro_month(self):
        self.ledger.apply_verified_entitlement(self.event())
        self.use(1)
        self.now = instant("2026-02-28T10:20:29.999999+00:00")
        self.assertEqual(self.ledger.snapshot("alice").committed, 1)
        self.now += timedelta(microseconds=1)
        self.assertEqual(self.ledger.snapshot("alice").plan, "free")
        renewal = self.event(event="renewal", revision=2, transaction="transaction-2",
                             start="2026-02-28T10:20:30+00:00", end="2026-03-28T10:20:30+00:00")
        self.ledger.apply_verified_entitlement(renewal)
        snapshot = self.ledger.snapshot("alice")
        self.assertEqual(snapshot.period_start, self.now)
        self.assertEqual(snapshot.period_end, instant("2026-03-28T10:20:30+00:00"))
        self.assertEqual((snapshot.plan, snapshot.committed), ("pro", 0))
        self.now = instant("2026-03-28T10:20:30+00:00")
        self.assertEqual(self.ledger.snapshot("alice").plan, "free")

    def test_repeat_notification_restore_and_old_transaction_cannot_refill(self):
        original = self.event()
        self.ledger.apply_verified_entitlement(original)
        self.use(3)
        self.assertTrue(self.ledger.apply_verified_entitlement(self.event(event="restore", revision=2)))
        self.assertEqual(self.ledger.snapshot("alice").committed, 3)
        with self.assertRaises(ValueError):
            self.ledger.apply_verified_entitlement(self.event(
                event="shifted-transaction", revision=3, start="2026-01-31T10:21:00+00:00"))
        self.now = instant("2026-02-28T10:20:30+00:00")
        self.ledger.apply_verified_entitlement(self.event(
            event="renewal", revision=4, transaction="transaction-2",
            start="2026-02-28T10:20:30+00:00", end="2026-03-28T10:20:30+00:00"))
        self.use(2, prefix="renewed")
        # Even a later-delivered verified old transaction cannot replace the new period.
        self.assertFalse(self.ledger.apply_verified_entitlement(self.event(event="old-restore", revision=5)))
        self.assertEqual(self.ledger.snapshot("alice").committed, 2)
        self.assertFalse(self.ledger.apply_verified_entitlement(original))
        self.assertFalse(self.ledger.apply_verified_entitlement(self.event(
            event="old-refund", revision=6, revoked=True)))
        self.assertEqual(self.ledger.snapshot("alice").remaining, 998)

    def test_old_pro_result_cannot_charge_the_next_verified_transaction(self):
        self.ledger.apply_verified_entitlement(self.event())
        self.now = instant("2026-02-28T10:20:29+00:00")
        reservation = self.ledger.reserve("alice", "old-pro")
        self.assertEqual(reservation.expires_at, instant("2026-02-28T10:20:30+00:00"))
        self.now += timedelta(seconds=1)
        self.ledger.apply_verified_entitlement(self.event(
            event="renewal", revision=2, transaction="transaction-2",
            start="2026-02-28T10:20:30+00:00", end="2026-03-28T10:20:30+00:00"))
        self.assertEqual(self.ledger.commit("alice", "old-pro").state, "expired")
        self.assertEqual((self.ledger.snapshot("alice").committed,
                          self.ledger.snapshot("alice").remaining), (0, 1000))
        self.assertFalse(self.ledger.reserve("alice", "old-pro").can_execute)

    def test_same_verified_window_different_notification_transaction_cannot_refill(self):
        self.ledger.apply_verified_entitlement(self.event())
        self.use(3)
        self.ledger.apply_verified_entitlement(self.event(event="duplicate-window", revision=2,
                                                        transaction="transaction-alias"))
        self.assertEqual(self.ledger.snapshot("alice").committed, 3)
        self.assertEqual(self.ledger.snapshot("alice").remaining, 997)

    def test_entitlement_future_start_expiry_and_original_free_usage(self):
        self.use(2)
        future = self.event(start="2026-01-31T10:21:00+00:00",
                            end="2026-01-31T10:22:00+00:00")
        with self.assertRaisesRegex(ValueError, "has not started"):
            self.ledger.apply_verified_entitlement(future)
        self.assertEqual(self.ledger.snapshot("alice").plan, "free")
        self.now = instant("2026-01-31T10:21:59+00:00")
        self.assertTrue(self.ledger.apply_verified_entitlement(future))
        reservation = self.ledger.reserve("alice", "expires-with-entitlement")
        self.assertEqual(reservation.plan, "pro")
        self.assertEqual(reservation.expires_at, instant("2026-01-31T10:22:00+00:00"))
        self.now += timedelta(seconds=1)
        self.assertEqual(self.ledger.commit("alice", reservation.action_id).state, "expired")
        snapshot = self.ledger.snapshot("alice")
        self.assertEqual((snapshot.plan, snapshot.committed, snapshot.remaining), ("free", 2, 18))

    def test_future_transaction_rejection_preserves_current_pro_and_database_records(self):
        self.ledger.apply_verified_entitlement(self.event())
        self.use(3)
        self.ledger.reserve("alice", "in-flight")
        future = self.event(event="future-renewal", revision=2, transaction="transaction-2",
                            start="2026-02-28T10:20:30+00:00", end="2026-03-28T10:20:30+00:00")
        with sqlite3.connect(self.path) as db:
            before = tuple(db.iterdump())
        with self.assertRaisesRegex(ValueError, "has not started"):
            self.ledger.apply_verified_entitlement(future)
        with sqlite3.connect(self.path) as db:
            self.assertEqual(tuple(db.iterdump()), before)
        snapshot = self.ledger.snapshot("alice")
        self.assertEqual((snapshot.plan, snapshot.committed, snapshot.reserved, snapshot.remaining),
                         ("pro", 3, 1, 996))
        self.assertEqual(snapshot.period_end, instant("2026-02-28T10:20:30+00:00"))
        # The rejected event was not consumed: the same event is accepted exactly at its start.
        self.now = future.period_start
        self.assertTrue(self.ledger.apply_verified_entitlement(future))
        self.assertEqual((self.ledger.snapshot("alice").plan, self.ledger.snapshot("alice").remaining),
                         ("pro", 1000))
        self.assertEqual(self.ledger.commit("alice", "in-flight").state, "expired")

    def test_revocation_invalidates_pending_work_and_old_events_cannot_restore_pro(self):
        self.ledger.apply_verified_entitlement(self.event())
        self.use(1)
        self.ledger.reserve("alice", "in-flight")
        revoke = self.event(event="refund", revision=3, revoked=True)
        self.assertTrue(self.ledger.apply_verified_entitlement(revoke))
        self.assertEqual(self.ledger.commit("alice", "in-flight").state, "revoked")
        self.assertFalse(self.ledger.apply_verified_entitlement(self.event(event="late-renewal", revision=2)))
        self.assertFalse(self.ledger.apply_verified_entitlement(self.event(event="equal-active", revision=3)))
        self.assertFalse(self.ledger.apply_verified_entitlement(self.event()))
        self.assertEqual(self.ledger.snapshot("alice").plan, "free")
        self.assertTrue(self.ledger.apply_verified_entitlement(self.event(event="new-purchase", revision=4)))
        self.assertEqual((self.ledger.snapshot("alice").plan,
                          self.ledger.snapshot("alice").committed), ("pro", 1))
        self.assertFalse(self.ledger.reserve("alice", "in-flight").can_execute)

    def test_same_revision_revocation_wins_in_either_delivery_order(self):
        self.ledger.apply_verified_entitlement(self.event())
        revoke = self.event(event="same-version-refund", revoked=True)
        self.assertTrue(self.ledger.apply_verified_entitlement(revoke))
        self.assertFalse(self.ledger.apply_verified_entitlement(self.event(event="same-version-active")))
        self.assertEqual(self.ledger.snapshot("alice").plan, "free")
        self.assertFalse(self.ledger.apply_verified_entitlement(revoke))

    def test_conflicting_event_id_or_equal_revision_fails_without_replacing_state(self):
        self.ledger.apply_verified_entitlement(self.event())
        with self.assertRaises(ValueError):
            self.ledger.apply_verified_entitlement(self.event(end="2026-05-31T10:20:30+00:00"))
        with self.assertRaises(ValueError):
            self.ledger.apply_verified_entitlement(self.event(event="conflict", end="2026-05-31T10:20:30+00:00"))
        self.assertEqual(self.ledger.snapshot("alice").plan, "pro")

    def test_restart_preserves_entitlement_pending_and_terminal_actions(self):
        self.ledger.apply_verified_entitlement(self.event())
        self.use(1)
        self.ledger.reserve("alice", "pending")
        self.ledger.reserve("alice", "failed")
        self.ledger.cancel("alice", "failed")
        restarted = SubscriptionLedger(self.path, clock=lambda: self.now)
        snapshot = restarted.snapshot("alice")
        self.assertEqual((snapshot.plan, snapshot.committed, snapshot.reserved), ("pro", 1, 1))
        self.assertFalse(restarted.reserve("alice", "pending").can_execute)
        self.assertEqual(restarted.commit("alice", "pending").state, "committed")
        self.assertEqual(restarted.commit("alice", "failed").state, "cancelled")
        self.assertEqual(restarted.snapshot("alice").committed, 2)
        with sqlite3.connect(self.path) as db:
            self.assertEqual(db.execute("PRAGMA journal_mode").fetchone()[0], "wal")

    def test_verified_extension_reuses_quota_and_does_not_extend_or_revive_actions(self):
        end = self.now + timedelta(minutes=1)
        self.ledger.apply_verified_entitlement(self.event(end=end.isoformat()))
        self.use(1)
        pending = self.ledger.reserve("alice", "before-extension")
        self.ledger.reserve("alice", "cancelled")
        self.ledger.cancel("alice", "cancelled")
        later_end = self.now + timedelta(days=1)
        self.assertTrue(self.ledger.apply_verified_entitlement(
            self.event(event="extension", revision=2, end=later_end.isoformat())))
        state = self.ledger.snapshot("alice")
        self.assertEqual((state.committed, state.reserved, state.remaining), (1, 1, 998))
        self.assertEqual(state.period_end, later_end)
        self.assertEqual(self.ledger.reserve("alice", "before-extension").expires_at, pending.expires_at)
        self.assertEqual(self.ledger.reserve("alice", "cancelled").state, "cancelled")
        self.assertEqual(self.ledger.reserve("alice", "action-0").state, "committed")
        self.now = end
        self.assertEqual(self.ledger.commit("alice", "before-extension").state, "expired")
        fresh = self.ledger.reserve("alice", "after-original-end")
        self.assertTrue(fresh.can_execute)
        self.assertEqual(fresh.period_end, later_end)
        self.assertEqual(fresh.expires_at, self.now + DEFAULT_LEASE)
        self.assertEqual(self.ledger.reserve("alice", "before-extension").state, "expired")

    def test_extension_cannot_change_start_or_be_undone_by_old_or_shorter_events(self):
        self.ledger.apply_verified_entitlement(self.event())
        extended = self.event(event="extension", revision=2, end="2026-03-03T10:20:30+00:00")
        self.ledger.apply_verified_entitlement(extended)
        self.assertFalse(self.ledger.apply_verified_entitlement(self.event(event="old-replay")))
        self.assertFalse(self.ledger.apply_verified_entitlement(self.event(event="shorter-new-state", revision=3)))
        with self.assertRaises(ValueError):
            self.ledger.apply_verified_entitlement(self.event(event="moved-start", revision=4,
                                                               start="2026-01-30T10:20:30+00:00"))
        self.assertEqual(self.ledger.snapshot("alice").period_end, extended.period_end)

    def test_refund_with_older_end_still_revokes_extended_transaction(self):
        self.ledger.apply_verified_entitlement(self.event())
        extended = self.event(event="extension", revision=2, end="2026-03-03T10:20:30+00:00")
        self.ledger.apply_verified_entitlement(extended)
        self.ledger.reserve("alice", "pending-refund")
        self.assertTrue(self.ledger.apply_verified_entitlement(self.event(event="refund", revision=3, revoked=True)))
        self.assertEqual(self.ledger.snapshot("alice").plan, "free")
        self.assertEqual(self.ledger.commit("alice", "pending-refund").state, "revoked")
        self.assertFalse(self.ledger.apply_verified_entitlement(extended))
        with sqlite3.connect(self.path) as db:
            self.assertEqual(db.execute("SELECT period_end FROM verified_periods").fetchone()[0],
                             int(extended.period_end.timestamp()*1000000))

    def test_users_have_isolated_action_ids_entitlements_and_limits(self):
        self.ledger.apply_verified_entitlement(self.event())
        for user in ("alice", "bob"):
            self.assertTrue(self.ledger.reserve(user, "shared-id").can_execute)
            self.ledger.commit(user, "shared-id")
        self.assertEqual(self.ledger.snapshot("alice").remaining, 999)
        self.assertEqual(self.ledger.snapshot("bob").remaining, 19)
        with self.assertRaises(KeyError):
            self.ledger.commit("charlie", "shared-id")
        self.assertEqual(self.ledger.snapshot("charlie").committed, 0)

    def test_sqlite_failure_rolls_back_charge_and_keeps_reservation(self):
        self.ledger.reserve("alice", "atomic")
        with sqlite3.connect(self.path) as db:
            db.execute("CREATE TRIGGER simulate_failure BEFORE UPDATE ON actions "
                       "WHEN NEW.state='committed' BEGIN SELECT RAISE(ABORT, 'injected failure'); END")
        with self.assertRaises(sqlite3.IntegrityError):
            self.ledger.commit("alice", "atomic")
        snapshot = self.ledger.snapshot("alice")
        self.assertEqual((snapshot.committed, snapshot.reserved), (0, 1))
        with sqlite3.connect(self.path) as db:
            db.execute("DROP TRIGGER simulate_failure")
        self.assertEqual(self.ledger.commit("alice", "atomic").state, "committed")
        self.assertEqual(self.ledger.snapshot("alice").committed, 1)

    def test_invalid_inputs_fail_before_granting_execution(self):
        for lease in (timedelta(0), timedelta(seconds=-1), MAX_LEASE + timedelta(microseconds=1)):
            with self.assertRaises(ValueError):
                self.ledger.reserve("alice", "invalid", lease=lease)
        for user, action in (("", "a"), ("a", " "), ("a", "a" * 257)):
            with self.assertRaises(ValueError):
                self.ledger.reserve(user, action)
        with self.assertRaises(TypeError):
            self.ledger.apply_verified_entitlement({"user_id": "alice", "isPro": True})
        with self.assertRaises(ValueError):
            self.ledger.apply_verified_entitlement(VerifiedEntitlementEvent(
                "alice", "naive", 1, "transaction", datetime(2026, 1, 1), datetime(2026, 2, 1)))
        with self.assertRaises(ValueError):
            self.ledger.apply_verified_entitlement(VerifiedEntitlementEvent("alice", "bad-window", 1, "transaction", self.now, self.now))
        with self.assertRaises(KeyError):
            self.ledger.commit("alice", "unknown")
        self.assertEqual(self.ledger.snapshot("alice").remaining, 20)
        self.assertEqual(DEFAULT_LEASE, timedelta(minutes=5))


if __name__ == "__main__":
    unittest.main()
