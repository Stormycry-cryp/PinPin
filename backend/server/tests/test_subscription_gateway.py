"""Real loopback model HTTP only; trusted identity fixtures never call Apple/model services."""

import asyncio
from contextlib import closing
from dataclasses import replace
from datetime import timedelta
import gzip
import json
import multiprocessing
from pathlib import Path
import sqlite3
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch
from uuid import uuid4

import aiohttp
from aiohttp import web
from aiohttp.test_utils import TestServer

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from gateway import DECISION_MODEL, EXPLANATION_MODEL, normalize_decision, normalize_explanation
from subscription_service import SubscriptionService
from subscription_gateway import (COMMERCIAL_EXPLANATION_URL, CommercialGatewaySettings,
                                  OperationPhases, create_subscription_gateway)
from test_gateway import decision, explanation
from test_subscription_service import NOW, TrustedFixtureVerifier


def event(value):
    return ("data: " + (value if isinstance(value, str) else json.dumps(value, ensure_ascii=False)) + "\n\n").encode()


def preview(text="你好", model=EXPLANATION_MODEL):
    return {"model": model, "choices": [{"index": 0, "delta": {"content": text}, "finish_reason": None}]}


def finish(reason="stop"):
    return {"model": EXPLANATION_MODEL, "choices": [{"index": 0, "delta": {}, "finish_reason": reason}],
            "usage": {"prompt_tokens": 5, "completion_tokens": 2, "total_tokens": 7,
                      "completion_tokens_details": {"reasoning_tokens": 0}}}


def good_stream(text="你好"):
    return event(preview(text)) + event(finish()) + event("[DONE]")


def decision_response(body):
    answers = {}
    for name, question in body["questions"].items():
        keys = list(question["criteria"])
        answers[name] = {"type": "choice", "choice": keys[0],
                         "probabilities": {key: int(key == keys[0]) for key in keys}}
    return {"model": DECISION_MODEL, "answers": answers, "usage": {"total_tokens": 3}}


def run_gateway_process(database, upstreams, output):
    async def serve():
        service = SubscriptionService(database, TrustedFixtureVerifier(), clock=lambda: NOW)
        app = create_subscription_gateway(CommercialGatewaySettings("local-beat-test-key", "local-commercial-test-key"),
                                          service, _test_upstreams=upstreams)
        runner = web.AppRunner(app, access_log=None)
        await runner.setup()
        site = web.TCPSite(runner, "127.0.0.1", 0)
        await site.start()
        output.put(site._server.sockets[0].getsockname()[1])
        await asyncio.Event().wait()
    asyncio.run(serve())


class SubscriptionGatewayTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="pinpin-commercial-gateway-test-")
        self.addCleanup(self.temp.cleanup)
        self.database = Path(self.temp.name) / "state.sqlite3"
        self.now = NOW
        self.verifier = TrustedFixtureVerifier()
        self.service = SubscriptionService(self.database, self.verifier, clock=lambda: self.now)
        self.session = self.service.create_session("app.alice.jws")
        self.token = self.session["access_token"]
        self.principal = self.service.authenticate(self.token)
        self.settings = CommercialGatewaySettings("local-beat-test-key", "local-commercial-test-key")
        self.calls = []
        self.behaviors = {}
        self.gateway = None

        async def upstream(request):
            raw = await request.read()
            body = json.loads(raw)
            self.calls.append({"path": request.path, "raw": raw, "body": body,
                               "auth": request.headers.get("Authorization"), "cookie": request.headers.get("Cookie")})
            if request.path in self.behaviors:
                return await self.behaviors[request.path](request, body)
            if request.path == "/decision":
                return web.json_response(decision_response(body))
            return web.Response(body=good_stream(), content_type="text/event-stream")

        upstream_app = web.Application(client_max_size=12*1024*1024)
        upstream_app.router.add_post("/{route}", upstream)
        self.upstream = TestServer(upstream_app, handler_cancellation=True)
        await self.upstream.start_server()
        self.upstreams = tuple(str(self.upstream.make_url("/" + route)) for route in ("decision", "explanation"))
        self.client = aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=10))
        await self.start_gateway()
        self.addAsyncCleanup(self.close_all)

    async def close_all(self):
        await self.client.close()
        if self.gateway:
            await self.gateway.close()
        await self.upstream.close()

    async def start_gateway(self, *, handler_cancellation=True, **settings):
        if self.gateway:
            await self.gateway.close()
        app = create_subscription_gateway(replace(self.settings, **settings), self.service, _test_upstreams=self.upstreams)
        # Exercise the deployment possibility where a client timeout doesn't
        # cancel the server handler immediately, without changing production code.
        app._handler_args["handler_cancellation"] = handler_cancellation
        self.gateway = TestServer(app, handler_cancellation=handler_cancellation)
        await self.gateway.start_server()

    def headers(self, action=None):
        return {"Authorization": "Bearer " + self.token, "X-PinPin-Action-ID": action or str(uuid4())}

    async def post(self, route, body=None, *, action=None, **kwargs):
        return await self.client.post(self.gateway.make_url("/ping/v1/" + route),
                                      json=body if body is not None else (decision() if route == "decision" else explanation()),
                                      headers=self.headers(action), **kwargs)

    def snapshot(self):
        return self.service.ledger.snapshot(self.principal.user_id)

    def action(self, action_id):
        with closing(sqlite3.connect(self.database)) as db:
            return db.execute("SELECT state FROM actions WHERE user_id=? AND action_id=?",
                              (self.principal.user_id, action_id)).fetchone()[0]

    def phase_rows(self):
        with closing(sqlite3.connect(self.database)) as db:
            return db.execute("SELECT phase,state,prompt_tokens,completion_tokens,total_tokens,reasoning_tokens "
                              "FROM subscription_model_phases ORDER BY phase").fetchall()

    async def test_normal_decision_answer_counts_once_and_upstream_bodies_match_accepted_normalizers(self):
        action = str(uuid4())
        response = await self.post("decision", action=action)
        self.assertEqual(response.status, 200)
        await response.read()
        self.assertEqual((self.snapshot().committed, self.snapshot().reserved), (0, 1))
        response = await self.post("explanation", action=action)
        self.assertEqual(response.status, 200)
        self.assertIn(b"[DONE]", await response.read())
        self.assertEqual((self.snapshot().committed, self.snapshot().reserved), (1, 0))
        self.assertEqual(self.calls[0]["raw"], json.dumps(normalize_decision(decision())).encode())
        self.assertEqual(self.calls[1]["raw"], json.dumps(normalize_explanation(explanation())).encode())
        self.assertEqual([c["auth"] for c in self.calls], ["Bearer local-beat-test-key", "Bearer local-commercial-test-key"])
        self.assertEqual(self.phase_rows(), [("answer", "succeeded", 5, 2, 7, 0), ("decision", "succeeded", None, None, 3, None)])
        for route in ("decision", "explanation"):
            duplicate = await self.post(route, action=action)
            self.assertEqual(duplicate.status, 409)
            await duplicate.read()
        self.assertEqual(len(self.calls), 2)

    async def test_enabled_thinking_image_and_gzip_payload_remain_byte_equivalent(self):
        body = explanation()
        body["thinking"] = {"type": "enabled"}
        body["reasoning_effort"] = "low"
        body["max_tokens"] = 1600
        asset = decision()["assets"]["screen"]
        body["messages"][1]["content"].append({"type": "image_url", "image_url": {"url": "data:image/png;base64," + asset["data_base64"]}})
        raw = gzip.compress(json.dumps(body).encode())
        response = await self.client.post(self.gateway.make_url("/ping/v1/explanation"), data=raw,
                                          headers={**self.headers(), "Content-Type": "application/json", "Content-Encoding": "gzip"})
        self.assertIn(b"[DONE]", await response.read())
        self.assertEqual(self.calls[-1]["raw"], json.dumps(normalize_explanation(body)).encode())

    async def test_reply_coaching_two_questions_remain_one_decision_and_one_charge(self):
        body = decision()
        names = {"intent": ["ask_information", "request_action", "share_update", "seek_support", "set_boundary", "disagreement", "unclear", "not_chat"],
                 "reply_strategy": ["承接", "降压", "调侃", "轻推", "约见", "澄清", "收线"]}
        body["questions"] = {key: {"type": "choice", "instructions": "fixture", "criteria": {option: "fixture" for option in values}} for key, values in names.items()}
        action = str(uuid4())
        response = await self.post("decision", body, action=action)
        self.assertEqual(response.status, 200)
        await response.read()
        response = await self.post("explanation", action=action)
        self.assertIn(b"[DONE]", await response.read())
        self.assertEqual(self.snapshot().committed, 1)
        self.assertEqual(len(self.calls), 2)
        self.assertEqual(self.calls[0]["raw"], json.dumps(normalize_decision(body)).encode())

    async def test_not_chat_without_answer_can_release_reservation_immediately(self):
        body = decision()
        names = {"intent": ["ask_information", "request_action", "share_update", "seek_support", "set_boundary", "disagreement", "unclear", "not_chat"],
                 "reply_strategy": ["承接", "降压", "调侃", "轻推", "约见", "澄清", "收线"]}
        body["questions"] = {key: {"type": "choice", "instructions": "fixture", "criteria": {option: "fixture" for option in values}} for key, values in names.items()}
        async def not_chat(request, payload):
            value = decision_response(payload)
            value["answers"]["intent"] = {"type": "choice", "choice": "not_chat",
                "probabilities": {key: int(key == "not_chat") for key in payload["questions"]["intent"]["criteria"]}}
            return web.json_response(value)
        self.behaviors["/decision"] = not_chat
        action = str(uuid4())
        response = await self.post("decision", body, action=action)
        self.assertEqual((await response.json())["answers"]["intent"]["choice"], "not_chat")
        self.assertEqual(self.snapshot().reserved, 1)
        cancelled = await self.client.post(self.gateway.make_url("/ping/v1/subscription/actions/cancel"),
                                           json={"action_id": action}, headers=self.headers(action))
        self.assertEqual((cancelled.status, (await cancelled.json())["state"]), (200, "cancelled"))
        self.assertEqual((self.snapshot().committed, self.snapshot().reserved), (0, 0))
        self.assertEqual(len(self.calls), 1)

    async def test_authenticated_cancel_during_answer_prevents_later_done_and_charge(self):
        release = asyncio.Event()
        async def stream(request, body):
            result = web.StreamResponse(headers={"Content-Type": "text/event-stream"})
            await result.prepare(request)
            await result.write(event(preview()))
            await release.wait()
            await result.write(event(finish()) + event("[DONE]"))
            return result
        self.behaviors["/explanation"] = stream
        action = str(uuid4())
        response = await self.post("explanation", action=action)
        self.assertIn("你好".encode(), await response.content.readuntil(b"\n\n"))
        try:
            cancelled = await self.client.post(self.gateway.make_url("/ping/v1/subscription/actions/cancel"),
                                               json={"action_id": action}, headers=self.headers(action))
            self.assertEqual((await cancelled.json())["state"], "cancelled")
        finally:
            release.set()
        remainder = await response.read()
        self.assertIn(b"action_finished", remainder)
        self.assertNotIn(b"[DONE]", remainder)
        self.assertNotIn(b'"stop"', remainder)
        self.assertEqual((self.snapshot().committed, self.snapshot().reserved), (0, 0))

    async def test_invalid_auth_action_or_body_never_calls_upstream_or_reserves(self):
        for headers in ({"X-PinPin-Action-ID": str(uuid4())},
                        {"Authorization": "Bearer invalid", "X-PinPin-Action-ID": str(uuid4())},
                        {"Authorization": "Bearer " + self.token},
                        self.headers("not-a-uuid"), self.headers("00000000-0000-0000-0000-000000000000")):
            response = await self.client.post(self.gateway.make_url("/ping/v1/explanation"), json=explanation(), headers=headers)
            self.assertIn(response.status, (400, 401))
            await response.read()
        response = await self.post("explanation", {**explanation(), "url": "https://other.invalid"})
        self.assertEqual(response.status, 400)
        await response.read()
        self.assertEqual(self.calls, [])
        self.assertEqual(self.snapshot().reserved, 0)

    async def test_quota_exhaustion_prevents_decision_and_answer_upstreams(self):
        for index in range(20):
            self.service.ledger.reserve(self.principal.user_id, f"used-{index}")
            self.service.ledger.commit(self.principal.user_id, f"used-{index}")
        for route in ("decision", "explanation"):
            response = await self.post(route)
            self.assertEqual(response.status, 402)
            self.assertEqual((await response.json())["error"]["code"], "quota_exceeded")
        self.assertEqual(self.calls, [])

    async def test_first_preview_streams_before_completion_and_before_charge(self):
        gate = asyncio.Event()
        async def streamed(request, body):
            result = web.StreamResponse(headers={"Content-Type": "text/event-stream"})
            await result.prepare(request)
            await result.write(event(preview("第一字")))
            await gate.wait()
            await result.write(event(finish()) + event("[DONE]"))
            await result.write_eof()
            return result
        self.behaviors["/explanation"] = streamed
        response = await self.post("explanation")
        try:
            first = await asyncio.wait_for(response.content.readuntil(b"\n\n"), 1)
            self.assertIn("第一字".encode(), first)
            self.assertEqual((self.snapshot().committed, self.snapshot().reserved), (0, 1))
        finally:
            gate.set()
        self.assertIn(b"[DONE]", await response.read())
        self.assertEqual(self.snapshot().committed, 1)

    async def test_done_and_finish_marker_wait_for_successful_commit(self):
        entered, release = threading.Event(), threading.Event()
        original = self.service.ledger.commit
        def slow_commit(*args, **kwargs):
            entered.set()
            release.wait(5)
            return original(*args, **kwargs)
        with patch.object(self.service.ledger, "commit", side_effect=slow_commit):
            response = await self.post("explanation")
            first = await response.content.readuntil(b"\n\n")
            self.assertNotIn(b'"stop"', first)
            self.assertNotIn(b"[DONE]", first)
            remaining = asyncio.create_task(response.read())
            try:
                self.assertTrue(await asyncio.to_thread(entered.wait, 3))
                await asyncio.sleep(.02)
                self.assertFalse(remaining.done())
                self.assertEqual(self.snapshot().committed, 0)
            finally:
                release.set()
            self.assertIn(b"[DONE]", await remaining)
        self.assertEqual(self.snapshot().committed, 1)

    async def test_utf8_and_crlf_split_across_network_chunks(self):
        raw = good_stream("汉字和 emoji 🐈").replace(b"\n", b"\r\n")
        async def streamed(request, body):
            result = web.StreamResponse(headers={"Content-Type": "text/event-stream"})
            await result.prepare(request)
            for byte in raw:
                await result.write(bytes([byte]))
                await asyncio.sleep(0)
            await result.write_eof()
            return result
        self.behaviors["/explanation"] = streamed
        response = await self.post("explanation")
        result = await response.read()
        self.assertIn("汉字和 emoji 🐈".encode(), result)
        self.assertIn(b"[DONE]", result)
        self.assertEqual(self.snapshot().committed, 1)

    async def test_bad_streams_and_200_errors_release_reservation_without_done(self):
        invalid = [
            event({"error": {"message": "private provider detail"}}),
            event(preview()) + event("[DONE]"),
            event(preview()) + event(finish()),
            event(preview()) + event(finish("length")) + event("[DONE]"),
            event(preview("")) + event(finish()) + event("[DONE]"),
            good_stream("无法读取所指内容"),
            event(preview(model="wrong-model")) + event(finish()) + event("[DONE]"),
            event({"choices": [{"delta": {"content": "no model"}}]}) + event(finish()) + event("[DONE]"),
            event(preview()) + b"data: \xff\n\n",
            event(preview()) + event({**finish(), "usage": {"total_tokens": 1.5}}) + event("[DONE]"),
        ]
        for raw in invalid:
            with self.subTest(raw=raw[:30]):
                async def upstream(request, body):
                    return web.Response(body=raw, content_type="text/event-stream")
                self.behaviors["/explanation"] = upstream
                action = str(uuid4())
                response = await self.post("explanation", action=action)
                result = await response.read()
                self.assertNotIn(b"[DONE]", result)
                self.assertIn(b'"error"', result)
                self.assertNotIn(b"private provider detail", result)
                self.assertEqual(self.action(action), "cancelled")
        self.assertEqual((self.snapshot().committed, self.snapshot().reserved), (0, 0))

    async def test_upstream_json_error_and_non_2xx_release_without_success(self):
        for status in (200, 401, 429, 500):
            async def upstream(request, body):
                return web.json_response({"error": {"message": "upstream-secret"}}, status=status)
            self.behaviors["/explanation"] = upstream
            action = str(uuid4())
            response = await self.post("explanation", action=action)
            self.assertEqual(response.status, 502)
            self.assertNotIn("upstream-secret", await response.text())
            self.assertEqual(self.action(action), "cancelled")
        self.assertEqual(self.snapshot().committed, 0)

    async def test_concurrent_duplicate_answer_calls_upstream_once(self):
        gate = asyncio.Event()
        async def upstream(request, body):
            result = web.StreamResponse(headers={"Content-Type": "text/event-stream"})
            await result.prepare(request)
            await result.write(event(preview()))
            await gate.wait()
            await result.write(event(finish()) + event("[DONE]"))
            return result
        self.behaviors["/explanation"] = upstream
        action = str(uuid4())
        response = await self.post("explanation", action=action)
        try:
            duplicate = await self.post("explanation", action=action)
            self.assertEqual(duplicate.status, 409)
            await duplicate.read()
            self.assertEqual(len(self.calls), 1)
        finally:
            gate.set()
        self.assertIn(b"[DONE]", await response.read())
        self.assertEqual(self.snapshot().committed, 1)

    async def test_answer_fallback_can_run_while_timed_out_client_decision_still_runs(self):
        gate, entered = asyncio.Event(), asyncio.Event()
        async def slow_decision(request, body):
            entered.set()
            await gate.wait()
            return web.json_response(decision_response(body))
        self.behaviors["/decision"] = slow_decision
        await self.start_gateway(handler_cancellation=False)
        action = str(uuid4())
        try:
            with self.assertRaises(TimeoutError):
                await self.post("decision", action=action, timeout=aiohttp.ClientTimeout(total=.05))
            self.assertTrue(entered.is_set())
            response = await self.post("explanation", action=action)
            self.assertIn(b"[DONE]", await response.read())
            self.assertFalse(gate.is_set())
            self.assertEqual(self.action(action), "committed")
            self.assertEqual(self.snapshot().committed, 1)
        finally:
            gate.set()
        # Closing the runner waits for the late decision; it cannot change answer settlement.
        await self.gateway.close()
        self.gateway = None
        self.assertEqual(self.action(action), "committed")
        self.assertEqual(self.snapshot().committed, 1)
        self.assertEqual([c["path"] for c in self.calls], ["/decision", "/explanation"])

    async def test_failed_decision_allows_answer_but_no_second_decision(self):
        async def broken(request, body):
            return web.json_response({"error": {"message": "failed"}})
        self.behaviors["/decision"] = broken
        action = str(uuid4())
        response = await self.post("decision", action=action)
        self.assertEqual(response.status, 502)
        await response.read()
        duplicate = await self.post("decision", action=action)
        self.assertEqual(duplicate.status, 409)
        await duplicate.read()
        self.assertEqual(self.snapshot().committed, 0)
        response = await self.post("explanation", action=action)
        self.assertIn(b"[DONE]", await response.read())
        self.assertEqual((self.snapshot().committed, len(self.calls)), (1, 2))

    async def test_decision_without_answer_expires_after_five_minute_lease(self):
        action = str(uuid4())
        response = await self.post("decision", action=action)
        await response.read()
        self.assertEqual(self.snapshot().reserved, 1)
        self.now += timedelta(minutes=5)
        self.assertEqual((self.snapshot().reserved, self.snapshot().committed), (0, 0))
        response = await self.post("explanation", action=action)
        self.assertEqual(response.status, 409)
        await response.read()
        self.assertEqual(len(self.calls), 1)

    async def test_model_timeout_releases_answer_reservation(self):
        gate = asyncio.Event()
        async def blocked(request, body):
            await gate.wait()
            return web.Response(body=good_stream(), content_type="text/event-stream")
        self.behaviors["/explanation"] = blocked
        await self.start_gateway(explanation_timeout=.04)
        action = str(uuid4())
        try:
            response = await self.post("explanation", action=action)
            self.assertEqual(response.status, 504)
            await response.read()
            self.assertEqual(self.action(action), "cancelled")
            self.assertEqual(self.snapshot().remaining, 20)
        finally:
            gate.set()

    async def test_client_disconnect_cancels_incomplete_answer_and_releases(self):
        gate, settled = asyncio.Event(), threading.Event()
        async def streamed(request, body):
            result = web.StreamResponse(headers={"Content-Type": "text/event-stream"})
            await result.prepare(request)
            await result.write(event(preview()))
            await gate.wait()
            await result.write(event(finish()) + event("[DONE]"))
            return result
        original = OperationPhases.answer_failed
        def record_failure(phases, *args):
            original(phases, *args)
            settled.set()
        self.behaviors["/explanation"] = streamed
        action = str(uuid4())
        with patch.object(OperationPhases, "answer_failed", record_failure):
            response = await self.post("explanation", action=action)
            await response.content.readuntil(b"\n\n")
            response.close()
            try:
                self.assertTrue(await asyncio.to_thread(settled.wait, 3))
                self.assertEqual(self.action(action), "cancelled")
                self.assertEqual((self.snapshot().committed, self.snapshot().reserved), (0, 0))
            finally:
                gate.set()

    async def test_hard_process_restart_keeps_phase_replay_blocked_until_lease_expires(self):
        gate = asyncio.Event()
        async def streamed(request, body):
            result = web.StreamResponse(headers={"Content-Type": "text/event-stream"})
            await result.prepare(request)
            await result.write(event(preview()))
            await gate.wait()
            await result.write(event(finish()) + event("[DONE]"))
            return result
        self.behaviors["/explanation"] = streamed
        context = multiprocessing.get_context("spawn")
        output = context.Queue()
        child = context.Process(target=run_gateway_process, args=(str(self.database), self.upstreams, output))
        child.start()
        response = None
        action = str(uuid4())
        try:
            port = await asyncio.to_thread(output.get, True, 10)
            response = await self.client.post(f"http://127.0.0.1:{port}/ping/v1/explanation", json=explanation(), headers=self.headers(action))
            await response.content.readuntil(b"\n\n")
            # A second live process sees the same phase CAS and cannot duplicate
            # inference, even before the first worker is terminated.
            concurrent = await self.post("explanation", action=action)
            self.assertEqual(concurrent.status, 409)
            await concurrent.read()
            self.assertEqual(len(self.calls), 1)
            child.terminate()
            await asyncio.to_thread(child.join, 5)
            self.assertIsNotNone(child.exitcode)
            response.close()
            self.service = SubscriptionService(self.database, self.verifier, clock=lambda: self.now)
            await self.start_gateway()
            retry = await self.post("explanation", action=action)
            self.assertEqual(retry.status, 409)
            await retry.read()
            self.assertEqual(len(self.calls), 1)
            self.assertEqual(self.snapshot().reserved, 1)
            self.now += timedelta(minutes=5)
            self.assertEqual(self.snapshot().reserved, 0)
            self.assertEqual(self.snapshot().committed, 0)
        finally:
            gate.set()
            if response:
                response.close()
            if child.is_alive():
                child.terminate()
                await asyncio.to_thread(child.join, 5)
            child.close()
            output.close()
            output.join_thread()

    async def test_database_keeps_only_phases_and_integer_usage_not_request_or_answer(self):
        body = explanation()
        private = "PRIVATE-SCREEN-PROMPT-DO-NOT-PERSIST"
        body["messages"][1]["content"][0]["text"] = private
        response = await self.post("explanation", body)
        await response.read()
        with closing(sqlite3.connect(self.database)) as db:
            dump = "\n".join(db.iterdump())
            self.assertNotIn(private, dump)
            self.assertNotIn("你好", dump)
            self.assertNotIn(self.token, dump)
            self.assertNotIn("local-commercial-test-key", dump)
            row = db.execute("SELECT typeof(prompt_tokens),typeof(completion_tokens),typeof(total_tokens),typeof(reasoning_tokens) "
                             "FROM subscription_model_phases WHERE phase='answer'").fetchone()
            self.assertEqual(row, ("integer",)*4)

    async def test_settings_require_separate_commercial_key_and_test_override_rejects_external_hosts(self):
        self.assertEqual(COMMERCIAL_EXPLANATION_URL, "https://ark.cn-beijing.volces.com/api/v3/chat/completions")
        self.assertNotIn(self.settings.commercial_api_key, repr(self.settings))
        with self.assertRaisesRegex(ValueError, "Apple signature verifier"):
            create_subscription_gateway(self.settings, self.service)
        with patch.dict("os.environ", {"BEATAPI_API_KEY": "test", "AGENT_API_KEY": "personal-plan-key"}, clear=True):
            with self.assertRaisesRegex(ValueError, "PINPIN_COMMERCIAL_API_KEY"):
                CommercialGatewaySettings.from_env()
        for url in ("https://127.0.0.1/decision", "http://localhost/decision", "http://example.com/decision",
                    "http://user:secret@127.0.0.1/decision", "http://127.0.0.1/decision?url=elsewhere"):
            with self.assertRaises(ValueError):
                create_subscription_gateway(self.settings, self.service, _test_upstreams=(url, self.upstreams[1]))

    async def test_commit_failure_never_sends_completion_and_releases_without_private_error_logs(self):
        action = str(uuid4())
        with patch.object(self.service.ledger, "commit", side_effect=RuntimeError("private-upstream-secret")):
            with self.assertLogs("pinpin.subscription_gateway", level="ERROR") as captured:
                response = await self.post("explanation", action=action)
                result = await response.read()
        self.assertNotIn(b"[DONE]", result)
        self.assertNotIn(b'"stop"', result)
        self.assertIn(b'"error"', result)
        self.assertNotIn("private-upstream-secret", "".join(captured.output))
        self.assertEqual(self.action(action), "cancelled")
        self.assertEqual((self.snapshot().committed, self.snapshot().reserved), (0, 0))

    async def test_phase_success_storage_failure_rolls_back_charge_with_same_transaction(self):
        action = str(uuid4())
        with self.service._connection() as db:
            db.execute("CREATE TRIGGER fail_success BEFORE UPDATE OF state ON subscription_model_phases "
                       "WHEN NEW.state='succeeded' BEGIN SELECT RAISE(ABORT, 'fixture disk error'); END")
        response = await self.post("explanation", action=action)
        result = await response.read()
        self.assertIn(b'service_unavailable', result)
        self.assertNotIn(b'"stop"', result)
        self.assertNotIn(b"[DONE]", result)
        self.assertEqual(self.action(action), "cancelled")
        self.assertEqual((self.snapshot().committed, self.snapshot().reserved), (0, 0))
        self.assertEqual(self.phase_rows(), [("answer", "failed", None, None, None, None)])
        duplicate = await self.post("explanation", action=action)
        self.assertEqual(duplicate.status, 409)
        await duplicate.read()
        self.assertEqual(len(self.calls), 1)
        with self.service._connection() as db:
            db.execute("DROP TRIGGER fail_success")
        recovered = await self.post("explanation")
        self.assertIn(b"[DONE]", await recovered.read())
        self.assertEqual((self.snapshot().committed, self.snapshot().reserved), (1, 0))


if __name__ == "__main__":
    unittest.main()
