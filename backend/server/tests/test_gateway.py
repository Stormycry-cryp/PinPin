"""Local loopback upstreams only; never spend model credits."""

import asyncio
import base64
from contextlib import asynccontextmanager
from dataclasses import replace
import inspect
import io
import gzip
import json
from pathlib import Path
import struct
import sys
import unittest
from unittest.mock import patch
import zlib

import aiohttp
from aiohttp import web
from aiohttp.test_utils import TestServer

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from gateway import (DECISION_MODEL, EXPLANATION_MODEL, MAX_REQUEST_BYTES, Settings, create_app)

TOKEN = "local-test-application-token-0123456789"
AUTH = {"Authorization": "Bearer " + TOKEN}


def png_image(width=320, height=320):
    """A real, blank grayscale PNG; fixtures do not need an image dependency."""
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 0, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress((b"\x00" + b"\x00" * width) * height))
            + chunk(b"IEND", b""))


# A locally encoded 280 x 280 grayscale JPEG, with metadata removed.
JPEG_IMAGE = base64.b64decode(
    "/9j/wAALCAEYARgBAREA/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9"
    "AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpT"
    "VFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJ"
    "ytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/9sAQwAbGxsbGxsvGxsvQi8vL0JZQkJCQllwWVlZWVlwiHBw"
    "cHBwcIiIiIiIiIiIo6Ojo6Ojvr6+vr7V1dXV1dXV1dXV/90ABAAj/9oACAEBAAA/AOaooooooooooooooooooooooooo"
    "ooooooooor//0Oaoooooooooooooooooooooooooooooooooor//0eaoooooooooooooooooooooooooooooooooor//0ua"
    "oooooooooooooooooooooooooooooooooor//0+aoooooooooooooooooooooooooooooooooor//1Oaoooooooooooooooo"
    "oooooooooooooooooor//1eaoooooooooooooooooooooooooooooooooor//1uaoooooooooooooooooooooooooooooooo"
    "oor//1+aoooooooooooooooooooooooooooooooooor//0Oaoooooooooooooooooooooooooooooooooor//0eaoooooooo"
    "oooooooooooooooooooooooooor//0uaoooooooooooooooooooooooooooooooooor//0+aoooooooooooooooooooooooo"
    "oooooooooor//1Oaoooooooooooooooooooooooooooooooooor//1eaoooooooooooooooooooooooooooooooooor//1ua"
    "oooooooooooooooooooooooooooooooooor//1+aoooooooooooooooooooooooooooooooooor//0Oaoooooooooooooooo"
    "oooooooooooooooooor//0eaoooooooooooooooooooooooooooooooooor//0uaoooooooooooooooooooooooooooooooo"
    "oor//0+aoooooooooooooooooooooooooooooooooor//1Oaoooooooooooooooooooooooooooooooooor//1eaoooooooo"
    "oooooooooooooooooooooooooor//1uaoooooooooooooooooooooooooooooooooor//1+aoooooooooooooooooooooooo"
    "oooooooooor//0Oaoooooooooooooooooooooooooooooooooor//0eaoooooooooooooooooooooooooooooooooor//0ua"
    "oooooooooooooooooooooooooooooooooor//0+aoooooooooooooooooooooooooooooooooor//1Oaoooooooooooooooo"
    "oooooooooooooooooor//1eaoooooooooooooooooooooooooooooooooor//1uaoooooooooooooooooooooooooooooooo"
    "oor//1+aoooooooooooooooooooooooooooooooooor//0Oaoooooooooooooooooooooooooooooooooor//0eaoooooooo"
    "oooooooooooooooooooooooooor//2Q=="
)


def screen_asset(data=None, image_format="png"):
    return {"type": "image", "format": image_format,
            "data_base64": base64.b64encode(png_image() if data is None else data).decode("ascii")}


def decision():
    return {"model": DECISION_MODEL, "state": {"task": "explain", "image": "screen", "capture_metadata": {
        "source": "point_image", "has_point_anchored_image": True, "point_in_image": {"x": 0.5, "y": 0.5}},
        "evidence": {"target": "", "application": "Local fixture", "window_title": "Example"}},
        "assets": {"screen": screen_asset()}, "questions": {"acquisition": {
            "type": "choice", "instructions": "Choose the image scope around the original point.",
            "criteria": {"use_current": "sufficient", "expand_visual": "need more surrounding image"}}}}


def explanation():
    return {"model": EXPLANATION_MODEL, "thinking": {"type": "disabled"}, "stream": True,
            "max_tokens": 400, "messages": [{"role": "system", "content": "explain"},
                                          {"role": "user", "content": [{"type": "text", "text": "evidence"}]}]}


class GatewayTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.settings = Settings("private-beat-key", "private-agent-key", TOKEN)
        self.calls = []
        self.behavior = None

        async def upstream(request):
            self.calls.append({"path": request.path, "auth": request.headers.get("Authorization"),
                               "cookie": request.headers.get("Cookie"),
                               "encoding": request.headers.get("Accept-Encoding"), "body": await request.json()})
            if self.behavior:
                return await self.behavior(request)
            if request.path == "/decision":
                return web.json_response({"model": DECISION_MODEL, "answers": {"acquisition": {"choice": "use_current"}}})
            return web.Response(body=b'data: {"model":"deepseek-v4.1-flash"}\n\ndata: [DONE]\n\n',
                                content_type="text/event-stream")

        app = web.Application(client_max_size=MAX_REQUEST_BYTES)
        app.router.add_post("/{route}", upstream)
        self.upstream = TestServer(app, handler_cancellation=True)
        await self.upstream.start_server()
        self.client = aiohttp.ClientSession()
        self.gateway = None
        await self.start_gateway()

    async def start_gateway(self, **changes):
        if self.gateway:
            await self.gateway.close()
        app = create_app(replace(self.settings, **changes), _test_upstreams=(
            str(self.upstream.make_url("/decision")), str(self.upstream.make_url("/explanation"))))
        self.gateway = TestServer(app, handler_cancellation=True)
        await self.gateway.start_server()

    async def asyncTearDown(self):
        await self.client.close()
        await self.gateway.close()
        await self.upstream.close()

    async def post(self, route="decision", body=None, **kwargs):
        return await self.client.post(self.gateway.make_url("/ping/v1/" + route),
                                      json=body if body is not None else decision(), headers=AUTH, **kwargs)

    def active_requests(self):
        handler = next(route.handler for route in self.gateway.app.router.routes()
                       if route.resource.canonical == "/ping/v1/explanation")
        return inspect.getclosurevars(handler).nonlocals["active"]

    @asynccontextmanager
    async def slow_uploads(self, count):
        import gateway
        read_body = gateway.read_body
        entered, finished, release = asyncio.Event(), asyncio.Queue(), asyncio.Event()
        entries = 0
        payload = json.dumps(explanation()).encode()

        async def observed_read(request, settings):
            nonlocal entries
            slow = request.headers.get("X-Local-Slow") == "yes"
            if slow:
                entries += 1
                if entries == count:
                    entered.set()
            try:
                return await read_body(request, settings)
            finally:
                if slow:
                    finished.put_nowait(None)

        async def body():
            yield payload[:10]
            await release.wait()
            yield payload[10:]

        async def request():
            return await self.client.post(self.gateway.make_url("/ping/v1/explanation"), data=body(),
                                          headers={**AUTH, "Content-Type": "application/json", "X-Local-Slow": "yes"})

        with patch("gateway.read_body", observed_read):
            tasks = [asyncio.create_task(request()) for _ in range(count)]
            try:
                await asyncio.wait_for(entered.wait(), 1)
                yield tasks, release, finished
            finally:
                for task in tasks:
                    if not task.done():
                        task.cancel()
                results = await asyncio.gather(*tasks, return_exceptions=True)
                for result in results:
                    if isinstance(result, aiohttp.ClientResponse):
                        result.close()
                for _ in range(count):
                    await asyncio.wait_for(finished.get(), 1)

    async def test_health_has_no_secrets(self):
        async with self.client.get(self.gateway.make_url("/ping/health")) as response:
            self.assertEqual(await response.json(), {"ready": True})
        self.assertEqual(self.calls, [])

    async def test_authentication_precedes_body_and_upstream(self):
        for auth in (None, "Bearer wrong", "bearer " + TOKEN, "Bearer 中文"):
            headers = {"Content-Type": "text/plain"}
            if auth is not None:
                headers["Authorization"] = auth
            async with self.client.post(self.gateway.make_url("/ping/v1/decision"), headers=headers,
                                         data="invalid json") as response:
                self.assertEqual(response.status, 401)
                self.assertEqual((await response.json())["error"]["code"], "unauthorized")
        self.assertEqual(self.calls, [])

    async def test_missing_configuration_is_rejected(self):
        for args in (("", "key", TOKEN), ("key", "", TOKEN), ("key", "key", "short")):
            with self.assertRaises(ValueError):
                Settings(*args)

    async def test_fixed_routes_and_provider_key_isolation(self):
        self.assertEqual(DECISION_MODEL, "jev-1.14")
        async with await self.post() as response:
            self.assertEqual(response.status, 200)
            self.assertEqual((await response.json())["model"], DECISION_MODEL)
        async with await self.post("explanation", explanation()) as response:
            self.assertEqual(response.status, 200)
            self.assertIn(b"[DONE]", await response.read())
            self.assertEqual(response.headers["X-Accel-Buffering"], "no")
        self.assertEqual([(call["path"], call["auth"], call["body"]["model"]) for call in self.calls], [
            ("/decision", "Bearer private-beat-key", DECISION_MODEL),
            ("/explanation", "Bearer private-agent-key", EXPLANATION_MODEL)])
        self.assertTrue(all(call["cookie"] is None for call in self.calls))
        self.assertTrue(all(call["encoding"] == "identity" for call in self.calls))
        self.assertEqual(self.calls[1]["body"]["thinking"], {"type": "disabled"})
        self.assertIs(self.calls[1]["body"]["stream"], True)
        self.assertEqual(self.calls[1]["body"]["max_tokens"], 400)

    async def test_model_and_cost_overrides_are_rejected(self):
        cases = [("decision", {**decision(), "model": "expensive-model"}),
                 ("decision", {**decision(), "model": "jev-1.14-free"}),
                 ("decision", {**decision(), "url": "https://attacker.invalid"})]
        for override in ({"model": "expensive-model"}, {"thinking": {"type": "enabled"}},
                         {"stream": False}, {"max_tokens": 1601}, {"max_tokens": True},
                         {"max_tokens": 0}, {"tools": []}, {"temperature": 2}):
            cases.append(("explanation", {**explanation(), **override}))
        for route, body in cases:
            async with await self.post(route, body) as response:
                self.assertEqual(response.status, 400)
        self.assertEqual(self.calls, [])

    async def test_remote_images_and_extra_messages_are_rejected(self):
        body = explanation()
        body["messages"][1]["content"].append({"type": "image_url", "image_url": {"url": "https://example.com/image.png"}})
        async with await self.post("explanation", body) as response:
            self.assertEqual(response.status, 400)
        body = explanation()
        body["messages"].append({"role": "user", "content": "extra"})
        async with await self.post("explanation", body) as response:
            self.assertEqual(response.status, 400)
        self.assertEqual(self.calls, [])

    async def test_translation_sized_output_limit_is_accepted(self):
        body = explanation()
        body["max_tokens"] = 1600
        async with await self.post("explanation", body) as response:
            self.assertEqual(response.status, 200)
            await response.read()
        self.assertEqual(self.calls[0]["body"]["max_tokens"], 1600)

    async def test_inline_image_and_lower_output_limit(self):
        body = explanation()
        body["max_tokens"] = 200
        body["messages"][1]["content"].append({"type": "image_url", "image_url": {"url": "data:image/png;base64,aW1hZ2U="}})
        async with await self.post("explanation", body) as response:
            self.assertEqual(response.status, 200)
            await response.read()
        self.assertEqual(self.calls[0]["body"]["max_tokens"], 200)

    async def test_content_type_json_and_size_validation(self):
        cases = [("text/plain", b"{}", 415), ("application/json", b"[]", 400),
                 ("application/json", b'{"a":1,"a":2}', 400),
                 ("application/json", b'{"a":NaN}', 400),
                 ("application/json", b"{broken", 400),
                 ("application/json", b" " * (MAX_REQUEST_BYTES + 1), 413)]
        for content_type, raw, expected in cases:
            async with self.client.post(self.gateway.make_url("/ping/v1/decision"), data=io.BytesIO(raw),
                                         headers={**AUTH, "Content-Type": content_type}) as response:
                self.assertEqual(response.status, expected)
                await response.read()
        self.assertEqual(self.calls, [])

    async def test_field_limits_and_shape_validation(self):
        for mutate in (lambda b: b["state"]["evidence"].update(target="x" * 4001),
                       lambda b: b["state"]["evidence"].update(application="x" * 201),
                       lambda b: b["state"]["evidence"].update(window_title="x" * 301),
                       lambda b: b["state"].update(task="x" * 6001),
                       lambda b: b["questions"]["acquisition"].update(criteria={}),
                       lambda b: b["state"].update(evidence=[])):
            body = decision()
            mutate(body)
            async with await self.post(body=body) as response:
                self.assertEqual(response.status, 400)
        self.assertEqual(self.calls, [])

    async def test_visual_decision_preserves_image_and_original_point(self):
        body = decision()
        body.pop("model")
        async with await self.post(body=body) as response:
            self.assertEqual(response.status, 200)
            self.assertEqual((await response.json())["answers"]["acquisition"]["choice"], "use_current")
        self.assertEqual(self.calls[0]["body"], {**body, "model": DECISION_MODEL})
        self.assertEqual(self.calls[0]["body"]["state"]["evidence"]["target"], "")

    async def test_image_dimension_boundaries_and_jpeg_alias_are_accepted(self):
        assets = [screen_asset(png_image(width, height)) for width, height in ((280, 1568), (1568, 280))]
        assets.extend(screen_asset(JPEG_IMAGE, image_format) for image_format in ("jpg", "jpeg"))
        for asset in assets:
            with self.subTest(image_format=asset["format"], size=len(asset["data_base64"])):
                body = decision()
                body["assets"]["screen"] = asset
                async with await self.post(body=body) as response:
                    self.assertEqual(response.status, 200)
                    await response.read()
                self.assertEqual(self.calls[-1]["body"]["assets"]["screen"], asset)

    async def test_each_image_dimension_must_stay_in_bounds(self):
        for width, height in ((279, 320), (320, 279), (1569, 320), (320, 1569)):
            with self.subTest(width=width, height=height):
                body = decision()
                body["assets"]["screen"] = screen_asset(png_image(width, height))
                async with await self.post(body=body) as response:
                    self.assertEqual(response.status, 400)
        self.assertEqual(self.calls, [])

    async def test_image_magic_and_declared_format_must_match(self):
        for data, image_format in ((b"not an image", "png"), (b"\x89PNG\r\n\x1a\n", "png"),
                                   (b"\xff\xd8\xff\xc0\x00\x11", "jpg"), (JPEG_IMAGE, "png"),
                                   (png_image(), "jpg"), (png_image(), "webp")):
            with self.subTest(image_format=image_format, prefix=data[:8]):
                body = decision()
                body["assets"]["screen"] = screen_asset(data, image_format)
                async with await self.post(body=body) as response:
                    self.assertEqual(response.status, 400)
        self.assertEqual(self.calls, [])

    async def test_non_string_image_format_is_a_client_error(self):
        for image_format in (None, True, 1, [], {}):
            with self.subTest(image_format=image_format):
                body = decision()
                body["assets"]["screen"]["format"] = image_format
                async with await self.post(body=body) as response:
                    self.assertEqual(response.status, 400)
        self.assertEqual(self.calls, [])

    async def test_image_base64_must_be_strict_and_nonempty(self):
        for encoded in ("", "%%%", "AAA", "aW1hZ2U=\n", None, [], 1):
            with self.subTest(encoded=encoded):
                body = decision()
                body["assets"]["screen"]["data_base64"] = encoded
                async with await self.post(body=body) as response:
                    self.assertEqual(response.status, 400)
        self.assertEqual(self.calls, [])

    async def test_encoded_and_decoded_image_size_limits(self):
        png = png_image()
        # The decoded limit is separate from the base64 character limit: 8,000,001
        # bytes still encode to the allowed 10,666,668 characters.
        encoded_cases = ("A" * 10_666_669,
                         base64.b64encode(png + b"\x00" * (8_000_001 - len(png))).decode("ascii"))
        self.assertEqual(len(encoded_cases[1]), 10_666_668)
        for encoded in encoded_cases:
            body = decision()
            body["assets"]["screen"]["data_base64"] = encoded
            async with self.client.post(self.gateway.make_url("/ping/v1/decision"),
                                        data=io.BytesIO(json.dumps(body).encode()),
                                        headers={**AUTH, "Content-Type": "application/json"}) as response:
                self.assertEqual(response.status, 400)
        self.assertEqual(self.calls, [])

    async def test_original_point_accepts_normalized_edges(self):
        for point in ({"x": 0, "y": 1}, {"x": 1.0, "y": 0.0}):
            body = decision()
            body["state"]["capture_metadata"]["point_in_image"] = point
            async with await self.post(body=body) as response:
                self.assertEqual(response.status, 200)
                await response.read()
            self.assertEqual(self.calls[-1]["body"]["state"]["capture_metadata"]["point_in_image"], point)

    async def test_original_point_rejects_missing_non_numeric_and_outside_values(self):
        points = ({}, {"x": 0}, {"y": 0}, [], None, {"x": 0, "y": 0, "origin": "bottom_left"})
        points += tuple({"x": value, "y": 0.5} for value in (-0.01, 1.01, True, "0.5", None))
        points += tuple({"x": 0.5, "y": value} for value in (-0.01, 1.01, False, "0.5", None))
        for point in points:
            with self.subTest(point=point):
                body = decision()
                body["state"]["capture_metadata"]["point_in_image"] = point
                async with await self.post(body=body) as response:
                    self.assertEqual(response.status, 400)
        self.assertEqual(self.calls, [])

    async def test_decision_requires_one_inline_point_anchored_screen_asset(self):
        mutations = (
            lambda b: b.pop("assets"),
            lambda b: b.update(assets={}),
            lambda b: b["assets"].update(other=screen_asset()),
            lambda b: b["assets"].update(screen={"type": "image", "url": "https://example.com/screen.png"}),
            lambda b: b["assets"]["screen"].update(url="file:///private/screen.png"),
            lambda b: b["state"].update(image="https://example.com/screen.png"),
            lambda b: b["state"]["capture_metadata"].update(has_point_anchored_image=False),
            lambda b: b["state"]["capture_metadata"].pop("point_in_image"),
        )
        for index, mutate in enumerate(mutations):
            with self.subTest(case=index):
                body = decision()
                mutate(body)
                async with await self.post(body=body) as response:
                    self.assertEqual(response.status, 400)
        self.assertEqual(self.calls, [])

    async def test_acquisition_only_allows_scope_choices(self):
        for choice in ("use_current", "expand_visual"):
            body = decision()
            body["questions"]["acquisition"]["criteria"] = {choice: "scope"}
            async with await self.post(body=body) as response:
                self.assertEqual(response.status, 200)
                await response.read()
        self.assertEqual(len(self.calls), 2)
        self.calls.clear()
        mutations = (
            lambda b: b["questions"].update(answer={"type": "text"}),
            lambda b: b["questions"]["acquisition"].update(type="text"),
            lambda b: b["questions"]["acquisition"].update(criteria={"read_ocr": "read text"}),
            lambda b: b["questions"]["acquisition"]["criteria"].update(answer="answer user"),
            lambda b: b["questions"]["acquisition"].update(criteria={"use_current": 1}),
        )
        for index, mutate in enumerate(mutations):
            with self.subTest(case=index):
                body = decision()
                mutate(body)
                async with await self.post(body=body) as response:
                    self.assertEqual(response.status, 400)
        self.assertEqual(self.calls, [])

    async def test_compressed_requests_preserve_decompressed_size_limit(self):
        async with self.client.post(self.gateway.make_url("/ping/v1/decision"),
                                     data=gzip.compress(b" " * (MAX_REQUEST_BYTES + 1)),
                                     headers={**AUTH, "Content-Type": "application/json", "Content-Encoding": "gzip"}) as response:
            self.assertEqual(response.status, 413)
        self.assertEqual(self.calls, [])

    async def test_body_read_timeout_precedes_upstream(self):
        await self.start_gateway(body_timeout=0.05)

        async def body():
            yield b"{"
            await asyncio.Event().wait()

        async with self.client.post(self.gateway.make_url("/ping/v1/decision"), data=body(),
                                     headers={**AUTH, "Content-Type": "application/json"}) as response:
            self.assertEqual(response.status, 408)
        self.assertEqual(self.calls, [])
        self.assertEqual(self.active_requests(), 0)

    async def test_slow_uploads_leave_model_slots_available(self):
        for slots in (1, 6):
            with self.subTest(slots=slots):
                await self.start_gateway(max_concurrent=slots)
                async with self.slow_uploads(slots) as (tasks, release, finished):
                    self.assertEqual(self.active_requests(), 0)
                    for _ in range(3):
                        async with await self.post("explanation", explanation()) as response:
                            self.assertEqual(response.status, 200)
                            await response.read()
                    release.set()
                    for task in tasks:
                        async with await task as response:
                            self.assertEqual(response.status, 200)
                            await response.read()
                self.assertEqual(self.active_requests(), 0)

    async def test_cancelled_upload_does_not_release_an_unacquired_slot(self):
        await self.start_gateway(max_concurrent=1)
        async with self.slow_uploads(1):
            self.assertEqual(self.active_requests(), 0)
        self.assertEqual(self.active_requests(), 0)
        started, release = asyncio.Event(), asyncio.Event()

        async def behavior(request):
            started.set()
            await release.wait()
            return web.json_response({"model": DECISION_MODEL})

        self.behavior = behavior
        task = asyncio.create_task(self.post())
        try:
            await asyncio.wait_for(started.wait(), 1)
            self.assertEqual(self.active_requests(), 1)
            async with await self.post() as response:
                self.assertEqual(response.status, 503)
        finally:
            release.set()
            async with await task as response:
                await response.read()
        self.assertEqual(self.active_requests(), 0)

    async def test_timed_out_upload_does_not_acquire_slot_or_consume_quota(self):
        await self.start_gateway(max_concurrent=1, requests_per_minute=1, body_timeout=0.05)
        async with self.slow_uploads(1) as (tasks, release, finished):
            self.assertEqual(self.active_requests(), 0)
            async with await tasks[0] as response:
                self.assertEqual(response.status, 408)
                await response.read()
        self.assertEqual(self.active_requests(), 0)
        async with await self.post() as response:
            self.assertEqual(response.status, 200)
            await response.read()
        self.assertEqual(self.active_requests(), 0)
        async with await self.post() as response:
            self.assertEqual(response.status, 429)

    async def test_redirect_and_upstream_errors_do_not_leak_body(self):
        for status in (302, 401, 500):
            async def behavior(request):
                return web.Response(status=status, text="private captured text and provider key",
                                    headers={"Location": str(self.upstream.make_url("/redirected"))})
            self.behavior = behavior
            async with await self.post() as response:
                self.assertEqual(response.status, 502)
                self.assertEqual(await response.json(), {"error": {"code": "upstream_unavailable"}})
        self.assertEqual(len(self.calls), 3)

    async def test_upstream_json_and_sse_content_type(self):
        async def behavior(request):
            return web.Response(text="private text", content_type="text/plain")
        self.behavior = behavior
        for route, body in (("decision", decision()), ("explanation", explanation())):
            async with await self.post(route, body) as response:
                self.assertEqual(response.status, 502)
                self.assertNotIn("private", await response.text())

    async def test_first_sse_chunk_arrives_before_upstream_finishes(self):
        release = asyncio.Event()
        first = b'data: {"choices":[{"delta":{"content":"hello"}}]}\n\n'

        async def behavior(request):
            response = web.StreamResponse(headers={"Content-Type": "text/event-stream"})
            await response.prepare(request)
            await response.write(first)
            await release.wait()
            await response.write(b"data: [DONE]\n\n")
            return response

        self.behavior = behavior
        async with await self.post("explanation", explanation()) as response:
            received = await asyncio.wait_for(response.content.readexactly(len(first)), timeout=0.5)
            self.assertEqual(received, first)
            self.assertFalse(release.is_set())
            release.set()
            self.assertEqual(await response.read(), b"data: [DONE]\n\n")

    async def test_client_cancellation_closes_upstream_before_headers(self):
        started, cancelled = asyncio.Event(), asyncio.Event()

        async def behavior(request):
            started.set()
            try:
                await asyncio.Event().wait()
            finally:
                cancelled.set()

        self.behavior = behavior
        task = asyncio.create_task(self.post())
        await asyncio.wait_for(started.wait(), 1)
        task.cancel()
        with self.assertRaises(asyncio.CancelledError):
            await task
        await asyncio.wait_for(cancelled.wait(), 1)

    async def test_client_cancellation_closes_streaming_upstream(self):
        cancelled = asyncio.Event()

        async def behavior(request):
            response = web.StreamResponse(headers={"Content-Type": "text/event-stream"})
            await response.prepare(request)
            await response.write(b"data: first\n\n")
            try:
                await asyncio.Event().wait()
            finally:
                cancelled.set()

        self.behavior = behavior
        response = await self.post("explanation", explanation())
        self.assertEqual(await response.content.readexactly(13), b"data: first\n\n")
        response.close()
        await asyncio.wait_for(cancelled.wait(), 1)

    async def test_timeout_closes_upstream(self):
        cancelled = asyncio.Event()

        async def behavior(request):
            try:
                await asyncio.Event().wait()
            finally:
                cancelled.set()

        self.behavior = behavior
        await self.start_gateway(decision_timeout=0.1)
        async with await self.post() as response:
            self.assertEqual(response.status, 504)
            self.assertEqual(await response.json(), {"error": {"code": "upstream_timeout"}})
        await asyncio.wait_for(cancelled.wait(), 1)

    async def test_midstream_timeout_is_an_incomplete_stream(self):
        cancelled = asyncio.Event()

        async def behavior(request):
            response = web.StreamResponse(headers={"Content-Type": "text/event-stream"})
            await response.prepare(request)
            await response.write(b"data: first\n\n")
            try:
                await asyncio.Event().wait()
            finally:
                cancelled.set()

        self.behavior = behavior
        await self.start_gateway(explanation_timeout=0.1)
        async with await self.post("explanation", explanation()) as response:
            self.assertEqual(await response.content.readexactly(13), b"data: first\n\n")
            with self.assertRaises(aiohttp.ClientPayloadError):
                await response.read()
        await asyncio.wait_for(cancelled.wait(), 1)

    async def test_busy_request_does_not_consume_admitted_request_quota(self):
        await self.start_gateway(max_concurrent=1, requests_per_minute=2)
        started, release = asyncio.Event(), asyncio.Event()

        async def behavior(request):
            started.set()
            await release.wait()
            return web.json_response({"model": DECISION_MODEL})

        self.behavior = behavior
        first = asyncio.create_task(self.post())
        try:
            await asyncio.wait_for(started.wait(), 1)
            # Both routes share capacity. Rejected work must not exhaust the quota.
            async with await self.post("explanation", explanation()) as response:
                self.assertEqual(response.status, 503)
            release.set()
            async with await first as response:
                self.assertEqual(response.status, 200)
                await response.read()
            async with await self.post() as response:
                self.assertEqual(response.status, 200)
                await response.read()
            async with await self.post() as response:
                self.assertEqual(response.status, 429)
            self.assertEqual(len(self.calls), 2)
        finally:
            release.set()
            if not first.done():
                first.cancel()
            await asyncio.gather(first, return_exceptions=True)

    async def test_rate_limit_and_concurrency_are_bounded(self):
        await self.start_gateway(requests_per_minute=1)
        async with await self.post() as response:
            self.assertEqual(response.status, 200)
            await response.read()
        async with await self.post() as response:
            self.assertEqual(response.status, 429)
        await self.start_gateway(max_concurrent=1)
        started, release = asyncio.Event(), asyncio.Event()

        async def behavior(request):
            started.set()
            await release.wait()
            return web.json_response({"model": DECISION_MODEL})

        self.behavior = behavior
        first = asyncio.create_task(self.post())
        await asyncio.wait_for(started.wait(), 1)
        async with await self.post() as response:
            self.assertEqual(response.status, 503)
        release.set()
        response = await first
        await response.read()
        response.close()


if __name__ == "__main__":
    unittest.main()
