"""Durable authenticated subscription state, sharing the usage ledger's SQLite file.

Only the verifier creates trusted Apple records. The normalized journal retains
provider dates; a separate monotonic projection revision orders complete user
states for the ledger. Saving a journal entry never itself grants another quota.
Call refresh_entitlement before reserving usage for an authenticated user. No
production gateway is wired here and no scheduler is required for future cycles.
"""

from contextlib import contextmanager
from dataclasses import asdict, dataclass
from datetime import datetime, timedelta, timezone
import hashlib
import json
from pathlib import Path
import secrets
import sqlite3
from typing import Callable
from uuid import UUID, uuid4

from apple_subscription_verifier import (
    MONTHLY_PRODUCT, SubscriptionError, SubscriptionVerifier,
    VerifiedAppIdentity, VerifiedNotification, VerifiedStoreTransaction,
)
from subscriptions import SubscriptionLedger, VerifiedEntitlementEvent

UTC = timezone.utc
SESSION_TTL = timedelta(days=30)
TRANSACTION_NOTIFICATIONS = frozenset({
    "SUBSCRIBED", "DID_RENEW", "DID_CHANGE_RENEWAL_PREF", "DID_CHANGE_RENEWAL_STATUS",
    "DID_FAIL_TO_RENEW", "EXPIRED", "GRACE_PERIOD_EXPIRED", "OFFER_REDEEMED",
    "PRICE_INCREASE", "REFUND", "REFUND_REVERSED", "REVOKE", "RENEWAL_EXTENDED",
})


def _ms(value: datetime) -> int:
    if value.utcoffset() is None:
        raise ValueError("clock must be timezone-aware")
    return int(value.timestamp() * 1000)


def _date(value: int) -> datetime:
    return datetime.fromtimestamp(value / 1000, UTC)


def _iso(value: datetime) -> str:
    return value.astimezone(UTC).isoformat().replace("+00:00", "Z")


def _digest(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def _canonical(value) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


@dataclass(frozen=True)
class SessionPrincipal:
    user_id: str
    app_transaction_id: str
    app_account_token: str


class SubscriptionService:
    def __init__(self, database: str | Path, verifier: SubscriptionVerifier, *,
                 clock: Callable[[], datetime] | None = None):
        self.database = str(database)
        self.verifier = verifier
        if verifier.environment not in ("Production", "Sandbox"):
            raise ValueError("the subscription service requires Production or Sandbox")
        self.clock = clock or (lambda: datetime.now(UTC))
        self.ledger = SubscriptionLedger(database, clock=self.clock)
        with self._connection() as db:
            db.executescript("""
                CREATE TABLE IF NOT EXISTS subscription_config (
                    singleton INTEGER PRIMARY KEY CHECK(singleton=1),
                    bundle_id TEXT NOT NULL, environment TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS subscription_identities (
                    user_id TEXT PRIMARY KEY, app_transaction_id TEXT NOT NULL UNIQUE,
                    app_account_token TEXT NOT NULL UNIQUE
                );
                CREATE TABLE IF NOT EXISTS subscription_sessions (
                    token_digest TEXT PRIMARY KEY, user_id TEXT NOT NULL,
                    expires_ms INTEGER NOT NULL
                );
                CREATE INDEX IF NOT EXISTS subscription_sessions_expiry
                    ON subscription_sessions(expires_ms);
                CREATE TABLE IF NOT EXISTS subscription_owners (
                    original_id TEXT PRIMARY KEY, user_id TEXT NOT NULL,
                    app_transaction_id TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS subscription_transactions (
                    transaction_id TEXT PRIMARY KEY, original_id TEXT NOT NULL,
                    app_transaction_id TEXT NOT NULL, product_id TEXT NOT NULL,
                    purchase_ms INTEGER NOT NULL, expires_ms INTEGER NOT NULL,
                    signed_ms INTEGER NOT NULL, revocation_ms INTEGER,
                    app_account_token TEXT, upgraded INTEGER NOT NULL
                );
                CREATE INDEX IF NOT EXISTS subscription_transactions_original
                    ON subscription_transactions(original_id, purchase_ms);
                CREATE TABLE IF NOT EXISTS subscription_notifications (
                    notification_id TEXT PRIMARY KEY, content_digest TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS subscription_projections (
                    user_id TEXT PRIMARY KEY, revision INTEGER NOT NULL,
                    transaction_id TEXT NOT NULL, purchase_ms INTEGER NOT NULL,
                    expires_ms INTEGER NOT NULL, revoked INTEGER NOT NULL
                );
            """)
        with self._transaction() as db:
            db.execute("INSERT INTO subscription_config VALUES (1, ?, ?) ON CONFLICT DO NOTHING",
                       (verifier.bundle_id, verifier.environment))
            scope = db.execute("SELECT bundle_id, environment FROM subscription_config").fetchone()
            if tuple(scope) != (verifier.bundle_id, verifier.environment):
                raise ValueError("subscription database belongs to another app or environment")

    @contextmanager
    def _connection(self):
        db = sqlite3.connect(self.database, isolation_level=None, timeout=10)
        db.row_factory = sqlite3.Row
        try:
            db.execute("PRAGMA synchronous=FULL")
            yield db
        finally:
            db.close()

    @contextmanager
    def _transaction(self):
        with self._connection() as db:
            db.execute("BEGIN IMMEDIATE")
            try:
                yield db
                db.commit()
            except BaseException:
                db.rollback()
                raise

    def _scope(self, value):
        if (value.bundle_id, value.environment) != (self.verifier.bundle_id, self.verifier.environment):
            raise SubscriptionError("invalid_signed_data", "Apple app or environment mismatch.")

    def create_session(self, signed_app_transaction: str) -> dict:
        identity = self.verifier.verify_app(signed_app_transaction)
        if not isinstance(identity, VerifiedAppIdentity) or not identity.app_transaction_id:
            raise SubscriptionError("invalid_signed_data", "A verified app transaction identity is required.")
        self._scope(identity)
        user_id = _digest(_canonical([identity.environment, identity.bundle_id, identity.app_transaction_id]))
        token = secrets.token_urlsafe(48)
        now = self.clock()
        expires = now + SESSION_TTL
        with self._transaction() as db:
            db.execute("INSERT INTO subscription_identities VALUES (?, ?, ?) ON CONFLICT DO NOTHING",
                       (user_id, identity.app_transaction_id, str(uuid4())))
            row = db.execute("SELECT * FROM subscription_identities WHERE user_id=?", (user_id,)).fetchone()
            db.execute("DELETE FROM subscription_sessions WHERE expires_ms<=?", (_ms(now),))
            db.execute("INSERT INTO subscription_sessions VALUES (?, ?, ?)",
                       (_digest(token), user_id, _ms(expires)))
        return {"access_token": token, "expires_at": _iso(expires), "app_account_token": row["app_account_token"]}

    def authenticate(self, token: str) -> SessionPrincipal:
        if not isinstance(token, str) or not 32 <= len(token) <= 256 or not token.isascii():
            raise SubscriptionError("unauthorized", "A valid subscription session is required.", 401)
        with self._connection() as db:
            row = db.execute("SELECT i.* FROM subscription_sessions s JOIN subscription_identities i "
                             "ON i.user_id=s.user_id WHERE token_digest=? AND expires_ms>?",
                             (_digest(token), _ms(self.clock()))).fetchone()
        if row is None:
            raise SubscriptionError("unauthorized", "The subscription session is missing or expired.", 401)
        return SessionPrincipal(row["user_id"], row["app_transaction_id"], row["app_account_token"])

    def state(self, token: str) -> dict:
        principal = self.authenticate(token)
        return self.state_for_user(principal.user_id)

    def cancel_action(self, token: str, action_id: str) -> dict:
        principal = self.authenticate(token)
        try:
            if not isinstance(action_id, str) or len(action_id) != 36:
                raise ValueError()
            action = UUID(action_id)
            if action.int == 0:
                raise ValueError()
            action_id = str(action)
        except (ValueError, TypeError, AttributeError):
            raise SubscriptionError("invalid_action_id", "A valid action UUID is required.") from None
        try:
            result = self.ledger.cancel(principal.user_id, action_id)
        except KeyError:
            # Unknown and another user's action are indistinguishable. Never
            # reserve or create state as part of this cleanup-only endpoint.
            raise SubscriptionError("action_not_found", "The action was not found.", 404) from None
        return {"action_id": action_id, "state": result.state}

    def state_for_user(self, user_id: str) -> dict:
        """Internal API: user_id must come from authenticate, never request JSON."""
        self.refresh_entitlement(user_id)
        state = self.ledger.snapshot(user_id)
        return {"plan": state.plan, "period_start": _iso(state.period_start),
                "period_end": _iso(state.period_end), "limit": state.limit,
                "committed": state.committed, "reserved": state.reserved,
                "remaining": state.remaining}

    def submit_transaction(self, token: str, signed_transaction: str) -> dict:
        principal = self.authenticate(token)
        value = self.verifier.verify_transaction(signed_transaction)
        self._validate_transaction(value)
        if value.product_id != MONTHLY_PRODUCT:
            raise SubscriptionError("unsupported_product", "This subscription product is not supported.")
        self._ownership(value, principal)
        with self._transaction() as db:
            self._check_original(db, value, principal)
            # Reconcile orphan notifications before binding. They may already
            # contain a later refund than the client purchase being restored.
            for row in db.execute("SELECT * FROM subscription_transactions WHERE original_id=?",
                                  (value.original_transaction_id,)).fetchall():
                self._ownership(self._stored(row), principal)
            self._store_transaction(db, value)
            db.execute("INSERT INTO subscription_owners VALUES (?, ?, ?) ON CONFLICT DO NOTHING",
                       (value.original_transaction_id, principal.user_id, principal.app_transaction_id))
        return self.state_for_user(principal.user_id)

    def accept_notification(self, signed_payload: str) -> dict:
        notification = self.verifier.verify_notification(signed_payload)
        if not isinstance(notification, VerifiedNotification):
            raise SubscriptionError("invalid_signed_data", "A verified notification is required.")
        digest = _digest(_canonical(asdict(notification)))
        user_id = None
        with self._transaction() as db:
            existing = db.execute("SELECT content_digest FROM subscription_notifications WHERE notification_id=?",
                                  (notification.notification_id,)).fetchone()
            if existing is not None and existing[0] != digest:
                raise SubscriptionError("notification_conflict", "Notification identity conflicts with stored data.", 409)
            value = notification.transaction
            if (notification.notification_type in TRANSACTION_NOTIFICATIONS
                    and value is not None and value.product_id == MONTHLY_PRODUCT):
                self._validate_transaction(value)
                if notification.notification_type in ("REFUND", "REVOKE") and value.revocation_ms is None:
                    raise SubscriptionError("invalid_signed_data", "A revocation notification requires a revocation date.")
                owner = db.execute("SELECT i.* FROM subscription_owners o JOIN subscription_identities i "
                                   "ON i.user_id=o.user_id WHERE o.original_id=?",
                                   (value.original_transaction_id,)).fetchone()
                if owner is not None:
                    principal = SessionPrincipal(owner["user_id"], owner["app_transaction_id"], owner["app_account_token"])
                    self._ownership(value, principal)
                    user_id = principal.user_id
                self._store_transaction(db, value)
            db.execute("INSERT INTO subscription_notifications VALUES (?, ?) ON CONFLICT DO NOTHING",
                       (notification.notification_id, digest))
        if user_id is not None:
            # Also replay projection on duplicate delivery after a process crash.
            self.refresh_entitlement(user_id)
        return {"status": "ok"}

    def _validate_transaction(self, value):
        if not isinstance(value, VerifiedStoreTransaction):
            raise SubscriptionError("invalid_signed_data", "A verified transaction is required.")
        self._scope(value)
        if value.purchase_ms >= value.expires_ms:
            raise SubscriptionError("invalid_signed_data", "The transaction period is invalid.")

    @staticmethod
    def _ownership(value, principal):
        if value.app_transaction_id != principal.app_transaction_id:
            raise SubscriptionError("ownership_mismatch", "This purchase belongs to another app identity.", 403)
        if value.app_account_token is not None and value.app_account_token != principal.app_account_token:
            raise SubscriptionError("ownership_mismatch", "This purchase belongs to another account token.", 403)

    @staticmethod
    def _check_original(db, value, principal):
        owner = db.execute("SELECT user_id, app_transaction_id FROM subscription_owners WHERE original_id=?",
                           (value.original_transaction_id,)).fetchone()
        if owner is not None and tuple(owner) != (principal.user_id, principal.app_transaction_id):
            raise SubscriptionError("ownership_mismatch", "The original purchase already has an owner.", 403)

    def _stored(self, row):
        return VerifiedStoreTransaction(row["transaction_id"], row["original_id"], row["app_transaction_id"],
                                        row["product_id"], self.verifier.bundle_id, self.verifier.environment,
                                        row["purchase_ms"], row["expires_ms"], row["signed_ms"],
                                        row["revocation_ms"], row["app_account_token"], bool(row["upgraded"]))

    def _store_transaction(self, db, value):
        row = db.execute("SELECT * FROM subscription_transactions WHERE transaction_id=?", (value.transaction_id,)).fetchone()
        immutable = (value.original_transaction_id, value.app_transaction_id, value.product_id, value.purchase_ms)
        expires_ms = value.expires_ms
        if row is not None:
            if (row["original_id"], row["app_transaction_id"], row["product_id"],
                    row["purchase_ms"]) != immutable:
                raise SubscriptionError("transaction_conflict", "Verified transaction details changed.", 409)
            if (row["app_account_token"] is not None and value.app_account_token is not None
                    and row["app_account_token"] != value.app_account_token):
                raise SubscriptionError("ownership_mismatch", "The transaction account token changed.", 403)
            if value.signed_ms < row["signed_ms"]:
                return
            if value.signed_ms == row["signed_ms"]:
                # A revoked state wins a tie, regardless of arrival order.
                if row["revocation_ms"] is not None or row["upgraded"]:
                    return
                if value.expires_ms != row["expires_ms"] and value.revocation_ms is None and not value.upgraded:
                    raise SubscriptionError("transaction_conflict", "An extension requires a newer signed state.", 409)
                if value.revocation_ms is None and not value.upgraded:
                    return
            # Apple may extend the same transaction. It remains one quota cycle.
            # Retain an already verified extension when a refund uses older dates.
            expires_ms = (row["expires_ms"] if value.signed_ms == row["signed_ms"]
                          else max(row["expires_ms"], value.expires_ms))
        account = value.app_account_token or (row["app_account_token"] if row is not None else None)
        db.execute("INSERT INTO subscription_transactions VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) "
                   "ON CONFLICT(transaction_id) DO UPDATE SET signed_ms=excluded.signed_ms, "
                   "expires_ms=excluded.expires_ms, revocation_ms=excluded.revocation_ms, app_account_token=excluded.app_account_token, "
                   "upgraded=excluded.upgraded",
                   (value.transaction_id, *immutable, expires_ms, value.signed_ms, value.revocation_ms, account, int(value.upgraded)))

    def refresh_entitlement(self, user_id: str):
        """Project the newest effective period, then replay safely into the ledger.

        Future transactions are journaled but cannot switch a current quota.
        Latest period remains selected after expiry/refund; older periods never
        resurrect. Projection writes and revisions serialize across processes.
        A crash between projection commit and ledger apply is recovered by the
        next state/notification/usage request, using the exact persisted event.
        """
        now = _ms(self.clock())
        with self._transaction() as db:
            row = db.execute("SELECT t.* FROM subscription_transactions t JOIN subscription_owners o "
                             "ON o.original_id=t.original_id WHERE o.user_id=? AND t.purchase_ms<=? "
                             "ORDER BY t.purchase_ms DESC, t.transaction_id DESC LIMIT 1", (user_id, now)).fetchone()
            if row is None:
                return
            revoked = int(bool(row["upgraded"]) or (row["revocation_ms"] is not None and row["revocation_ms"] <= now))
            payload = (row["transaction_id"], row["purchase_ms"], row["expires_ms"], revoked)
            previous = db.execute("SELECT * FROM subscription_projections WHERE user_id=?", (user_id,)).fetchone()
            if previous is not None and tuple(previous)[2:] == payload:
                revision = previous["revision"]
            else:
                revision = 1 if previous is None else previous["revision"] + 1
                db.execute("INSERT INTO subscription_projections VALUES (?, ?, ?, ?, ?, ?) "
                           "ON CONFLICT(user_id) DO UPDATE SET revision=excluded.revision, "
                           "transaction_id=excluded.transaction_id, purchase_ms=excluded.purchase_ms, "
                           "expires_ms=excluded.expires_ms, revoked=excluded.revoked", (user_id, revision, *payload))
        self.ledger.apply_verified_entitlement(VerifiedEntitlementEvent(
            user_id, f"apple-projection-{revision}", revision, payload[0],
            _date(payload[1]), _date(payload[2]), bool(payload[3]),
        ))
