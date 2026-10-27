"""Gzip transport regressions using the existing loopback gateway fixture."""

import base64
import gzip
import io
import json
import unittest
from unittest.mock import patch

from aiohttp import web

import test_gateway as fixture


class GatewayGzipTests(unittest.IsolatedAsyncioTestCase):
    # Reuse the fixture without inheriting and rerunning its existing test methods.
    asyncSetUp = fixture.GatewayTests.asyncSetUp
    asyncTearDown = fixture.GatewayTests.asyncTearDown
    start_gateway = fixture.GatewayTests.start_gateway

    async def wire_post(self, route, raw, *, encoding, auth=fixture.AUTH):
        return await self.client.post(
            self.gateway.make_url("/ping/v1/" + route), data=io.BytesIO(raw),
            headers={**auth, "Content-Type": "application/json", "Content-Encoding": encoding})

    @staticmethod
    def payload(route):
        image = fixture.png_image()
        if route == "decision":
            body = fixture.decision()
            body.pop("model")  # Exercise the unchanged provider model normalization.
            body["state"]["evidence"]["application"] = "本地测试"
            body["state"]["capture_metadata"]["point_in_image"] = {"x": 0.125, "y": 0.875}
        else:
            body = {"messages": fixture.explanation()["messages"]}
            body["messages"][1]["content"][0]["text"] = "解释原点附近的内容。"
            body["messages"][1]["content"].append({
                "type": "image_url", "image_url": {
                    "url": "data:image/png;base64," + base64.b64encode(image).decode("ascii")}})
        return body, image

    @staticmethod
    def encoded(body):
        return json.dumps(body, ensure_ascii=False, separators=(",", ":")).encode("utf-8")

    async def test_identity_and_gzip_preserve_normalized_provider_body_and_image(self):
        provider_raw = []
        sse = b'data: {"choices":[{"delta":{"content":"hello"}}]}\n\ndata: [DONE]\n\n'

        async def behavior(request):
            # The shared fixture has cached these exact provider wire bytes via request.json().
            provider_raw.append(await request.read())
            if request.path == "/decision":
                return web.json_response({"model": fixture.DECISION_MODEL})
            return web.Response(body=sse, content_type="text/event-stream")

        self.behavior = behavior
        for route in ("decision", "explanation"):
            with self.subTest(route=route):
                self.calls.clear()
                provider_raw.clear()
                body, image = self.payload(route)
                raw = self.encoded(body)
                responses = []
                for encoding in ("identity", "gzip"):
                    wire = raw if encoding == "identity" else gzip.compress(raw, mtime=0)
                    async with await self.wire_post(route, wire, encoding=encoding) as response:
                        self.assertEqual(response.status, 200)
                        responses.append(await response.read())
                        if route == "explanation":
                            self.assertEqual(response.headers["X-Accel-Buffering"], "no")
                self.assertEqual(len(self.calls), 2)
                self.assertEqual(provider_raw[0], provider_raw[1])
                self.assertEqual(responses[0], responses[1])
                expected = {**body, "model": fixture.DECISION_MODEL} if route == "decision" else {
                    **body, "model": fixture.EXPLANATION_MODEL, "thinking": {"type": "disabled"},
                    "stream": True, "max_tokens": 400}
                self.assertEqual(self.calls[0]["body"], expected)
                self.assertEqual(self.calls[1]["body"], expected)
                if route == "decision":
                    encoded_image = expected["assets"]["screen"]["data_base64"]
                else:
                    encoded_image = expected["messages"][1]["content"][1]["image_url"]["url"].split(",", 1)[1]
                    self.assertEqual(responses[0], sse)
                self.assertEqual(base64.b64decode(encoded_image, validate=True), image)

    async def test_unauthorized_gzip_never_reads_body_or_calls_upstream(self):
        with patch("gateway.read_body", side_effect=AssertionError("unauthorized body was read")) as read_body:
            for route in ("decision", "explanation"):
                for auth in ({}, {"Authorization": "Bearer wrong"}):
                    with self.subTest(route=route, authenticated=bool(auth)):
                        async with await self.wire_post(route, b"not-gzip", encoding="gzip", auth=auth) as response:
                            self.assertEqual(response.status, 401)
                            self.assertEqual(await response.json(), {"error": {"code": "unauthorized"}})
            read_body.assert_not_called()
        self.assertEqual(self.calls, [])

    async def test_invalid_truncated_crc_and_trailing_gzip_never_call_upstream(self):
        for route in ("decision", "explanation"):
            raw = self.encoded(self.payload(route)[0])
            valid = gzip.compress(raw, mtime=0)
            bad_crc = bytearray(valid)
            bad_crc[-8] ^= 1
            cases = {"not_gzip": raw, "truncated": valid[:-4], "bad_crc": bytes(bad_crc),
                     "trailing_bytes": valid + b"trailing", "second_member": valid + gzip.compress(b"{}", mtime=0)}
            for case, wire in cases.items():
                with self.subTest(route=route, case=case):
                    async with await self.wire_post(route, wire, encoding="gzip") as response:
                        self.assertEqual(response.status, 400)
                        self.assertEqual(await response.json(), {"error": {"code": "invalid_request"}})
        self.assertEqual(self.calls, [])

    async def test_gzip_cannot_bypass_original_twelve_mib_boundary(self):
        # The existing aiohttp request.read() accepts exactly client_max_size bytes.
        # Valid JSON plus whitespace isolates that byte limit from field/image limits.
        for route in ("decision", "explanation"):
            compact = self.encoded(self.payload(route)[0])
            for size, expected_status in ((fixture.MAX_REQUEST_BYTES - 1, 200),
                                          (fixture.MAX_REQUEST_BYTES, 200),
                                          (fixture.MAX_REQUEST_BYTES + 1, 413)):
                raw = compact + b" " * (size - len(compact))
                for encoding in ("identity", "gzip"):
                    with self.subTest(route=route, size=size, encoding=encoding):
                        self.calls.clear()
                        wire = raw if encoding == "identity" else gzip.compress(raw, mtime=0)
                        if encoding == "gzip":
                            self.assertLess(len(wire), fixture.MAX_REQUEST_BYTES)
                        async with await self.wire_post(route, wire, encoding=encoding) as response:
                            self.assertEqual(response.status, expected_status)
                            result = await response.read()
                            if expected_status == 413:
                                self.assertEqual(json.loads(result), {"error": {"code": "request_too_large"}})
                        self.assertEqual(len(self.calls), 1 if expected_status == 200 else 0)


if __name__ == "__main__":
    unittest.main()
