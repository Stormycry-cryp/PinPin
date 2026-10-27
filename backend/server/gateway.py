"""PinPin's two fixed model routes. No user content or credentials are logged."""

from __future__ import annotations

import asyncio
import base64
import binascii
from collections import deque
from dataclasses import dataclass, field
import hmac
import json
import logging
import os
import time
import zlib
from urllib.parse import urlsplit

import aiohttp
from aiohttp import web

DECISION_URL = "https://api.beatapi.io/v1/systemone"
EXPLANATION_URL = "https://ark.cn-beijing.volces.com/api/plan/v3/chat/completions"
DECISION_MODEL = "jev-1.14"
EXPLANATION_MODEL = "deepseek-v4.1-flash"
MAX_REQUEST_BYTES = 12 * 1024 * 1024
MAX_JSON_RESPONSE_BYTES = 512_000
MAX_STREAM_BYTES = 1024 * 1024
# Explanations stay short (client default 400); translate and rewrite scale with their input.
MAX_OUTPUT_TOKENS = 1600
PLANS = {"use_current", "expand_visual"}
logger = logging.getLogger("pinpin.gateway")


@dataclass(frozen=True)
class Settings:
    beatapi_api_key: str = field(repr=False)
    agent_api_key: str = field(repr=False)
    access_token: str = field(repr=False)
    max_concurrent: int = 6
    requests_per_minute: int = 60
    decision_timeout: float = 20
    explanation_timeout: float = 30
    body_timeout: float = 10

    def __post_init__(self):
        # Require a separately generated, URL-safe application token even in tests.
        if len(self.access_token) < 32 or not self.access_token.isascii() or any(c.isspace() for c in self.access_token):
            raise ValueError("PINPIN_ACCESS_TOKEN must contain at least 32 non-whitespace ASCII characters")
        if not self.beatapi_api_key or not self.agent_api_key:
            raise ValueError("Both provider keys are required")
        if self.max_concurrent < 1 or self.requests_per_minute < 1:
            raise ValueError("Limits must be positive")
        if min(self.decision_timeout, self.explanation_timeout, self.body_timeout) <= 0:
            raise ValueError("Timeouts must be positive")

    @classmethod
    def from_env(cls):
        return cls(*(os.environ.get(name, "") for name in
                     ("BEATAPI_API_KEY", "AGENT_API_KEY", "PINPIN_ACCESS_TOKEN")))


class GatewayError(Exception):
    def __init__(self, status: int, code: str):
        self.status, self.code = status, code


def require(condition):
    if not condition:
        raise GatewayError(400, "invalid_request")


def object_keys(value, allowed, required=()):
    require(isinstance(value, dict) and set(value) <= set(allowed) and set(required) <= set(value))


def text_field(value, maximum):
    require(isinstance(value, str) and len(value) <= maximum)


def image_dimensions(data):
    """Read bounded PNG/JPEG dimensions without decoding pixels or adding an image runtime."""
    if data.startswith(b"\x89PNG\r\n\x1a\n") and len(data) >= 24 and data[12:16] == b"IHDR":
        return "png", int.from_bytes(data[16:20], "big"), int.from_bytes(data[20:24], "big")
    if data.startswith(b"\xff\xd8"):
        position = 2
        while position + 4 <= len(data):
            if data[position] != 255:
                break
            while position < len(data) and data[position] == 255:
                position += 1
            if position >= len(data):
                break
            marker = data[position]
            position += 1
            if marker in {0xD8, 0xD9, 0x01} or 0xD0 <= marker <= 0xD7:
                continue
            if position + 2 > len(data):
                break
            length = int.from_bytes(data[position:position + 2], "big")
            if length < 2 or position + length > len(data):
                break
            if marker in {0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF} and length >= 8:
                return "jpg", int.from_bytes(data[position + 5:position + 7], "big"), int.from_bytes(data[position + 3:position + 5], "big")
            position += length
    raise GatewayError(400, "invalid_image")


def normalize_decision(body):
    object_keys(body, {"model", "state", "questions", "assets"}, {"state", "questions", "assets"})
    require(body.get("model", DECISION_MODEL) == DECISION_MODEL)
    state = body["state"]
    object_keys(state, {"task", "image", "capture_metadata", "evidence"}, {"task", "image", "capture_metadata", "evidence"})
    require(state["image"] == "screen")
    text_field(state["task"], 6000)
    metadata = state["capture_metadata"]
    object_keys(metadata, {"source", "has_point_anchored_image", "point_in_image"}, {"source", "has_point_anchored_image", "point_in_image"})
    text_field(metadata["source"], 1000)
    require(metadata["has_point_anchored_image"] is True)
    point = metadata["point_in_image"]
    object_keys(point, {"x", "y"}, {"x", "y"})
    for value in point.values():
        require(type(value) in {int, float} and 0 <= value <= 1)
    evidence = state["evidence"]
    object_keys(evidence, {"target", "application", "window_title"}, {"target", "application", "window_title"})
    for key, maximum in (("target", 4000), ("application", 200), ("window_title", 300)):
        text_field(evidence[key], maximum)
    object_keys(body["assets"], {"screen"}, {"screen"})
    asset = body["assets"]["screen"]
    object_keys(asset, {"type", "format", "data_base64"}, {"type", "format", "data_base64"})
    require(asset["type"] == "image" and isinstance(asset["format"], str) and asset["format"] in {"png", "jpg", "jpeg"})
    encoded = asset["data_base64"]
    require(isinstance(encoded, str) and 0 < len(encoded) <= 10_666_668)
    try:
        data = base64.b64decode(encoded, validate=True)
    except (ValueError, binascii.Error):
        raise GatewayError(400, "invalid_image") from None
    require(0 < len(data) <= 8_000_000)
    kind, width, height = image_dimensions(data)
    require(kind == ("jpg" if asset["format"] == "jpeg" else asset["format"]))
    require(280 <= width <= 1568 and 280 <= height <= 1568)
    if isinstance(body["questions"], dict) and set(body["questions"]) == {"intent", "reply_strategy"}:
        expected = {
            "intent": {"ask_information", "request_action", "share_update", "seek_support", "set_boundary", "disagreement", "unclear", "not_chat"},
            "reply_strategy": {"承接", "降压", "调侃", "轻推", "约见", "澄清", "收线"},
        }
        for name, keys in expected.items():
            question = body["questions"][name]
            object_keys(question, {"type", "instructions", "criteria"}, {"type", "instructions", "criteria"})
            require(question["type"] == "choice")
            text_field(question["instructions"], 6000)
            object_keys(question["criteria"], keys, keys)
            for description in question["criteria"].values():
                text_field(description, 3000)
        return {**body, "model": DECISION_MODEL}
    object_keys(body["questions"], {"acquisition"}, {"acquisition"})
    question = body["questions"]["acquisition"]
    object_keys(question, {"type", "instructions", "criteria"}, {"type", "instructions", "criteria"})
    require(question["type"] == "choice")
    text_field(question["instructions"], 6000)
    criteria = question["criteria"]
    object_keys(criteria, PLANS)
    require(1 <= len(criteria) <= 2)
    for description in criteria.values():
        text_field(description, 3000)
    return {**body, "model": DECISION_MODEL}


def normalize_explanation(body):
    object_keys(body, {"model", "thinking", "reasoning_effort", "stream", "max_tokens", "messages"}, {"messages"})
    require(body.get("model", EXPLANATION_MODEL) == EXPLANATION_MODEL)
    thinking = body.get("thinking", {"type": "disabled"})
    require(thinking in ({"type": "disabled"}, {"type": "enabled"}))
    if thinking["type"] == "enabled":
        require(body.get("reasoning_effort") == "low")
    else:
        require("reasoning_effort" not in body)
    require(body.get("stream", True) is True)
    limit = body.get("max_tokens", 400)
    require(type(limit) is int and 1 <= limit <= MAX_OUTPUT_TOKENS)
    messages = body["messages"]
    require(isinstance(messages, list) and len(messages) == 2)
    system, user = messages
    for message, role in ((system, "system"), (user, "user")):
        object_keys(message, {"role", "content"}, {"role", "content"})
        require(message["role"] == role)
    text_field(system["content"], 12_000)
    content = user["content"]
    require(isinstance(content, list) and 1 <= len(content) <= 2)
    object_keys(content[0], {"type", "text"}, {"type", "text"})
    require(content[0]["type"] == "text")
    text_field(content[0]["text"], 40_000)
    if len(content) == 2:
        part = content[1]
        object_keys(part, {"type", "image_url"}, {"type", "image_url"})
        require(part["type"] == "image_url")
        object_keys(part["image_url"], {"url"}, {"url"})
        value = part["image_url"]["url"]
        require(isinstance(value, str))
        prefix, separator, encoded = value.partition(",")
        require(separator and prefix in {"data:image/png;base64", "data:image/jpeg;base64", "data:image/webp;base64"})
        require(len(encoded) <= 10_666_668)
        try:
            image = base64.b64decode(encoded, validate=True)
        except (ValueError, binascii.Error):
            raise GatewayError(400, "invalid_request") from None
        require(0 < len(image) <= 8_000_000)
    return {**body, "model": EXPLANATION_MODEL, "thinking": thinking,
            "stream": True, "max_tokens": limit}


def _reject_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate_key")
        result[key] = value
    return result


async def read_body(request, settings):
    encoding = request.headers.get("Content-Encoding", "identity")
    if request.content_type != "application/json" or encoding not in {"identity", "gzip"}:
        raise GatewayError(415, "unsupported_media_type")
    try:
        async with asyncio.timeout(settings.body_timeout):
            raw = await request.read()
            if encoding == "gzip":
                decoder = zlib.decompressobj(16 + zlib.MAX_WBITS)
                raw = decoder.decompress(raw, MAX_REQUEST_BYTES + 1)
                if len(raw) > MAX_REQUEST_BYTES:
                    raise GatewayError(413, "request_too_large")
                if not decoder.eof or decoder.unused_data:
                    raise GatewayError(400, "invalid_request")
        body = json.loads(raw, object_pairs_hook=_reject_duplicate_keys,
                          parse_constant=lambda _: (_ for _ in ()).throw(ValueError("nonfinite")))
    except web.HTTPRequestEntityTooLarge:
        raise GatewayError(413, "request_too_large") from None
    except (ValueError, UnicodeError, RecursionError, zlib.error):
        raise GatewayError(400, "invalid_request") from None
    except TimeoutError:
        raise GatewayError(408, "request_timeout") from None
    require(isinstance(body, dict))
    return body


def token_is_valid(authorization, settings):
    """Replace this one function when application tokens become account credentials."""
    expected = ("Bearer " + settings.access_token).encode("ascii")
    return hmac.compare_digest(authorization.encode("utf-8"), expected)


def create_app(settings: Settings, *, _test_upstreams=None):
    # Only the test harness can inject loopback destinations. No env/request URL option exists.
    upstreams = (DECISION_URL, EXPLANATION_URL)
    if _test_upstreams is not None:
        require(len(_test_upstreams) == 2)
        for url in _test_upstreams:
            parsed = urlsplit(url)
            require(parsed.scheme == "http" and parsed.hostname in {"127.0.0.1", "::1"}
                    and parsed.username is None and parsed.password is None)
        upstreams = tuple(_test_upstreams)
    active = 0
    admissions = deque()
    session = None

    @web.middleware
    async def errors(request, handler):
        try:
            return await handler(request)
        except GatewayError as error:
            headers = {"Cache-Control": "no-store"}
            if error.status == 401:
                headers["WWW-Authenticate"] = "Bearer"
            if error.status in {429, 503}:
                headers["Retry-After"] = "5"
            return web.json_response({"error": {"code": error.code}}, status=error.status, headers=headers)
        except web.HTTPException as error:
            return web.json_response({"error": {"code": "not_found" if error.status == 404 else "invalid_request"}},
                                     status=error.status, headers={"Cache-Control": "no-store"})
        except (ConnectionError, asyncio.CancelledError):
            raise
        except Exception:
            # Never include exception values/tracebacks: upstream errors can contain private input.
            logger.error("gateway_internal_error")
            return web.json_response({"error": {"code": "internal_error"}}, status=500)

    app = web.Application(middlewares=[errors], client_max_size=MAX_REQUEST_BYTES,
                          handler_args={"auto_decompress": False})

    async def lifecycle(app):
        nonlocal session
        session = aiohttp.ClientSession(
            connector=aiohttp.TCPConnector(limit=settings.max_concurrent, limit_per_host=settings.max_concurrent,
                                           ttl_dns_cache=300),
            timeout=aiohttp.ClientTimeout(total=None, connect=5, sock_read=10),
            cookie_jar=aiohttp.DummyCookieJar(), trust_env=False, auto_decompress=False,
            headers={"User-Agent": "PinPin-Gateway/1", "Accept-Encoding": "identity"})
        yield
        await session.close()

    async def health(request):
        return web.json_response({"ready": True}, headers={"Cache-Control": "no-store"})

    async def proxy(request):
        nonlocal active
        if not token_is_valid(request.headers.get("Authorization", ""), settings):
            raise GatewayError(401, "unauthorized")
        body = await read_body(request, settings)
        now = time.monotonic()
        while admissions and admissions[0] <= now - 60:
            admissions.popleft()
        if len(admissions) >= settings.requests_per_minute:
            raise GatewayError(429, "rate_limited")
        if active >= settings.max_concurrent:
            raise GatewayError(503, "busy")
        admissions.append(now)
        active += 1
        downstream = None
        try:
            explanation = request.path.endswith("/explanation")
            payload = normalize_explanation(body) if explanation else normalize_decision(body)
            index = 1 if explanation else 0
            key = settings.agent_api_key if explanation else settings.beatapi_api_key
            timeout = settings.explanation_timeout if explanation else settings.decision_timeout
            async with asyncio.timeout(timeout):
                async with session.post(upstreams[index], json=payload, allow_redirects=False,
                                        headers={"Authorization": "Bearer " + key,
                                                 "Accept": "text/event-stream" if explanation else "application/json"}) as upstream:
                    if not 200 <= upstream.status < 300:
                        raise GatewayError(502, "upstream_unavailable")
                    if upstream.headers.get("Content-Encoding", "identity") != "identity":
                        raise GatewayError(502, "invalid_upstream_response")
                    if explanation:
                        if upstream.content_type != "text/event-stream":
                            raise GatewayError(502, "invalid_upstream_response")
                        downstream = web.StreamResponse(headers={"Content-Type": "text/event-stream",
                                                                 "Cache-Control": "no-store",
                                                                 "X-Accel-Buffering": "no"})
                        await downstream.prepare(request)
                        total = 0
                        async for chunk in upstream.content.iter_any():
                            total += len(chunk)
                            if total > MAX_STREAM_BYTES:
                                raise GatewayError(502, "invalid_upstream_response")
                            await downstream.write(chunk)
                        await downstream.write_eof()
                        return downstream
                    if upstream.content_type != "application/json":
                        raise GatewayError(502, "invalid_upstream_response")
                    raw = bytearray()
                    async for chunk in upstream.content.iter_chunked(16_384):
                        raw.extend(chunk)
                        if len(raw) > MAX_JSON_RESPONSE_BYTES:
                            raise GatewayError(502, "invalid_upstream_response")
                    try:
                        result = json.loads(raw)
                        if not isinstance(result, dict):
                            raise ValueError()
                    except (ValueError, UnicodeError, RecursionError):
                        raise GatewayError(502, "invalid_upstream_response") from None
                    return web.Response(body=bytes(raw), content_type="application/json",
                                        headers={"Cache-Control": "no-store"})
        except (TimeoutError, aiohttp.ClientError, GatewayError) as error:
            if downstream is not None and downstream.prepared:
                # Status/headers already reached the client. Abort so its SSE parser sees an incomplete stream.
                if request.transport is not None:
                    request.transport.abort()
                return downstream
            if isinstance(error, GatewayError):
                raise
            if isinstance(error, TimeoutError):
                raise GatewayError(504, "upstream_timeout") from None
            raise GatewayError(502, "upstream_unavailable") from None
        finally:
            active -= 1

    app.cleanup_ctx.append(lifecycle)
    app.router.add_get("/ping/health", health, allow_head=False)
    app.router.add_post("/ping/v1/decision", proxy)
    app.router.add_post("/ping/v1/explanation", proxy)
    return app


def main():
    logging.basicConfig(level=logging.INFO, format="%(name)s %(levelname)s %(message)s")
    try:
        settings = Settings.from_env()
    except ValueError:
        raise SystemExit("PinPin requires valid provider keys and PINPIN_ACCESS_TOKEN") from None
    web.run_app(create_app(settings), host="127.0.0.1", port=8789, access_log=None,
                handler_cancellation=True, shutdown_timeout=5, print=None)


if __name__ == "__main__":
    main()
