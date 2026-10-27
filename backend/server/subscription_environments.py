"""One fixed API for Apple Production and Sandbox with independent ledgers.

Unsigned JWS fields only select a configured verifier. That verifier must still
authenticate the complete Apple object; verification failures never fall back to
another environment. Network callers cannot configure trust or add environments.
"""

import base64
import binascii
import json
from pathlib import Path

from apple_subscription_verifier import SubscriptionError, validate_jws
from subscription_service import SubscriptionService


def _unique_object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError("duplicate field")
        value[key] = item
    return value


def _environment_hint(signed: str, *, notification=False) -> str:
    validate_jws(signed)
    try:
        encoded = signed.split(".")[1]
        payload = json.loads(base64.b64decode(encoded + "=" * (-len(encoded) % 4),
                                            altchars=b"-_", validate=True),
                             object_pairs_hook=_unique_object)
        if not isinstance(payload, dict):
            raise ValueError()
        if notification:
            # Subscription notifications use data; summary/appData cover Apple's
            # other signed V2 forms. The official verifier checks the same scope.
            containers = [payload[key] for key in ("data", "summary", "appData")
                          if payload.get(key) is not None]
            if len(containers) != 1 or not isinstance(containers[0], dict):
                raise ValueError()
            environment = containers[0].get("environment")
        else:
            environment = payload.get("receiptType")
        if environment not in ("Production", "Sandbox"):
            raise ValueError()
        return environment
    except (ValueError, TypeError, UnicodeError, RecursionError, binascii.Error):
        raise SubscriptionError("invalid_signature", "Apple signature verification failed.") from None


class SubscriptionEnvironments:
    def __init__(self, *, production: SubscriptionService, sandbox: SubscriptionService):
        if (production.verifier.environment, sandbox.verifier.environment) != ("Production", "Sandbox"):
            raise ValueError("explicit Production and Sandbox services are required")
        if production.verifier.bundle_id != sandbox.verifier.bundle_id:
            raise ValueError("both environments must belong to the same app")
        prod_path, sandbox_path = Path(production.database), Path(sandbox.database)
        if prod_path.resolve() == sandbox_path.resolve() or prod_path.samefile(sandbox_path):
            raise ValueError("Production and Sandbox require separate databases")
        self.services = (production, sandbox)

    def _signed_service(self, signed, *, notification=False):
        environment = _environment_hint(signed, notification=notification)
        return next(service for service in self.services if service.verifier.environment == environment)

    def resolve_session(self, token):
        matches = []
        for service in self.services:
            try:
                matches.append((service, service.authenticate(token)))
            except SubscriptionError as error:
                if error.code != "unauthorized":
                    raise
        if len(matches) != 1:
            raise SubscriptionError("unauthorized", "A valid subscription session is required.", 401)
        return matches[0]

    def create_session(self, signed_app_transaction):
        return self._signed_service(signed_app_transaction).create_session(signed_app_transaction)

    def state(self, token):
        service, principal = self.resolve_session(token)
        return service.state_for_user(principal.user_id)

    def cancel_action(self, token, action_id):
        service, _ = self.resolve_session(token)
        return service.cancel_action(token, action_id)

    def submit_transaction(self, token, signed_transaction):
        service, _ = self.resolve_session(token)
        # The authenticated session selects the verifier, never the transaction's
        # untrusted hint. Cross-environment transactions fail full verification.
        return service.submit_transaction(token, signed_transaction)

    def accept_notification(self, signed_payload):
        return self._signed_service(signed_payload, notification=True).accept_notification(signed_payload)
