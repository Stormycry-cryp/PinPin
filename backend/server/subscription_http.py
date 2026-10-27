"""Mountable aiohttp subscription routes; not connected to the production gateway.

All synchronous verification (including Apple's OCSP) and SQLite work runs in a
bounded thread pool. A cancelled HTTP request does not free the worker's slot
until the underlying operation actually finishes. Never log request bodies or
Authorization headers; host/proxy access-log configuration must follow this too.
"""

import asyncio
from concurrent.futures import ThreadPoolExecutor
import json
import logging
import sqlite3

from aiohttp import web

from apple_subscription_verifier import SubscriptionError, validate_jws
from subscription_service import SubscriptionService

MAX_BODY_BYTES = 96 * 1024
LOG = logging.getLogger(__name__)


class SubscriptionHTTP:
    def __init__(self, service: SubscriptionService, *, workers: int = 4):
        if type(workers) is not int or not 1 <= workers <= 16:
            raise ValueError("workers must be between 1 and 16")
        self.service = service
        self._pool = ThreadPoolExecutor(max_workers=workers, thread_name_prefix="apple-subscription")
        self._slots = asyncio.Queue(maxsize=workers)
        for _ in range(workers):
            self._slots.put_nowait(None)
        self._futures = set()
        self._closed = False

    async def _run(self, method, *args, wait_for_slot=False):
        if self._closed:
            raise SubscriptionError("service_unavailable", "Subscription service is shutting down.", 503)
        if wait_for_slot:
            # Only already-admitted model requests use this for durable settlement.
            # Their count is bounded by the model concurrency limit; incoming HTTP
            # authentication/verification remains fail-fast, with no extra queue.
            await self._slots.get()
        else:
            try:
                self._slots.get_nowait()
            except asyncio.QueueEmpty:
                raise SubscriptionError("service_busy", "Subscription service is busy; retry shortly.", 503) from None
        future = asyncio.get_running_loop().run_in_executor(self._pool, method, *args)
        self._futures.add(future)

        def finished(done):
            self._futures.discard(done)
            self._slots.put_nowait(None)
            # Retrieve exceptions even when the original HTTP caller disconnected.
            if not done.cancelled():
                done.exception()

        future.add_done_callback(finished)
        return await asyncio.shield(future)

    async def close(self, app=None):
        self._closed = True
        if self._futures:
            await asyncio.gather(*self._futures, return_exceptions=True)
        self._pool.shutdown(wait=False, cancel_futures=True)

    @staticmethod
    async def _body(request: web.Request, field: str, *, validator=validate_jws):
        if request.headers.get("Content-Encoding", "identity").lower() != "identity":
            raise SubscriptionError("invalid_request", "Compressed request bodies are not supported.", 415)
        if request.content_type != "application/json":
            raise SubscriptionError("invalid_request", "Content-Type must be application/json.", 415)
        if request.content_length is not None and request.content_length > MAX_BODY_BYTES:
            raise SubscriptionError("request_too_large", "Subscription request body is too large.", 413)
        body = bytearray()
        async for chunk in request.content.iter_chunked(8192):
            body.extend(chunk)
            if len(body) > MAX_BODY_BYTES:
                raise SubscriptionError("request_too_large", "Subscription request body is too large.", 413)

        def unique_object(pairs):
            result = {}
            for key, value in pairs:
                if key in result:
                    raise ValueError("duplicate field")
                result[key] = value
            return result

        try:
            value = json.loads(body, object_pairs_hook=unique_object)
        except (ValueError, UnicodeError, RecursionError):
            raise SubscriptionError("invalid_request", "Request body must be valid JSON.") from None
        if not isinstance(value, dict) or set(value) != {field}:
            raise SubscriptionError("invalid_request", f"Only {field} is accepted.")
        return validator(value[field])

    @staticmethod
    def _token(request: web.Request) -> str:
        values = request.headers.getall("Authorization", [])
        if len(values) != 1:
            raise SubscriptionError("unauthorized", "A Bearer subscription session is required.", 401)
        pieces = values[0].split(" ")
        if len(pieces) != 2 or pieces[0].lower() != "bearer" or not pieces[1]:
            raise SubscriptionError("unauthorized", "A Bearer subscription session is required.", 401)
        return pieces[1]

    async def session(self, request):
        return await self._run(self.service.create_session, await self._body(request, "signed_app_transaction"))

    async def state(self, request):
        return await self._run(self.service.state, self._token(request))

    async def transaction(self, request):
        token = self._token(request)
        signed = await self._body(request, "signed_transaction")
        return await self._run(self.service.submit_transaction, token, signed)

    async def notification(self, request):
        return await self._run(self.service.accept_notification, await self._body(request, "signedPayload"))

    async def cancel_action(self, request):
        token = self._token(request)
        action_id = await self._body(request, "action_id", validator=lambda value: value)
        return await self._run(self.service.cancel_action, token, action_id)

    @staticmethod
    def _handler(method):
        async def handle(request):
            try:
                value = await method(request)
                status = 200
            except SubscriptionError as error:
                value = {"error": {"code": error.code, "message": error.message}}
                status = error.status
            except sqlite3.Error:
                LOG.error("Subscription storage operation failed")
                value = {"error": {"code": "service_unavailable", "message": "Subscription storage is temporarily unavailable."}}
                status = 503
            except Exception:
                # Deliberately omit exception repr/traceback: third-party errors
                # may embed the original signed object or headers.
                LOG.error("Subscription request failed")
                value = {"error": {"code": "internal_error", "message": "Subscription request could not be completed."}}
                status = 500
            return web.json_response(value, status=status, headers={"Cache-Control": "no-store"})
        return handle

    def mount(self, app: web.Application, *, prefix: str = "/ping/v1"):
        app.router.add_post(prefix + "/subscription/session", self._handler(self.session))
        app.router.add_get(prefix + "/subscription/state", self._handler(self.state))
        app.router.add_post(prefix + "/subscription/transaction", self._handler(self.transaction))
        app.router.add_post(prefix + "/subscription/apple-notifications", self._handler(self.notification))
        app.router.add_post(prefix + "/subscription/actions/cancel", self._handler(self.cancel_action))
        app.on_cleanup.append(self.close)


def mount_subscription_routes(app: web.Application, service: SubscriptionService, *,
                              prefix: str = "/ping/v1", workers: int = 4) -> SubscriptionHTTP:
    routes = SubscriptionHTTP(service, workers=workers)
    routes.mount(app, prefix=prefix)
    return routes
