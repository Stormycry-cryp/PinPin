"""Apple signature boundary. Network callers cannot select trust roots or modes.

Root DER files must be provisioned from https://www.apple.com/certificateauthority/.
The production adapter always performs online certificate status checks. Its sync
methods must run off the aiohttp event loop (see subscription_http.py).
"""

from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Callable, Protocol
from uuid import UUID

from appstoreserverlibrary.models.Environment import Environment
from appstoreserverlibrary.signed_data_verifier import (
    SignedDataVerifier, VerificationException, VerificationStatus,
)

UTC = timezone.utc
MONTHLY_PRODUCT = "com.pointout.app.pro.monthly"
MAX_JWS_BYTES = 64 * 1024


class SubscriptionError(Exception):
    """Safe public error. Never include tokens, signed payloads, or upstream text."""

    def __init__(self, code: str, message: str, status: int = 400):
        super().__init__(message)
        self.code, self.message, self.status = code, message, status


@dataclass(frozen=True)
class VerifiedAppIdentity:
    app_transaction_id: str
    bundle_id: str
    environment: str


@dataclass(frozen=True)
class VerifiedStoreTransaction:
    transaction_id: str
    original_transaction_id: str
    app_transaction_id: str
    product_id: str
    bundle_id: str
    environment: str
    purchase_ms: int
    expires_ms: int
    signed_ms: int
    revocation_ms: int | None = None
    app_account_token: str | None = None
    upgraded: bool = False


@dataclass(frozen=True)
class VerifiedNotification:
    notification_id: str
    notification_type: str
    signed_ms: int
    transaction: VerifiedStoreTransaction | None


class SubscriptionVerifier(Protocol):
    bundle_id: str
    environment: str

    def verify_app(self, signed: str) -> VerifiedAppIdentity: ...
    def verify_transaction(self, signed: str) -> VerifiedStoreTransaction: ...
    def verify_notification(self, signed: str) -> VerifiedNotification: ...


def identifier(value, field: str) -> str:
    if (not isinstance(value, str) or not value.strip() or value != value.strip()
            or len(value) > 256 or any(ord(c) < 32 for c in value)):
        raise SubscriptionError("invalid_signed_data", f"Missing or invalid {field}.")
    return value


def timestamp(value, field: str) -> int:
    # Also prevents datetime/SQLite overflow when structuring signed data.
    if type(value) is not int or not 0 <= value < 253402300800000:
        raise SubscriptionError("invalid_signed_data", f"Missing or invalid {field}.")
    return value


def validate_jws(signed: str) -> str:
    if not isinstance(signed, str) or not 0 < len(signed) <= MAX_JWS_BYTES:
        raise SubscriptionError("invalid_request", "A bounded signed JWS is required.")
    if not signed.isascii() or signed.count(".") != 2:
        raise SubscriptionError("invalid_signature", "Apple signature verification failed.")
    return signed


class AppleSubscriptionVerifier:
    def __init__(self, *, root_certificate_paths: list[str | Path],
                 bundle_id: str, environment: str, app_apple_id: int | None = None,
                 clock: Callable[[], datetime] | None = None):
        if environment not in ("Production", "Sandbox"):
            raise ValueError("only Production and Sandbox are supported")
        if environment == "Production" and (type(app_apple_id) is not int or app_apple_id <= 0):
            raise ValueError("Production requires a positive appAppleId")
        if not root_certificate_paths:
            raise ValueError("Apple root certificate paths are required")
        self.bundle_id = identifier(bundle_id, "bundleId")
        self.environment = environment
        self.clock = clock or (lambda: datetime.now(UTC))
        roots = [Path(path).read_bytes() for path in root_certificate_paths]
        # Fail startup for invalid DER / non-CA roots instead of advertising readiness.
        from cryptography import x509
        for root in roots:
            certificate = x509.load_der_x509_certificate(root)
            if not certificate.extensions.get_extension_for_class(x509.BasicConstraints).value.ca:
                raise ValueError("configured trust root is not a CA certificate")
        self._verifier = SignedDataVerifier(
            roots, True, Environment(environment), bundle_id, app_apple_id,
        )

    def _decode(self, method: str, signed: str):
        validate_jws(signed)
        try:
            return getattr(self._verifier, method)(signed)
        except VerificationException as error:
            if error.status == VerificationStatus.RETRYABLE_VERIFICATION_FAILURE:
                raise SubscriptionError("verification_unavailable", "Apple verification is temporarily unavailable.", 503) from None
            raise SubscriptionError("invalid_signature", "Apple signature verification failed.", 400) from None

    def _date(self, value, field: str) -> int:
        value = timestamp(value, field)
        if value > int((self.clock() + timedelta(minutes=5)).timestamp() * 1000):
            raise SubscriptionError("invalid_signed_data", "Apple signing date is in the future.")
        return value

    def verify_app(self, signed: str) -> VerifiedAppIdentity:
        data = self._decode("verify_and_decode_app_transaction", signed)
        self._date(data.receiptCreationDate, "receiptCreationDate")
        return VerifiedAppIdentity(identifier(data.appTransactionId, "appTransactionId"),
                                   self.bundle_id, self.environment)

    def verify_transaction(self, signed: str) -> VerifiedStoreTransaction:
        data = self._decode("verify_and_decode_signed_transaction", signed)
        if data.rawType != "Auto-Renewable Subscription":
            raise SubscriptionError("unsupported_product", "An auto-renewable subscription is required.")
        purchase = timestamp(data.purchaseDate, "purchaseDate")
        expires = timestamp(data.expiresDate, "expiresDate")
        if expires <= purchase:
            raise SubscriptionError("invalid_signed_data", "The transaction period is invalid.")
        signed_ms = self._date(data.signedDate, "signedDate")
        revoked = None if data.revocationDate is None else timestamp(data.revocationDate, "revocationDate")
        if revoked is not None and revoked > signed_ms:
            raise SubscriptionError("invalid_signed_data", "The revocation date exceeds the signing date.")
        account = data.appAccountToken
        if account is not None:
            try:
                account = str(UUID(account))
            except (ValueError, TypeError, AttributeError):
                raise SubscriptionError("invalid_signed_data", "The appAccountToken is invalid.") from None
        return VerifiedStoreTransaction(
            identifier(data.transactionId, "transactionId"),
            identifier(data.originalTransactionId, "originalTransactionId"),
            identifier(data.appTransactionId, "appTransactionId"),
            identifier(data.productId, "productId"), self.bundle_id, self.environment,
            purchase, expires, signed_ms, revoked, account, bool(data.isUpgraded),
        )

    def verify_notification(self, signed: str) -> VerifiedNotification:
        data = self._decode("verify_and_decode_notification", signed)
        if data.version != "2.0":
            raise SubscriptionError("invalid_signed_data", "Only Apple V2 notifications are supported.")
        signed_ms = self._date(data.signedDate, "signedDate")
        transaction = None
        if data.data is not None:
            if data.data.signedTransactionInfo:
                transaction = self.verify_transaction(data.data.signedTransactionInfo)
            if data.data.signedRenewalInfo:
                renewal = self._decode("verify_and_decode_renewal_info", data.data.signedRenewalInfo)
                if transaction is not None and renewal.originalTransactionId != transaction.original_transaction_id:
                    raise SubscriptionError("invalid_signed_data", "Notification transaction identifiers disagree.")
        if data.appData is not None and data.appData.signedAppTransactionInfo:
            self.verify_app(data.appData.signedAppTransactionInfo)
        return VerifiedNotification(identifier(data.notificationUUID, "notificationUUID"),
                                    identifier(data.rawNotificationType, "notificationType"), signed_ms, transaction)
