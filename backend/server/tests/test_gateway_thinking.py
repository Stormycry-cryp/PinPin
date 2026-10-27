"""Explicit low-thinking contract against loopback fake upstreams only."""

import asyncio
import base64
import copy
import json
import unittest
from unittest.mock import patch

import aiohttp
from aiohttp import web

import test_gateway as fixture


def thinking_body(**overrides):
    return {**fixture.explanation(), "thinking": {"type": "enabled"},
            "reasoning_effort": "low", "max_tokens": 1600, **overrides}


class GatewayThinkingTests(unittest.IsolatedAsyncioTestCase):
    # Reuse setup helpers, without inheriting or rerunning the original methods.
    asyncSetUp = fixture.GatewayTests.asyncSetUp
    asyncTearDown = fixture.GatewayTests.asyncTearDown
    start_gateway = fixture.GatewayTests.start_gateway
    post = fixture.GatewayTests.post
    active_requests = fixture.GatewayTests.active_requests

    async def assert_invalid(self, body):
        before = len(self.calls)
        async with await self.post("explanation", body) as response:
            self.assertEqual(response.status, 400)
            self.assertEqual(await response.json(), {"error": {"code": "invalid_request"}})
        self.assertEqual(len(self.calls), before)

    async def test_omitted_and_explicit_disabled_keep_existing_defaults(self):
        original = fixture.explanation()
        for body in ({"messages": original["messages"]}, original):
            with self.subTest(explicit="thinking" in body):
                async with await self.post("explanation", body) as response:
                    self.assertEqual(response.status, 200)
                    await response.read()
                self.assertEqual(self.calls[-1]["body"], original)
                self.assertNotIn("reasoning_effort", self.calls[-1]["body"])

    async def test_enabled_low_preserves_complete_body_image_and_provider_auth(self):
        body = thinking_body()
        body["messages"][0]["content"] = "只解释用户关注的内容。"
        body["messages"][1]["content"][0]["text"] = "原点 x=0.25 y=0.75"
        body["messages"][1]["content"].append({"type": "image_url", "image_url": {
            "url": "data:image/png;base64," + base64.b64encode(fixture.png_image()).decode()}})
        frozen = copy.deepcopy(body)
        async with await self.post("explanation", body) as response:
            self.assertEqual(response.status, 200)
            await response.read()
        self.assertEqual(body, frozen)
        self.assertEqual(self.calls[0]["body"], frozen)
        self.assertEqual(self.calls[0]["path"], "/explanation")
        self.assertEqual(self.calls[0]["auth"], "Bearer private-agent-key")
        self.assertIsNone(self.calls[0]["cookie"])
        self.assertEqual(self.calls[0]["encoding"], "identity")

    async def test_thinking_requires_exact_supported_object(self):
        for value in (None, True, 1, "enabled", [], {}, {"type": True}, {"type": "ENABLED"},
                      {"type": "auto"}, {"type": "enabled", "extra": 1},
                      {"type": "disabled", "reasoning_effort": "low"}):
            with self.subTest(thinking=value):
                await self.assert_invalid(thinking_body(thinking=value))

    async def test_enabled_requires_explicit_exact_low_effort(self):
        missing = thinking_body()
        missing.pop("reasoning_effort")
        await self.assert_invalid(missing)
        for value in (None, True, 1, [], {}, "", "LOW", "minimal", "medium", "high", "max"):
            with self.subTest(effort=value):
                await self.assert_invalid(thinking_body(reasoning_effort=value))

    async def test_disabled_or_omitted_thinking_rejects_every_effort_field(self):
        for explicit in (True, False):
            for value in ("low", "high", None, True, 0, {}, []):
                with self.subTest(explicit=explicit, effort=value):
                    body = {**fixture.explanation(), "reasoning_effort": value}
                    if not explicit:
                        body.pop("thinking")
                    await self.assert_invalid(body)

    async def test_enabled_output_budget_edges_and_default_remain_unchanged(self):
        for limit in (1, 1600, "omitted"):
            body = thinking_body(max_tokens=limit)
            if limit == "omitted":
                body.pop("max_tokens")
            async with await self.post("explanation", body) as response:
                self.assertEqual(response.status, 200)
                await response.read()
            self.assertEqual(self.calls[-1]["body"]["max_tokens"], 400 if limit == "omitted" else limit)
        for limit in (0, -1, 1601, True, False, 1600.0, "1600", None):
            with self.subTest(limit=limit):
                await self.assert_invalid(thinking_body(max_tokens=limit))

    async def test_enabled_does_not_relax_model_stream_or_message_contract(self):
        for override in ({"model": "another-model"}, {"stream": False}, {"tools": []},
                         {"url": "https://example.invalid"}):
            await self.assert_invalid(thinking_body(**override))
        extra = thinking_body()
        extra["messages"].append({"role": "user", "content": []})
        await self.assert_invalid(extra)
        remote = thinking_body()
        remote["messages"][1]["content"].append({"type": "image_url", "image_url": {
            "url": "https://example.invalid/image.png"}})
        await self.assert_invalid(remote)

    async def test_enabled_reasoning_and_final_sse_pass_through_exactly(self):
        first = ('data: ' + json.dumps({"choices": [{"delta": {
            "reasoning_content": "仅供本地测试的推理片段"}}]}, ensure_ascii=False) + '\n\n').encode()
        final = ('data: ' + json.dumps({"choices": [{"delta": {"content": "最终正文"},
                    "finish_reason": "stop"}], "usage": {"completion_tokens": 12,
                    "completion_tokens_details": {"reasoning_tokens": 7}}}, ensure_ascii=False)
                 + '\n\ndata: [DONE]\n\n').encode()
        release = asyncio.Event()

        async def behavior(request):
            stream = web.StreamResponse(headers={"Content-Type": "text/event-stream"})
            await stream.prepare(request)
            # Even a split inside UTF-8 stays untouched: gateway streams bytes.
            split = first.index("仅".encode()) + 1
            for fragment in (first[:split], first[split:]):
                await stream.write(fragment)
            await release.wait()
            await stream.write(final)
            return stream

        self.behavior = behavior
        async with await self.post("explanation", thinking_body()) as response:
            self.assertEqual(response.status, 200)
            self.assertEqual(response.headers["X-Accel-Buffering"], "no")
            received = await asyncio.wait_for(response.content.readexactly(len(first)), 1)
            self.assertEqual(received, first)
            release.set()
            self.assertEqual(received + await response.read(), first + final)

    async def test_enabled_unauthorized_never_reads_body_or_contacts_provider(self):
        with patch("gateway.read_body", side_effect=AssertionError("body read before authentication")) as read:
            async with self.client.post(self.gateway.make_url("/ping/v1/explanation"),
                                        json=thinking_body(), headers={"Authorization": "Bearer wrong"}) as response:
                self.assertEqual(response.status, 401)
                self.assertEqual(await response.json(), {"error": {"code": "unauthorized"}})
            read.assert_not_called()
        self.assertEqual(self.calls, [])

    async def test_enabled_client_cancel_closes_upstream_and_releases_slot(self):
        cancelled = asyncio.Event()
        first = b'data: {"choices":[{"delta":{"reasoning_content":"local fixture"}}]}\n\n'

        async def behavior(request):
            stream = web.StreamResponse(headers={"Content-Type": "text/event-stream"})
            await stream.prepare(request)
            await stream.write(first)
            try:
                await asyncio.Event().wait()
            finally:
                cancelled.set()

        self.behavior = behavior
        response = await self.post("explanation", thinking_body())
        self.assertEqual(await response.content.readexactly(len(first)), first)
        response.close()
        await asyncio.wait_for(cancelled.wait(), 1)
        self.assertEqual(self.active_requests(), 0)

    async def test_enabled_timeout_still_ends_as_incomplete_sse(self):
        cancelled = asyncio.Event()
        first = b'data: {"choices":[{"delta":{"reasoning_content":"local fixture"}}]}\n\n'

        async def behavior(request):
            stream = web.StreamResponse(headers={"Content-Type": "text/event-stream"})
            await stream.prepare(request)
            await stream.write(first)
            try:
                await asyncio.Event().wait()
            finally:
                cancelled.set()

        self.behavior = behavior
        await self.start_gateway(explanation_timeout=0.05)
        async with await self.post("explanation", thinking_body()) as response:
            self.assertEqual(await response.content.readexactly(len(first)), first)
            with self.assertRaises(aiohttp.ClientPayloadError):
                await response.read()
        await asyncio.wait_for(cancelled.wait(), 1)
        self.assertEqual(self.active_requests(), 0)

    async def test_decision_rejects_thinking_fields_and_keeps_jev_unchanged(self):
        for override in ({"thinking": {"type": "enabled"}}, {"reasoning_effort": "low"}):
            async with await self.post("decision", {**fixture.decision(), **override}) as response:
                self.assertEqual(response.status, 400)
        self.assertEqual(self.calls, [])
        async with await self.post("decision", fixture.decision()) as response:
            self.assertEqual(response.status, 200)
            await response.read()
        self.assertEqual(self.calls[0]["body"], fixture.decision())
        self.assertEqual(self.calls[0]["auth"], "Bearer private-beat-key")
