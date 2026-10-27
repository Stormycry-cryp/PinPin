"""Commercial model gateway with durable per-operation phases and quota settlement.

One authenticated user operation reserves one usage unit and may claim decision
and answer once each. Answer may begin while decision is still running, matching
the native client's short Jev timeout and fallback. Only a validated final answer
commits; previews stream immediately. No input, prompt, screenshot or answer is
stored. Configure separately from the private-test gateway; no shared app token
or personal-plan API credential is used here.
"""

from __future__ import annotations

import asyncio
from collections import deque
from dataclasses import dataclass, field
from datetime import datetime, timezone
import json
import logging
import math
import os
import re
import sqlite3
import time
from urllib.parse import urlsplit
from uuid import UUID

import aiohttp
from aiohttp import web

from apple_subscription_verifier import AppleSubscriptionVerifier, SubscriptionError
from gateway import (DECISION_MODEL, DECISION_URL, EXPLANATION_MODEL, GatewayError,
                     MAX_JSON_RESPONSE_BYTES, MAX_REQUEST_BYTES, MAX_STREAM_BYTES,
                     normalize_decision, normalize_explanation, read_body)
from subscription_http import mount_subscription_routes
from subscription_service import SessionPrincipal, SubscriptionService
from subscription_environments import SubscriptionEnvironments

COMMERCIAL_EXPLANATION_URL = "https://ark.cn-beijing.volces.com/api/v3/chat/completions"
UNREADABLE_SENTINEL = "无法读取所指内容"
MAX_ANSWER_BYTES = 32_768
LOG = logging.getLogger("pinpin.subscription_gateway")
USAGE_FIELDS = ("prompt_tokens", "completion_tokens", "total_tokens", "reasoning_tokens")


@dataclass(frozen=True)
class CommercialGatewaySettings:
    beatapi_api_key: str = field(repr=False)
    commercial_api_key: str = field(repr=False)
    max_concurrent: int = 6
    requests_per_minute: int = 60
    decision_timeout: float = 20
    explanation_timeout: float = 30
    body_timeout: float = 10

    def __post_init__(self):
        for name, value in (("BEATAPI_API_KEY", self.beatapi_api_key),
                            ("PINPIN_COMMERCIAL_API_KEY", self.commercial_api_key)):
            if (not isinstance(value, str) or not value.strip() or value != value.strip()
                    or any(ord(c) < 32 for c in value)):
                raise ValueError(f"{name} is required for the commercial subscription gateway")
        for value in (self.max_concurrent, self.requests_per_minute):
            if type(value) is not int or value < 1:
                raise ValueError("gateway limits must be positive integers")
        for value in (self.decision_timeout, self.explanation_timeout, self.body_timeout):
            if type(value) not in (int, float) or not math.isfinite(value) or value <= 0:
                raise ValueError("gateway timeouts must be positive finite numbers")

    @classmethod
    def from_env(cls):
        return cls(os.environ.get("BEATAPI_API_KEY", ""), os.environ.get("PINPIN_COMMERCIAL_API_KEY", ""))


def _json_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate field")
        result[key] = value
    return result


def _parse_json(raw):
    try:
        value = json.loads(raw, object_pairs_hook=_json_object,
                           parse_constant=lambda _: (_ for _ in ()).throw(ValueError("nonfinite")))
        if not isinstance(value, dict) or "error" in value:
            raise ValueError("invalid response")
        return value
    except (ValueError, UnicodeError, RecursionError):
        raise GatewayError(502, "invalid_upstream_response") from None


def _usage(value):
    if value is None:
        return {}
    if not isinstance(value, dict):
        raise GatewayError(502, "invalid_upstream_response")
    result = {}
    for key in USAGE_FIELDS:
        item = value.get(key)
        if key == "reasoning_tokens" and item is None:
            details = value.get("completion_tokens_details")
            if isinstance(details, dict):
                item = details.get("reasoning_tokens")
        if item is not None:
            if type(item) is not int or not 0 <= item < 2**63:
                raise GatewayError(502, "invalid_upstream_response")
            result[key] = item
    return result


def _action_id(request):
    values = request.headers.getall("X-PinPin-Action-ID", [])
    try:
        if len(values) != 1 or len(values[0]) != 36:
            raise ValueError()
        action = UUID(values[0])
        if action.int == 0:
            raise ValueError()
        return str(action)
    except (ValueError, AttributeError):
        raise GatewayError(400, "invalid_action_id") from None


class OperationPhases:
    """SQLite CAS grants at most one upstream call per action/phase, across workers."""

    def __init__(self, service: SubscriptionService):
        self.service = service
        with service._connection() as db:
            db.execute("""
                CREATE TABLE IF NOT EXISTS subscription_model_phases (
                    user_id TEXT NOT NULL, action_id TEXT NOT NULL,
                    phase TEXT NOT NULL CHECK(phase IN ('decision', 'answer')),
                    state TEXT NOT NULL CHECK(state IN ('running', 'succeeded', 'failed')),
                    prompt_tokens INTEGER, completion_tokens INTEGER,
                    total_tokens INTEGER, reasoning_tokens INTEGER,
                    PRIMARY KEY(user_id, action_id, phase)
                )
            """)

    def begin(self, principal: SessionPrincipal, action_id: str, phase: str):
        self.service.refresh_entitlement(principal.user_id)
        action = self.service.ledger.reserve(principal.user_id, action_id)
        if action.state == "quota_exceeded":
            raise GatewayError(402, "quota_exceeded")
        if action.state != "reserved":
            raise GatewayError(409, "action_finished")
        with self.service._transaction() as db:
            current = db.execute("SELECT state, expires_at FROM actions WHERE user_id=? AND action_id=?",
                                 (principal.user_id, action_id)).fetchone()
            if (current is None or current["state"] != "reserved"
                    or current["expires_at"] <= int(self.service.clock().timestamp() * 1_000_000)):
                raise GatewayError(409, "action_finished")
            if db.execute("SELECT 1 FROM subscription_model_phases WHERE user_id=? AND action_id=? AND phase=?",
                          (principal.user_id, action_id, phase)).fetchone() is not None:
                raise GatewayError(409, "phase_already_started")
            if phase == "decision" and db.execute(
                    "SELECT 1 FROM subscription_model_phases WHERE user_id=? AND action_id=? AND phase='answer'",
                    (principal.user_id, action_id)).fetchone() is not None:
                raise GatewayError(409, "phase_already_started")
            # The answer does not wait for a running decision: the client may
            # already have hit its shorter Jev timeout and chosen visual fallback.
            db.execute("INSERT INTO subscription_model_phases (user_id, action_id, phase, state) VALUES (?, ?, ?, 'running')",
                       (principal.user_id, action_id, phase))
        return action

    def _record(self, user_id, action_id, phase, state, usage=None, *, db=None):
        if db is None:
            with self.service._transaction() as connection:
                return self._record(user_id, action_id, phase, state, usage, db=connection)
        usage = usage or {}
        db.execute("UPDATE subscription_model_phases SET state=?, "
                   "prompt_tokens=COALESCE(?, prompt_tokens), completion_tokens=COALESCE(?, completion_tokens), "
                   "total_tokens=COALESCE(?, total_tokens), reasoning_tokens=COALESCE(?, reasoning_tokens) "
                   "WHERE user_id=? AND action_id=? AND phase=?",
                   (state, *(usage.get(key) for key in USAGE_FIELDS), user_id, action_id, phase))

    def decision_finished(self, user_id, action_id, succeeded, usage=None):
        self._record(user_id, action_id, "decision", "succeeded" if succeeded else "failed", usage)

    def answer_completed(self, user_id, action_id, usage):
        action = self.service.ledger.commit(user_id, action_id, on_committed=lambda db:
                                           self._record(user_id, action_id, "answer", "succeeded", usage, db=db))
        if action.state != "committed":
            self._record(user_id, action_id, "answer", "failed")
            raise GatewayError(409, "action_finished")

    def answer_failed(self, user_id, action_id):
        action = self.service.ledger.cancel(user_id, action_id)
        # A disconnect can race a commit already in progress. Never undo the
        # durable result or turn a completed action into an executable retry.
        self._record(user_id, action_id, "answer", "succeeded" if action.state == "committed" else "failed")


class SSEParser:
    """Byte-oriented SSE framing, including split UTF-8 and CR/LF boundaries."""

    def __init__(self):
        self.line = bytearray()
        self.data = []
        self.event_type = ""
        self.skip_lf = False

    def feed(self, chunk):
        events = []
        for byte in chunk:
            if self.skip_lf:
                self.skip_lf = False
                if byte == 10:
                    continue
            if byte not in (10, 13):
                self.line.append(byte)
                continue
            self.skip_lf = byte == 13
            try:
                line = self.line.decode("utf-8")
            except UnicodeError:
                raise GatewayError(502, "invalid_upstream_response") from None
            self.line.clear()
            if not line:
                if self.data:
                    if self.event_type == "error":
                        raise GatewayError(502, "invalid_upstream_response")
                    events.append("\n".join(self.data))
                self.data.clear()
                self.event_type = ""
            elif line.startswith("data:"):
                self.data.append(line[6:] if line.startswith("data: ") else line[5:])
            elif line.startswith("event:"):
                self.event_type = line[6:].lstrip(" ")
        return events


class AnswerStream:
    def __init__(self):
        self.model = None
        self.text = []
        self.text_bytes = 0
        self.finished = False
        self.done = False
        self.usage = {}
        self.terminal_events = []

    def consume(self, event: str) -> bytes | None:
        if self.done:
            raise GatewayError(502, "invalid_upstream_response")
        if event == "[DONE]":
            answer = "".join(self.text).strip()
            if not self.finished or self.model is None or not answer or answer == UNREADABLE_SENTINEL:
                raise GatewayError(502, "incomplete_upstream_response")
            self.done = True
            return None
        value = _parse_json(event)
        model = value.get("model")
        if model is not None:
            if (not isinstance(model, str) or not (model == EXPLANATION_MODEL
                    or re.fullmatch(r"deepseek-v4-1-flash-[0-9]{6}", model))
                    or (self.model is not None and self.model != model)):
                raise GatewayError(502, "invalid_upstream_response")
            self.model = model
        self.usage.update(_usage(value.get("usage")))
        choices = value.get("choices")
        if not isinstance(choices, list) or len(choices) > 1:
            raise GatewayError(502, "invalid_upstream_response")
        if choices:
            choice = choices[0]
            if not isinstance(choice, dict) or type(choice.get("index", 0)) is not int or choice.get("index", 0) != 0:
                raise GatewayError(502, "invalid_upstream_response")
            delta = choice.get("delta", {})
            if not isinstance(delta, dict):
                raise GatewayError(502, "invalid_upstream_response")
            for field_name in ("content", "reasoning_content"):
                content = delta.get(field_name)
                if content is not None and not isinstance(content, str):
                    raise GatewayError(502, "invalid_upstream_response")
            content = delta.get("content")
            if content is not None:
                if self.finished or self.model is None:
                    raise GatewayError(502, "invalid_upstream_response")
                self.text.append(content)
                self.text_bytes += len(content.encode("utf-8"))
                if self.text_bytes > MAX_ANSWER_BYTES:
                    raise GatewayError(502, "invalid_upstream_response")
            finish = choice.get("finish_reason")
            if finish is not None:
                if finish != "stop" or self.finished:
                    raise GatewayError(502, "incomplete_upstream_response")
                self.finished = True
        encoded = ("data: " + event + "\n\n").encode("utf-8")
        if self.finished:
            self.terminal_events.append(encoded)
            return None
        return encoded


def _decision_result(raw, payload):
    value = _parse_json(raw)
    if value.get("model") != DECISION_MODEL or not isinstance(value.get("answers"), dict):
        raise GatewayError(502, "invalid_upstream_response")
    for name, question in payload["questions"].items():
        answer = value["answers"].get(name)
        if not isinstance(answer, dict) or answer.get("type") != "choice":
            raise GatewayError(502, "invalid_upstream_response")
        selected, probabilities = answer.get("choice"), answer.get("probabilities")
        allowed = question["criteria"]
        if (not isinstance(selected, str) or selected not in allowed
                or not isinstance(probabilities, dict) or set(probabilities) != set(allowed)):
            raise GatewayError(502, "invalid_upstream_response")
        if any(type(number) not in (int, float) or not math.isfinite(number) or not 0 <= number <= 1
               for number in probabilities.values()):
            raise GatewayError(502, "invalid_upstream_response")
        highest = max(probabilities.values())
        if highest <= 0 or probabilities[selected] != highest or abs(sum(probabilities.values()) - 1) >= .02:
            raise GatewayError(502, "invalid_upstream_response")
    return _usage(value.get("usage"))


def create_subscription_gateway(settings: CommercialGatewaySettings, service: SubscriptionService | SubscriptionEnvironments, *,
                                prefix="/ping/v1", _test_upstreams=None):
    if not isinstance(prefix, str) or not re.fullmatch(r"/[A-Za-z0-9_-]+(?:/[A-Za-z0-9_-]+)+", prefix):
        raise ValueError("prefix must be an absolute API path without trailing slash")
    upstreams = (DECISION_URL, COMMERCIAL_EXPLANATION_URL)
    services = service.services if isinstance(service, SubscriptionEnvironments) else (service,)
    if _test_upstreams is None and any(not isinstance(item.verifier, AppleSubscriptionVerifier) for item in services):
        raise ValueError("the commercial gateway requires the configured Apple signature verifier")
    if _test_upstreams is not None:
        if not isinstance(_test_upstreams, (tuple, list)) or len(_test_upstreams) != 2:
            raise ValueError("exactly two loopback test upstreams are required")
        for url in _test_upstreams:
            parsed = urlsplit(url)
            if (parsed.scheme != "http" or parsed.hostname not in {"127.0.0.1", "::1"}
                    or parsed.username is not None or parsed.password is not None
                    or parsed.query or parsed.fragment):
                raise ValueError("test upstreams must be plain HTTP loopback URLs")
        upstreams = tuple(_test_upstreams)
    environment_phases = {item: OperationPhases(item) for item in services}
    active = 0
    admissions = deque()
    session = None

    @web.middleware
    async def errors(request, handler):
        try:
            return await handler(request)
        except (GatewayError, SubscriptionError) as error:
            return web.json_response({"error": {"code": error.code,
                                               "message": getattr(error, "message", "The request could not be completed.")}},
                                     status=error.status, headers={"Cache-Control": "no-store"})
        except web.HTTPException as error:
            return web.json_response({"error": {"code": "not_found" if error.status == 404 else "invalid_request",
                                               "message": "The request could not be completed."}},
                                     status=error.status, headers={"Cache-Control": "no-store"})
        except (ConnectionError, asyncio.CancelledError):
            raise
        except Exception:
            LOG.error("subscription_gateway_internal_error")
            return web.json_response({"error": {"code": "internal_error", "message": "The request could not be completed."}},
                                     status=500, headers={"Cache-Control": "no-store"})

    app = web.Application(middlewares=[errors], client_max_size=MAX_REQUEST_BYTES,
                          handler_args={"auto_decompress": False, "handler_cancellation": True})
    offloop = mount_subscription_routes(app, service, prefix=prefix)

    async def lifecycle(app):
        nonlocal session
        session = aiohttp.ClientSession(
            connector=aiohttp.TCPConnector(limit=settings.max_concurrent, limit_per_host=settings.max_concurrent,
                                           ttl_dns_cache=300),
            timeout=aiohttp.ClientTimeout(total=None, connect=5, sock_read=10),
            cookie_jar=aiohttp.DummyCookieJar(), trust_env=False, auto_decompress=False,
            headers={"User-Agent": "PinPin-Subscription-Gateway/1", "Accept-Encoding": "identity"})
        yield
        await session.close()

    async def settle(method, *args):
        # Keep the durable settlement running if the HTTP task is cancelled.
        return await asyncio.shield(offloop._run(method, *args, wait_for_slot=True))

    async def proxy(request):
        nonlocal active
        token = offloop._token(request)
        if isinstance(service, SubscriptionEnvironments):
            scoped_service, principal = await offloop._run(service.resolve_session, token)
        else:
            scoped_service, principal = service, await offloop._run(service.authenticate, token)
        phases = environment_phases[scoped_service]
        action_id = _action_id(request)
        body = await read_body(request, settings)
        answer = request.path.endswith("/explanation")
        payload = normalize_explanation(body) if answer else normalize_decision(body)
        now = time.monotonic()
        while admissions and admissions[0] <= now - 60:
            admissions.popleft()
        if len(admissions) >= settings.requests_per_minute:
            raise GatewayError(429, "rate_limited")
        if active >= settings.max_concurrent:
            raise GatewayError(503, "busy")
        admissions.append(now)
        active += 1
        phase_started = False
        phase_finished = False
        downstream = None
        try:
            phase = "answer" if answer else "decision"
            claim = asyncio.create_task(offloop._run(phases.begin, principal, action_id, phase))
            try:
                action = await asyncio.shield(claim)
            except asyncio.CancelledError:
                # The SQLite CAS may already be running off-loop. Observe its
                # actual result before deciding whether this caller owns cleanup;
                # a failed duplicate must never cancel another caller's action.
                try:
                    await claim
                    phase_started = True
                except (GatewayError, SubscriptionError):
                    pass
                raise
            phase_started = True
            remaining = (action.expires_at - scoped_service.clock()).total_seconds()
            if remaining <= 0:
                raise GatewayError(409, "action_finished")
            timeout = min(settings.explanation_timeout if answer else settings.decision_timeout, remaining)
            async with asyncio.timeout(timeout) as inference_timeout:
                async with session.post(upstreams[1 if answer else 0], json=payload, allow_redirects=False,
                                        headers={"Authorization": "Bearer " + (settings.commercial_api_key if answer else settings.beatapi_api_key),
                                                 "Accept": "text/event-stream" if answer else "application/json"}) as upstream:
                    if not 200 <= upstream.status < 300:
                        raise GatewayError(502, "upstream_unavailable")
                    if upstream.headers.get("Content-Encoding", "identity") != "identity":
                        raise GatewayError(502, "invalid_upstream_response")
                    if not answer:
                        if upstream.content_type != "application/json":
                            raise GatewayError(502, "invalid_upstream_response")
                        raw = bytearray()
                        async for chunk in upstream.content.iter_chunked(16384):
                            raw.extend(chunk)
                            if len(raw) > MAX_JSON_RESPONSE_BYTES:
                                raise GatewayError(502, "invalid_upstream_response")
                        usage = _decision_result(raw, payload)
                        inference_timeout.reschedule(None)
                        await settle(phases.decision_finished, principal.user_id, action_id, True, usage)
                        phase_finished = True
                        return web.Response(body=bytes(raw), content_type="application/json", headers={"Cache-Control": "no-store"})
                    if upstream.content_type != "text/event-stream":
                        raise GatewayError(502, "invalid_upstream_response")
                    downstream = web.StreamResponse(headers={"Content-Type": "text/event-stream", "Cache-Control": "no-store",
                                                             "X-Accel-Buffering": "no"})
                    await downstream.prepare(request)
                    parser, stream, total = SSEParser(), AnswerStream(), 0
                    async for chunk in upstream.content.iter_any():
                        total += len(chunk)
                        if total > MAX_STREAM_BYTES:
                            raise GatewayError(502, "invalid_upstream_response")
                        for event in parser.feed(chunk):
                            preview = stream.consume(event)
                            if preview is not None:
                                await downstream.write(preview)
                        if stream.done:
                            break
                    if not stream.done:
                        raise GatewayError(502, "incomplete_upstream_response")
                    inference_timeout.reschedule(None)
                    if request.transport is None or request.transport.is_closing():
                        raise ConnectionError()
                    await settle(phases.answer_completed, principal.user_id, action_id, stream.usage)
                    phase_finished = True
                    for event in stream.terminal_events:
                        await downstream.write(event)
                    await downstream.write(b"data: [DONE]\n\n")
                    await downstream.write_eof()
                    return downstream
        except Exception as error:
            settlement_failed = False
            if phase_started and not phase_finished:
                try:
                    if answer:
                        await settle(phases.answer_failed, principal.user_id, action_id)
                    else:
                        await settle(phases.decision_finished, principal.user_id, action_id, False)
                except Exception:
                    # A storage outage cannot authorize completion. The persisted
                    # reservation still has its lease and can expire after recovery.
                    LOG.error("subscription_settlement_failed")
                    settlement_failed = True
                phase_finished = True
            if settlement_failed or isinstance(error, sqlite3.Error):
                code, status = "service_unavailable", 503
            elif isinstance(error, (GatewayError, SubscriptionError)):
                code, status = error.code, error.status
            elif isinstance(error, TimeoutError):
                code, status = "upstream_timeout", 504
            elif isinstance(error, (aiohttp.ClientError, ConnectionError)):
                code, status = "upstream_unavailable", 502
            else:
                LOG.error("subscription_model_request_failed")
                code, status = "internal_error", 500
            if downstream is not None and downstream.prepared:
                if request.transport is not None and not request.transport.is_closing():
                    await downstream.write(("data: " + json.dumps({"error": {"code": code}}) + "\n\n").encode())
                    await downstream.write_eof()
                return downstream
            raise GatewayError(status, code) from None
        finally:
            try:
                if phase_started and not phase_finished:
                    try:
                        if answer:
                            await settle(phases.answer_failed, principal.user_id, action_id)
                        else:
                            await settle(phases.decision_finished, principal.user_id, action_id, False)
                    except Exception:
                        LOG.error("subscription_settlement_failed")
            finally:
                active -= 1

    async def health(request):
        return web.json_response({"ready": True, "mode": "subscription"}, headers={"Cache-Control": "no-store"})

    app.cleanup_ctx.append(lifecycle)
    app.router.add_get(prefix.rsplit("/", 1)[0] + "/health", health, allow_head=False)
    app.router.add_post(prefix + "/decision", proxy)
    app.router.add_post(prefix + "/explanation", proxy)
    return app
