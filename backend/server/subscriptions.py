"""Internal monthly entitlement and usage ledger; no HTTP or payment verification.

Only a trusted server adapter may create VerifiedEntitlementEvent after verifying
purchase ownership, provider signatures, expiry and refund/revocation state. Its
revision must monotonically order the adapter's complete verified state for that
user, including revocations. A durable server projection sequence is suitable;
client timestamps are not. Original provider times remain in the adapter journal.
Client payloads (including isPro) must never reach this API
as verified events. The adapter supplies actual verified transaction period dates
for monthly products only; annual products are intentionally unsupported.

An action may start model work only when reserve().can_execute is true. Replays
return the original action and never authorize another execution. Stop work at
expires_at. Streaming previews may be displayed during the active lease; mark
final successful settlement/completion only after commit() returns committed.
The caller handles failed/cancelled actions and partial-output cleanup. An
exception authorizes neither new model work nor final successful completion.
A failed action needs a new action_id to retry. Persist action IDs for as long
as replay is possible.
"""

from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
import sqlite3
from typing import Callable, Iterator

UTC = timezone.utc
FREE_MONTHLY_LIMIT = 20
PRO_MONTHLY_LIMIT = 1000
MAX_LEASE = timedelta(minutes=15)
DEFAULT_LEASE = timedelta(minutes=5)
_EPOCH = datetime(1970, 1, 1, tzinfo=UTC)


def _utc(value: datetime) -> datetime:
    if not isinstance(value, datetime) or value.utcoffset() is None:
        raise ValueError("timestamps must be timezone-aware")
    return value.astimezone(UTC)


def _micros(value: datetime) -> int:
    delta = _utc(value) - _EPOCH
    return (delta.days * 86400 + delta.seconds) * 1_000_000 + delta.microseconds


def _datetime(value: int) -> datetime:
    return _EPOCH + timedelta(microseconds=value)


def _identifier(value: str, field: str) -> str:
    if not isinstance(value, str) or not value.strip() or len(value) > 256:
        raise ValueError(f"{field} must be a nonblank string of at most 256 characters")
    return value


def _next_free_month(start: datetime) -> datetime:
    if start.month == 12:
        return start.replace(year=start.year + 1, month=1)
    return start.replace(month=start.month + 1)


@dataclass(frozen=True)
class VerifiedEntitlementEvent:
    """Adapter-verified monthly state, never a client-supplied entitlement.

    revision orders the full entitlement state for this user. A cancellation of
    future renewal retains period_end; a refund/revocation sets revoked=True.
    The actual transaction ID and period_start are immutable. A strictly newer
    verified state may extend period_end without changing the quota cycle or
    existing action leases. Older/shorter states cannot undo that extension.
    Revocation wins an equal revision; only a strictly newer verified event can
    restore access. Same-version conflicting active states fail closed.
    Only periods that have already started are accepted; the future adapter must
    resubmit a not-yet-started transaction when it becomes effective.
    """
    user_id: str
    event_id: str
    revision: int
    transaction_id: str
    period_start: datetime
    period_end: datetime
    revoked: bool = False


@dataclass(frozen=True)
class UsageSnapshot:
    plan: str
    period_start: datetime
    period_end: datetime
    limit: int
    committed: int
    reserved: int

    @property
    def remaining(self) -> int:
        return self.limit - self.committed - self.reserved


@dataclass(frozen=True)
class ActionReservation:
    user_id: str
    action_id: str
    state: str
    plan: str
    period_start: datetime
    period_end: datetime
    expires_at: datetime
    newly_reserved: bool = False

    @property
    def can_execute(self) -> bool:
        return self.state == "reserved" and self.newly_reserved


class SubscriptionLedger:
    """SQLite WAL ledger shared by server workers/devices via authenticated IDs.

    Free cycles are UTC calendar months starting at 00:00 on day 1. Pro cycles
    use exactly the verified monthly transaction period_start/period_end. No
    local anniversary calculation extends a purchase or creates Pro periods.
    Each free cycle has 20 actions and each Pro period has 1000, with no carryover.
    Upgrades enter the Pro cycle;
    returning to free reuses any usage already recorded in that free calendar
    month. A lease ends at the earliest of its TTL, cycle end or entitlement end.
    """

    def __init__(self, database: str | Path, *,
                 clock: Callable[[], datetime] | None = None):
        self.database = str(database)
        if self.database == ":memory:":
            raise ValueError("use a private file database for durable shared transactions")
        self.clock = clock or (lambda: datetime.now(UTC))
        with self._connection() as db:
            db.execute("PRAGMA journal_mode=WAL")
            db.executescript("""
                CREATE TABLE IF NOT EXISTS entitlements (
                    user_id TEXT PRIMARY KEY,
                    event_id TEXT NOT NULL,
                    revision INTEGER NOT NULL,
                    transaction_id TEXT NOT NULL,
                    period_start INTEGER NOT NULL,
                    period_end INTEGER NOT NULL,
                    revoked INTEGER NOT NULL CHECK (revoked IN (0, 1))
                );
                CREATE TABLE IF NOT EXISTS entitlement_events (
                    user_id TEXT NOT NULL,
                    event_id TEXT NOT NULL,
                    revision INTEGER NOT NULL,
                    transaction_id TEXT NOT NULL,
                    period_start INTEGER NOT NULL,
                    period_end INTEGER NOT NULL,
                    revoked INTEGER NOT NULL,
                    PRIMARY KEY (user_id, event_id)
                );
                CREATE TABLE IF NOT EXISTS verified_periods (
                    user_id TEXT NOT NULL,
                    transaction_id TEXT NOT NULL,
                    period_start INTEGER NOT NULL,
                    period_end INTEGER NOT NULL,
                    PRIMARY KEY (user_id, transaction_id)
                );
                CREATE TABLE IF NOT EXISTS usage (
                    user_id TEXT NOT NULL,
                    plan TEXT NOT NULL,
                    period_start INTEGER NOT NULL,
                    committed INTEGER NOT NULL CHECK (committed >= 0),
                    PRIMARY KEY (user_id, plan, period_start)
                );
                CREATE TABLE IF NOT EXISTS actions (
                    user_id TEXT NOT NULL,
                    action_id TEXT NOT NULL,
                    state TEXT NOT NULL CHECK (state IN
                        ('reserved', 'committed', 'cancelled', 'expired', 'revoked', 'quota_exceeded')),
                    plan TEXT NOT NULL,
                    period_start INTEGER NOT NULL,
                    period_end INTEGER NOT NULL,
                    quota INTEGER NOT NULL,
                    expires_at INTEGER NOT NULL,
                    PRIMARY KEY (user_id, action_id)
                );
                CREATE INDEX IF NOT EXISTS actions_active_cycle
                    ON actions(user_id, plan, period_start, state);
            """)

    @contextmanager
    def _connection(self) -> Iterator[sqlite3.Connection]:
        db = sqlite3.connect(self.database, timeout=10, isolation_level=None)
        db.row_factory = sqlite3.Row
        try:
            db.execute("PRAGMA busy_timeout=10000")
            db.execute("PRAGMA synchronous=FULL")
            yield db
        finally:
            db.close()

    @contextmanager
    def _transaction(self) -> Iterator[sqlite3.Connection]:
        with self._connection() as db:
            db.execute("BEGIN IMMEDIATE")
            try:
                yield db
                db.commit()
            except BaseException:
                db.rollback()
                raise

    def apply_verified_entitlement(self, event: VerifiedEntitlementEvent) -> bool:
        """Apply a verified event atomically; return False for replay/stale input.

        No signature, purchase or user authentication occurs here. This method
        belongs behind the future trusted verification adapter, never an HTTP
        entitlement-grant endpoint accepting client fields. A future period
        raises ValueError without changing database records; the adapter must
        resubmit it at or after period_start. No scheduler is implemented here.
        """
        if not isinstance(event, VerifiedEntitlementEvent):
            raise TypeError("requires an adapter-verified entitlement event")
        user = _identifier(event.user_id, "user_id")
        event_id = _identifier(event.event_id, "event_id")
        if (type(event.revision) is not int or not 0 <= event.revision < 2**63
                or type(event.revoked) is not bool):
            raise ValueError("invalid event revision or revocation state")
        transaction = _identifier(event.transaction_id, "transaction_id")
        start, end = _micros(event.period_start), _micros(event.period_end)
        if end <= start:
            raise ValueError("verified period_start must precede period_end")
        payload = (event.revision, transaction, start, end, int(event.revoked))
        with self._transaction() as db:
            if start > _micros(self.clock()):
                raise ValueError("verified entitlement period has not started; resubmit when effective")
            seen = db.execute("SELECT revision, transaction_id, period_start, period_end, revoked "
                              "FROM entitlement_events WHERE user_id=? AND event_id=?",
                              (user, event_id)).fetchone()
            if seen is not None:
                if tuple(seen) != payload:
                    raise ValueError("event_id was reused with a different verified state")
                return False
            period = db.execute("SELECT period_start, period_end FROM verified_periods "
                                "WHERE user_id=? AND transaction_id=?", (user, transaction)).fetchone()
            effective_end = end
            stale_period = False
            if period is not None:
                if start != period["period_start"]:
                    raise ValueError("verified transaction start cannot change on replay or restore")
                effective_end = max(end, period["period_end"])
                if end > period["period_end"]:
                    latest_revision = db.execute("SELECT MAX(revision) FROM entitlement_events "
                                                 "WHERE user_id=? AND transaction_id=?",
                                                 (user, transaction)).fetchone()[0]
                    if latest_revision is not None and event.revision <= latest_revision:
                        if event.revision == latest_revision and not event.revoked:
                            raise ValueError("an extension requires a newer verified state")
                        effective_end = period["period_end"]
                        stale_period = not event.revoked
                elif end < period["period_end"] and not event.revoked:
                    stale_period = True
            current = db.execute("SELECT * FROM entitlements WHERE user_id=?", (user,)).fetchone()
            apply = not stale_period
            if current is not None:
                if start < current["period_start"] or event.revision < current["revision"]:
                    apply = False
                elif event.revision == current["revision"]:
                    if current["revoked"]:
                        apply = False
                    elif event.revoked and transaction == current["transaction_id"]:
                        apply = True
                    elif (transaction, start, end) == (current["transaction_id"],
                                                       current["period_start"], current["period_end"]):
                        apply = False
                    else:
                        raise ValueError("conflicting states at the same revision")
            db.execute("INSERT INTO entitlement_events VALUES (?, ?, ?, ?, ?, ?, ?)",
                       (user, event_id, *payload))
            db.execute("INSERT INTO verified_periods VALUES (?, ?, ?, ?) "
                       "ON CONFLICT(user_id, transaction_id) DO UPDATE SET "
                       "period_end=MAX(verified_periods.period_end, excluded.period_end)",
                       (user, transaction, start, effective_end))
            if not apply:
                return False
            db.execute("INSERT INTO entitlements VALUES (?, ?, ?, ?, ?, ?, ?) "
                       "ON CONFLICT(user_id) DO UPDATE SET event_id=excluded.event_id, "
                       "revision=excluded.revision, transaction_id=excluded.transaction_id, "
                       "period_start=excluded.period_start, period_end=excluded.period_end, "
                       "revoked=excluded.revoked",
                       (user, event_id, event.revision, transaction, start, effective_end, int(event.revoked)))
            if event.revoked:
                db.execute("UPDATE actions SET state='revoked' WHERE user_id=? "
                           "AND plan='pro' AND state='reserved'", (user,))
            return True

    def _cycle(self, db: sqlite3.Connection, user: str, now: datetime) -> tuple[str, int, int, int]:
        entitlement = db.execute("SELECT * FROM entitlements WHERE user_id=?", (user,)).fetchone()
        stamp = _micros(now)
        if (entitlement is not None and not entitlement["revoked"]
                and entitlement["period_start"] <= stamp < entitlement["period_end"]):
            return ("pro", entitlement["period_start"], entitlement["period_end"], PRO_MONTHLY_LIMIT)
        start = now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
        return "free", _micros(start), _micros(_next_free_month(start)), FREE_MONTHLY_LIMIT

    @staticmethod
    def _expire(db: sqlite3.Connection, user: str, now: int) -> None:
        db.execute("UPDATE actions SET state='expired' WHERE user_id=? "
                   "AND state='reserved' AND expires_at<=?", (user, now))

    @staticmethod
    def _counts(db: sqlite3.Connection, user: str, plan: str, start: int) -> tuple[int, int]:
        row = db.execute("SELECT committed FROM usage WHERE user_id=? AND plan=? AND period_start=?",
                         (user, plan, start)).fetchone()
        reserved = db.execute("SELECT COUNT(*) FROM actions WHERE user_id=? AND plan=? "
                              "AND period_start=? AND state='reserved'", (user, plan, start)).fetchone()[0]
        return (row[0] if row is not None else 0), reserved

    @staticmethod
    def _action(row: sqlite3.Row, newly_reserved: bool = False) -> ActionReservation:
        return ActionReservation(row["user_id"], row["action_id"], row["state"], row["plan"],
                                 _datetime(row["period_start"]), _datetime(row["period_end"]),
                                 _datetime(row["expires_at"]), newly_reserved)

    def snapshot(self, user_id: str) -> UsageSnapshot:
        user = _identifier(user_id, "user_id")
        with self._transaction() as db:
            now = _utc(self.clock())
            self._expire(db, user, _micros(now))
            plan, start, end, limit = self._cycle(db, user, now)
            committed, reserved = self._counts(db, user, plan, start)
            return UsageSnapshot(plan, _datetime(start), _datetime(end), limit, committed, reserved)

    def reserve(self, user_id: str, action_id: str, *,
                lease: timedelta = DEFAULT_LEASE) -> ActionReservation:
        """Reserve one unit. Only a newly reserved action permits model execution."""
        user = _identifier(user_id, "user_id")
        action = _identifier(action_id, "action_id")
        if not isinstance(lease, timedelta) or not timedelta(0) < lease <= MAX_LEASE:
            raise ValueError("lease must be positive and at most 15 minutes")
        with self._transaction() as db:
            now = _utc(self.clock())
            self._expire(db, user, _micros(now))
            previous = db.execute("SELECT * FROM actions WHERE user_id=? AND action_id=?",
                                  (user, action)).fetchone()
            if previous is not None:
                return self._action(previous)
            plan, start, end, limit = self._cycle(db, user, now)
            used, reserved = self._counts(db, user, plan, start)
            state = "reserved" if used + reserved < limit else "quota_exceeded"
            expires = min(_micros(now + lease), end)
            db.execute("INSERT INTO actions VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                       (user, action, state, plan, start, end, limit, expires))
            row = db.execute("SELECT * FROM actions WHERE user_id=? AND action_id=?",
                             (user, action)).fetchone()
            return self._action(row, newly_reserved=state == "reserved")

    def commit(self, user_id: str, action_id: str, *, on_committed=None) -> ActionReservation:
        """Settle final success once; streaming previews may precede settlement.

        The caller marks completion only on committed and handles partial output
        cleanup on failure/cancellation. Terminal replays preserve their state.
        on_committed, when supplied, records associated success using the same
        SQLite connection and transaction. A failure rolls back the usage too.
        """
        return self._settle(user_id, action_id, commit=True, on_committed=on_committed)

    def cancel(self, user_id: str, action_id: str) -> ActionReservation:
        """Release a failed action's reservation once; committed units stay used."""
        return self._settle(user_id, action_id, commit=False)

    def _settle(self, user_id: str, action_id: str, *, commit: bool, on_committed=None) -> ActionReservation:
        user = _identifier(user_id, "user_id")
        action = _identifier(action_id, "action_id")
        with self._transaction() as db:
            self._expire(db, user, _micros(self.clock()))
            row = db.execute("SELECT * FROM actions WHERE user_id=? AND action_id=?",
                             (user, action)).fetchone()
            if row is None:
                raise KeyError("unknown action for this user")
            if row["state"] != "reserved":
                if row["state"] == "committed" and on_committed is not None:
                    on_committed(db)
                return self._action(row)
            state = "cancelled"
            if commit:
                db.execute("INSERT INTO usage VALUES (?, ?, ?, 0) ON CONFLICT DO NOTHING",
                           (user, row["plan"], row["period_start"]))
                changed = db.execute("UPDATE usage SET committed=committed+1 WHERE user_id=? "
                                     "AND plan=? AND period_start=? AND committed<?",
                                     (user, row["plan"], row["period_start"], row["quota"])).rowcount
                if changed != 1:
                    raise RuntimeError("usage invariant violated; final success must not be marked")
                state = "committed"
            db.execute("UPDATE actions SET state=? WHERE user_id=? AND action_id=?", (state, user, action))
            if state == "committed" and on_committed is not None:
                on_committed(db)
            return self._action(db.execute("SELECT * FROM actions WHERE user_id=? AND action_id=?",
                                           (user, action)).fetchone())
