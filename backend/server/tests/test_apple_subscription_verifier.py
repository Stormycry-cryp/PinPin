"""Exercise Apple's actual library with local cryptographic fixtures.

The test CA, signatures and OCSP replies are synthetic. They verify rejection
paths and adapter binding, and are not evidence of Apple purchase acceptance.
Online OCSP checking remains enabled; only its HTTP transport is substituted.
No fixtures, root overrides or bypasses are exposed to the server's HTTP API.
"""

import base64
from datetime import datetime, timedelta, timezone
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509 import ocsp
from cryptography.x509.oid import AuthorityInformationAccessOID, NameOID, ObjectIdentifier
import jwt

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from apple_subscription_verifier import AppleSubscriptionVerifier, MONTHLY_PRODUCT, SubscriptionError

UTC = timezone.utc


class AppleVerifierTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="pinpin-local-test-ca-")
        cls.now = datetime.now(UTC)
        cls.stamp = int(cls.now.timestamp() * 1000)
        cls.keys = [ec.generate_private_key(ec.SECP256R1()) for _ in range(3)]
        cls.names = [x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, f"Local test only {i}")]) for i in range(3)]
        cls.certs = []
        for i in range(3):
            issuer = max(0, i-1)
            builder = (x509.CertificateBuilder().subject_name(cls.names[i]).issuer_name(cls.names[issuer])
                       .public_key(cls.keys[i].public_key()).serial_number(i+1)
                       .not_valid_before(cls.now - timedelta(days=1)).not_valid_after(cls.now + timedelta(days=1))
                       .add_extension(x509.BasicConstraints(ca=i<2, path_length=(2-i if i<2 else None)), True)
                       .add_extension(x509.KeyUsage(digital_signature=True, content_commitment=False,
                                                   key_encipherment=False, data_encipherment=False,
                                                   key_agreement=False, key_cert_sign=i<2, crl_sign=i<2,
                                                   encipher_only=False, decipher_only=False), True)
                       .add_extension(x509.SubjectKeyIdentifier.from_public_key(cls.keys[i].public_key()), False)
                       .add_extension(x509.AuthorityKeyIdentifier.from_issuer_public_key(cls.keys[issuer].public_key()), False))
            if i:
                builder = builder.add_extension(x509.AuthorityInformationAccess([
                    x509.AccessDescription(AuthorityInformationAccessOID.OCSP, x509.UniformResourceIdentifier("http://ocsp.fixture.invalid"))
                ]), False)
                oid = "1.2.840.113635.100.6.2.1" if i == 1 else "1.2.840.113635.100.6.11.1"
                builder = builder.add_extension(x509.UnrecognizedExtension(ObjectIdentifier(oid), b"\x05\x00"), False)
            cls.certs.append(builder.sign(cls.keys[issuer], hashes.SHA256()))
        cls.root_path = Path(cls.temp.name) / "synthetic-test-root.der"
        cls.root_path.write_bytes(cls.certs[0].public_bytes(serialization.Encoding.DER))
        cls.headers = {"x5c": [base64.b64encode(cert.public_bytes(serialization.Encoding.DER)).decode() for cert in reversed(cls.certs)]}

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def setUp(self):
        self.ocsp_expired = False
        self.ocsp_unavailable = False
        self.calls = 0
        self.transport = patch("appstoreserverlibrary.signed_data_verifier.requests.post", side_effect=self.ocsp_response)
        self.transport.start()
        self.addCleanup(self.transport.stop)
        self.verifier = self.new_verifier()

    def new_verifier(self, **changes):
        args = dict(root_certificate_paths=[self.root_path], bundle_id="com.pointout.app", environment="Sandbox")
        args.update(changes)
        return AppleSubscriptionVerifier(**args)

    def ocsp_response(self, url, *, data, **kwargs):
        self.calls += 1
        self.assertEqual(url, "http://ocsp.fixture.invalid")
        self.assertEqual(kwargs["timeout"], 30)
        if self.ocsp_unavailable:
            return SimpleNamespace(status_code=503, content=b"")
        request = ocsp.load_der_ocsp_request(data)
        index = request.serial_number - 1
        issuer = index - 1
        response = (ocsp.OCSPResponseBuilder()
                    .add_response(cert=self.certs[index], issuer=self.certs[issuer], algorithm=request.hash_algorithm,
                                  cert_status=ocsp.OCSPCertStatus.GOOD,
                                  this_update=self.now - timedelta(hours=2),
                                  next_update=self.now + (timedelta(hours=-1) if self.ocsp_expired else timedelta(hours=1)),
                                  revocation_time=None, revocation_reason=None)
                    .responder_id(ocsp.OCSPResponderEncoding.HASH, self.certs[issuer])
                    .sign(self.keys[issuer], hashes.SHA256()))
        return SimpleNamespace(status_code=200, content=response.public_bytes(serialization.Encoding.DER))

    def sign(self, payload, *, key=None):
        return jwt.encode(payload, key or self.keys[2], algorithm="ES256", headers=self.headers)

    def app(self, **changes):
        payload = dict(receiptType="Sandbox", bundleId="com.pointout.app", appTransactionId="app-alice",
                       receiptCreationDate=self.stamp, appAppleId=1234)
        payload.update(changes)
        return payload

    def transaction(self, **changes):
        payload = dict(environment="Sandbox", bundleId="com.pointout.app", appTransactionId="app-alice",
                       transactionId="t1", originalTransactionId="o1", productId=MONTHLY_PRODUCT,
                       type="Auto-Renewable Subscription", signedDate=self.stamp,
                       purchaseDate=self.stamp-86400000, expiresDate=self.stamp+86400000)
        payload.update(changes)
        return payload

    def notification(self, inner=None, **changes):
        payload = dict(notificationType="DID_RENEW", notificationUUID="uuid-1", version="2.0", signedDate=self.stamp,
                       data=dict(bundleId="com.pointout.app", environment="Sandbox", appAppleId=1234,
                                 signedTransactionInfo=inner or self.sign(self.transaction())))
        payload.update(changes)
        return payload

    def assert_rejected(self, method, signed, code="invalid_signature"):
        with self.assertRaises(SubscriptionError) as error:
            method(signed)
        self.assertEqual(error.exception.code, code)

    def test_actual_library_signature_and_ocsp_path_with_synthetic_test_chain(self):
        identity = self.verifier.verify_app(self.sign(self.app()))
        self.assertEqual(identity.app_transaction_id, "app-alice")
        self.assertEqual(self.calls, 2)
        self.assertTrue(self.verifier._verifier._enable_online_checks)

    def test_wrong_signature_and_unsigned_payload_are_rejected(self):
        forged = self.sign(self.app(), key=ec.generate_private_key(ec.SECP256R1()))
        self.assert_rejected(self.verifier.verify_app, forged)
        unsigned = jwt.encode(self.app(), "", algorithm="none")
        self.assert_rejected(self.verifier.verify_app, unsigned)

    def test_wrong_environment_bundle_and_production_apple_id_are_rejected(self):
        self.assert_rejected(self.verifier.verify_app, self.sign(self.app(receiptType="Production")))
        self.assert_rejected(self.verifier.verify_app, self.sign(self.app(bundleId="com.someone.else")))
        production = self.new_verifier(environment="Production", app_apple_id=5678)
        self.assert_rejected(production.verify_app, self.sign(self.app(receiptType="Production", appAppleId=1234)))

    def test_dual_environment_dispatch_still_performs_complete_official_verification(self):
        from subscription_environments import SubscriptionEnvironments
        from subscription_service import SubscriptionService
        with tempfile.TemporaryDirectory(prefix="pinpin-official-dual-test-") as directory:
            prod = self.new_verifier(environment="Production", app_apple_id=1234)
            services = [SubscriptionService(Path(directory) / (verifier.environment + ".sqlite"), verifier)
                        for verifier in (prod, self.verifier)]
            router = SubscriptionEnvironments(production=services[0], sandbox=services[1])
            tokens = []
            for environment in ("Production", "Sandbox"):
                signed = self.sign(self.app(receiptType=environment))
                tokens.append(router.create_session(signed)["access_token"])
            self.assertGreaterEqual(self.calls, 4)
            self.assertEqual([router.state(token)["limit"] for token in tokens], [20, 20])
            for token, environment in zip(tokens, ("Production", "Sandbox")):
                router.submit_transaction(token, self.sign(self.transaction(environment=environment)))
            self.assertEqual([router.state(token)["limit"] for token in tokens], [1000, 1000])
            wrong_key = ec.generate_private_key(ec.SECP256R1())
            self.assert_rejected(router.create_session, self.sign(self.app(), key=wrong_key))
            self.assert_rejected(router.create_session, self.sign(self.app(receiptType="LocalTesting")))
            self.assert_rejected(lambda signed: router.submit_transaction(tokens[0], signed),
                                 self.sign(self.transaction()))
            # Verified outer Production cannot carry an inner Sandbox transaction.
            outer = self.notification(data=dict(bundleId="com.pointout.app", environment="Production",
                                                appAppleId=1234, signedTransactionInfo=self.sign(self.transaction())))
            self.assert_rejected(router.accept_notification, self.sign(outer))
            forged_outer = self.notification()
            self.assert_rejected(router.accept_notification, self.sign(forged_outer, key=wrong_key))
            self.assertEqual([router.state(token)["limit"] for token in tokens], [1000, 1000])
            # A signed Production refund only changes that independent ledger.
            refunded = self.sign(self.transaction(environment="Production", revocationDate=self.stamp))
            outer = self.notification(notificationType="REFUND", data=dict(
                bundleId="com.pointout.app", environment="Production", appAppleId=1234,
                signedTransactionInfo=refunded))
            router.accept_notification(self.sign(outer))
            self.assertEqual([router.state(token)["limit"] for token in tokens], [20, 1000])
        self.assert_rejected(self.verifier.verify_transaction, self.sign(self.transaction(environment="Production")))
        self.assert_rejected(self.verifier.verify_transaction, self.sign(self.transaction(bundleId="com.someone.else")))

    def test_expired_ocsp_is_rejected_by_fixed_library(self):
        self.ocsp_expired = True
        self.assert_rejected(self.verifier.verify_app, self.sign(self.app()))

    def test_unavailable_ocsp_is_retryable_and_never_grants_identity(self):
        self.ocsp_unavailable = True
        self.assert_rejected(self.verifier.verify_app, self.sign(self.app()), "verification_unavailable")

    def test_environment_bypass_modes_and_missing_production_id_fail_startup(self):
        for environment in ("Xcode", "LocalTesting", "Sandbox "):
            with self.assertRaises(ValueError):
                self.new_verifier(environment=environment)
        with self.assertRaises(ValueError):
            self.new_verifier(environment="Production")
        with self.assertRaises(ValueError):
            self.new_verifier(root_certificate_paths=[])

    def test_missing_identity_and_future_signature_fail_closed(self):
        self.assert_rejected(self.verifier.verify_app, self.sign(self.app(appTransactionId=None)), "invalid_signed_data")
        self.assert_rejected(self.verifier.verify_app, self.sign(self.app(receiptCreationDate=self.stamp+3600000)), "invalid_signed_data")
        self.assert_rejected(self.verifier.verify_transaction, self.sign(self.transaction(appTransactionId=None)), "invalid_signed_data")

    def test_nested_notification_verifies_outer_transaction_and_renewal_signatures(self):
        self.assertEqual(self.verifier.verify_notification(self.sign(self.notification())).transaction.transaction_id, "t1")
        bad_inner = self.sign(self.transaction(), key=ec.generate_private_key(ec.SECP256R1()))
        self.assert_rejected(self.verifier.verify_notification, self.sign(self.notification(inner=bad_inner)))
        bad_outer = self.sign(self.notification(), key=ec.generate_private_key(ec.SECP256R1()))
        self.assert_rejected(self.verifier.verify_notification, bad_outer)
        payload = self.notification()
        payload["data"]["signedRenewalInfo"] = self.sign(dict(environment="Sandbox", originalTransactionId="o-other", signedDate=self.stamp))
        self.assert_rejected(self.verifier.verify_notification, self.sign(payload), "invalid_signed_data")
        payload["data"]["signedRenewalInfo"] = "not.a.signature"
        self.assert_rejected(self.verifier.verify_notification, self.sign(payload))

    def test_actual_period_and_optional_account_token_are_validated(self):
        self.assertEqual(self.verifier.verify_transaction(self.sign(self.transaction())).expires_ms, self.stamp+86400000)
        for changes in ({"expiresDate": self.stamp-86400000}, {"purchaseDate": None},
                        {"signedDate": self.stamp+3600000}, {"appAccountToken": "not-a-uuid"},
                        {"revocationDate": self.stamp+1000}):
            self.assert_rejected(self.verifier.verify_transaction, self.sign(self.transaction(**changes)), "invalid_signed_data")


if __name__ == "__main__":
    unittest.main()
