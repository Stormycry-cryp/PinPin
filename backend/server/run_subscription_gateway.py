"""Standalone commercial service. Importing this module performs no setup.

Provision DER Apple CA roots from Apple's certificate authority page. This
process never downloads roots or reads the private-test gateway's credentials.
--check-config only reads configuration, certificates and path metadata; it
does not create databases, make directories, run OCSP or contact models.
"""

import argparse
from dataclasses import dataclass
from datetime import datetime, timezone
import logging
import os
from pathlib import Path
import stat
import sys

from aiohttp import web
from cryptography import x509

from apple_subscription_verifier import AppleSubscriptionVerifier
from subscription_environments import SubscriptionEnvironments
from subscription_gateway import CommercialGatewaySettings, create_subscription_gateway
from subscription_service import SubscriptionService

API_PREFIX = "/pinpin/v1"
DATABASE_NAMES = ("production.sqlite3", "sandbox.sqlite3")


class ConfigurationError(ValueError):
    """Only fixed, nonsecret diagnostic messages may cross the CLI boundary."""


@dataclass(frozen=True)
class RuntimeConfig:
    settings: CommercialGatewaySettings
    app_apple_id: int
    roots: tuple[Path, ...]
    database_directory: Path
    port: int = 8790


def _required(environment, name):
    value = environment.get(name)
    if not isinstance(value, str) or not value.strip() or value != value.strip() or any(ord(c) < 32 for c in value):
        raise ConfigurationError(f"{name} is required and must be valid.")
    return value


def load_config(environment=None) -> RuntimeConfig:
    environment = os.environ if environment is None else environment
    settings = CommercialGatewaySettings(_required(environment, "BEATAPI_API_KEY"),
                                         _required(environment, "PINPIN_COMMERCIAL_API_KEY"))
    raw_id = _required(environment, "PINPIN_APP_APPLE_ID")
    if len(raw_id) > 19 or not raw_id.isascii() or not raw_id.isdigit() or not 0 < int(raw_id) < 2**63:
        raise ConfigurationError("PINPIN_APP_APPLE_ID must be a positive Apple app ID.")
    port = environment.get("PINPIN_SUBSCRIPTION_PORT", "8790")
    if not isinstance(port, str) or len(port) > 5 or not port.isascii() or not port.isdigit() or not 1 <= int(port) <= 65535:
        raise ConfigurationError("PINPIN_SUBSCRIPTION_PORT must be between 1 and 65535.")
    roots_directory = Path(_required(environment, "PINPIN_APPLE_ROOTS_DIR"))
    directory = Path(_required(environment, "PINPIN_SUBSCRIPTION_DB_DIR"))
    if not roots_directory.is_absolute():
        raise ConfigurationError("PINPIN_APPLE_ROOTS_DIR must be an absolute directory.")
    if not directory.is_absolute() or directory == Path(directory.anchor):
        raise ConfigurationError("PINPIN_SUBSCRIPTION_DB_DIR must be a dedicated absolute directory.")
    try:
        if not roots_directory.is_dir():
            raise ConfigurationError("PINPIN_APPLE_ROOTS_DIR must contain provisioned Apple DER roots.")
        roots = tuple(sorted(path for path in roots_directory.iterdir()
                             if path.suffix.lower() in (".cer", ".der")))
        if not roots:
            raise ConfigurationError("PINPIN_APPLE_ROOTS_DIR must contain provisioned Apple DER roots.")
        now = datetime.now(timezone.utc)
        for path in roots:
            if not path.is_file():
                raise ValueError()
            certificate = x509.load_der_x509_certificate(path.read_bytes())
            if (not certificate.extensions.get_extension_for_class(x509.BasicConstraints).value.ca
                    or not certificate.not_valid_before_utc <= now < certificate.not_valid_after_utc):
                raise ValueError()
    except ConfigurationError:
        raise
    except (OSError, ValueError, x509.ExtensionNotFound):
        raise ConfigurationError("PINPIN_APPLE_ROOTS_DIR contains an unreadable, invalid or expired DER CA root.") from None
    _check_database_paths(directory)
    return RuntimeConfig(settings, int(raw_id), roots, directory, int(port))


def _check_database_paths(directory):
    try:
        if directory.is_symlink() or (directory.exists() and not directory.is_dir()):
            raise ConfigurationError("PINPIN_SUBSCRIPTION_DB_DIR must be a real dedicated directory.")
        parent = directory if directory.exists() else directory.parent
        if not parent.is_dir() or not os.access(parent, os.W_OK | os.X_OK):
            raise ConfigurationError("PINPIN_SUBSCRIPTION_DB_DIR or its parent must exist and be writable.")
        for name in DATABASE_NAMES:
            path = directory / name
            if path.is_symlink():
                raise ConfigurationError("Subscription databases must not be symbolic links.")
            if path.exists() and (not stat.S_ISREG(path.stat().st_mode) or path.stat().st_nlink != 1):
                raise ConfigurationError("Subscription databases must be independent regular files.")
    except OSError:
        raise ConfigurationError("Subscription database paths cannot be inspected.") from None


def build_application(config: RuntimeConfig):
    # Only runtime initialization mutates the explicitly configured state path.
    os.umask(0o077)
    directory = config.database_directory
    _check_database_paths(directory)
    directory.mkdir(mode=0o700, exist_ok=True)
    directory.chmod(0o700)
    services = []
    for environment, name in zip(("Production", "Sandbox"), DATABASE_NAMES):
        path = directory / name
        if path.exists():
            path.chmod(0o600)
        verifier = AppleSubscriptionVerifier(root_certificate_paths=list(config.roots),
            bundle_id="com.pointout.app", environment=environment, app_apple_id=config.app_apple_id)
        services.append(SubscriptionService(path, verifier))
        path.chmod(0o600)
    environments = SubscriptionEnvironments(production=services[0], sandbox=services[1])
    return create_subscription_gateway(config.settings, environments, prefix=API_PREFIX)


def main(argv=None):
    parser = argparse.ArgumentParser(description="PinPin commercial subscription gateway")
    parser.add_argument("--check-config", action="store_true", help="validate configuration without startup or writes")
    args = parser.parse_args(argv)
    try:
        config = load_config()
    except ConfigurationError as error:
        print(f"Configuration error: {error}", file=sys.stderr)
        return 2
    if args.check_config:
        print("Configuration valid: Production + Sandbox; /pinpin/v1; loopback listener.")
        return 0
    logging.basicConfig(level=logging.WARNING, format="%(name)s %(levelname)s %(message)s")
    try:
        app = build_application(config)
        web.run_app(app, host="127.0.0.1", port=config.port, access_log=None,
                    handler_cancellation=True, shutdown_timeout=5, print=None)
    except Exception:
        print("Commercial subscription service could not start; inspect configuration and state permissions.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
