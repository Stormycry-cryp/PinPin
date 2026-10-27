using System.Net;
using System.Text;
using System.Text.Json;
using PinPin.Core;

namespace PinPin.Core.Tests;

internal sealed record SentRequest(HttpMethod Method, string Path, string? Authorization, string? Body);
internal sealed class FakeHttpMessageHandler(Func<SentRequest, CancellationToken, Task<HttpResponseMessage>> respond) : HttpMessageHandler
{
    public readonly List<SentRequest> Requests = [];
    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        var sent = new SentRequest(request.Method, request.RequestUri!.AbsolutePath, request.Headers.Authorization?.ToString(),
            request.Content is null ? null : await request.Content.ReadAsStringAsync(cancellationToken));
        lock (Requests) Requests.Add(sent);
        return await respond(sent, cancellationToken);
    }
}
internal sealed class ChunkedStream(byte[] bytes, int chunk = 1) : Stream
{
    private int index;
    public override bool CanRead => true; public override bool CanSeek => false; public override bool CanWrite => false;
    public override long Length => bytes.Length; public override long Position { get => index; set => throw new NotSupportedException(); }
    public override int Read(byte[] buffer, int offset, int count)
    { int take = Math.Min(Math.Min(chunk, count), bytes.Length - index); Array.Copy(bytes, index, buffer, offset, take); index += take; return take; }
    public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
    { cancellationToken.ThrowIfCancellationRequested(); int take = Math.Min(Math.Min(chunk, buffer.Length), bytes.Length - index); bytes.AsMemory(index, take).CopyTo(buffer); index += take; return ValueTask.FromResult(take); }
    public override void Flush() { } public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
    public override void SetLength(long value) => throw new NotSupportedException(); public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
}
internal sealed class HeldAnswerStream(byte[] bytes, int pauseAt) : Stream
{
    private int index;
    public readonly TaskCompletionSource Paused = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public readonly TaskCompletionSource Continue = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public override bool CanRead => true; public override bool CanSeek => false; public override bool CanWrite => false;
    public override long Length => bytes.Length; public override long Position { get => index; set => throw new NotSupportedException(); }
    public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
    {
        if (index >= pauseAt) { Paused.TrySetResult(); await Continue.Task.WaitAsync(cancellationToken); }
        int take = Math.Min(buffer.Length, bytes.Length - index);
        if (index < pauseAt) take = Math.Min(take, pauseAt - index);
        bytes.AsMemory(index, take).CopyTo(buffer); index += take; return take;
    }
    public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    public override void Flush() { } public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
    public override void SetLength(long value) => throw new NotSupportedException(); public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
}
internal static class GatewayTests
{
    internal static string Sse(params string[] parts)
    {
        var events = new List<string> { ": comment", "data: " + JsonSerializer.Serialize(new { model = GatewayModelService.AnswerModel,
            choices = new[] { new { index = 0, delta = new { reasoning_content = "synthetic-private-reasoning" }, finish_reason = (string?)null } } }) };
        events.AddRange(parts.Select(part => "data: " + JsonSerializer.Serialize(new { model = GatewayModelService.AnswerModel,
            choices = new[] { new { index = 0, delta = new { content = part }, finish_reason = (string?)null } } })));
        events.Add("data: " + JsonSerializer.Serialize(new { model = GatewayModelService.AnswerModel,
            choices = new[] { new { index = 0, delta = new { }, finish_reason = "stop" } } }));
        events.Add("data: [DONE]");
        return string.Join("\r\n\r\n", events) + "\r\n\r\n";
    }
    internal static HttpResponseMessage Response(string text, bool sse = true)
    {
        var response = new HttpResponseMessage(HttpStatusCode.OK) { Content = new StreamContent(new ChunkedStream(Encoding.UTF8.GetBytes(text))) };
        response.Content.Headers.ContentType = new(sse ? "text/event-stream" : "application/json"); return response;
    }
    private static GatewayModelService Service(HttpClient client, GatewayOptions? options = null) =>
        new(client, options ?? new(new("https://gateway.invalid/ping"), "synthetic-token"));
    public static void Register(List<(string, Func<Task>)> tests)
    {
        tests.Add(("gateway.actual-routes-body-budget-and-split-utf8", async () =>
        {
            using var handler = new FakeHttpMessageHandler((_, _) => Task.FromResult(Response(Sse("完整", "中文🙂", "答案"))));
            using var client = new HttpClient(handler); var service = Service(client); using var evidence = Fixtures.Capture(text: "词语", image: false);
            var streamed = new List<string>(); var result = await service.GenerateAsync(ActionKind.Explain, evidence, streamed.Add, default);
            Check.Equal("完整中文🙂答案", result.Text); Check.Equal(result.Text, streamed.Last()); Check.True(result.Metrics.ReasoningReturned);
            Check.True(!result.Text.Contains("synthetic-private-reasoning"));
            Check.Equal(1, handler.Requests.Count); var sent = handler.Requests.Single(); Check.Equal("/ping/v1/explanation", sent.Path);
            Check.Equal("Bearer synthetic-token", sent.Authorization);
            using var body = JsonDocument.Parse(sent.Body!); var root = body.RootElement;
            Check.Equal(GatewayModelService.AnswerModel, root.GetProperty("model").GetString()); Check.Equal(1600, root.GetProperty("max_tokens").GetInt32());
            Check.Equal("enabled", root.GetProperty("thinking").GetProperty("type").GetString()); Check.Equal("low", root.GetProperty("reasoning_effort").GetString());
            Check.True(root.GetProperty("messages")[0].GetProperty("content").GetString()!.Contains("不要描述箭头"));
        }));
        tests.Add(("gateway-expand-once-argmax-and-image-context", async () =>
        {
            int expansions = 0;
            using var handler = new FakeHttpMessageHandler((sent, _) => Task.FromResult(sent.Path.EndsWith("decision") ? Response("""
                {"model":"jev-1.14","answers":{"acquisition":{"type":"choice","choice":"expand_visual","probabilities":{"use_current":0.2,"expand_visual":0.8}}}}
                """, false) : Response(Sse("解释"))));
            using var client = new HttpClient(handler); var service = Service(client);
            using var evidence = Fixtures.Capture(expand: _ => { expansions++; return Task.FromResult<ImageEvidence?>(Fixtures.Image() with { PointInImage = new(.8, .6) }); });
            var result = await service.GenerateAsync(ActionKind.Explain, evidence, _ => { }, default);
            Check.Equal(1, expansions); Check.Equal(2, handler.Requests.Count); Check.Equal("/ping/v1/decision", handler.Requests[0].Path);
            Check.Equal(new ScreenPoint(.8, .6), result.Context.Image!.PointInImage);
            using var decision = JsonDocument.Parse(handler.Requests[0].Body!); Check.Equal("jev-1.14", decision.RootElement.GetProperty("model").GetString());
            Check.Equal("choice", decision.RootElement.GetProperty("questions").GetProperty("acquisition").GetProperty("type").GetString());
            Check.Equal(0, decision.RootElement.GetProperty("state").GetProperty("evidence").GetProperty("target").GetString()!.Length);
        }));
        tests.Add(("gateway-invalid-decision-keeps-local-without-retry", async () =>
        {
            int expansions = 0;
            using var handler = new FakeHttpMessageHandler((sent, _) => Task.FromResult(sent.Path.EndsWith("decision") ? Response("""
                {"model":"jev-1.14","answers":{"acquisition":{"type":"choice","choice":"expand_visual","probabilities":{"use_current":0.8,"expand_visual":0.2}}}}
                """, false) : Response(Sse("本地图"))));
            using var client = new HttpClient(handler); using var evidence = Fixtures.Capture(expand: _ => { expansions++; return Task.FromResult<ImageEvidence?>(Fixtures.Image()); });
            var result = await Service(client).GenerateAsync(ActionKind.Explain, evidence, _ => { }, default);
            Check.Equal("本地图", result.Text); Check.Equal(0, expansions); Check.Equal(2, handler.Requests.Count);
        }));
        tests.Add(("gateway-permanent-auth-zero-retries", async () =>
        {
            using var handler = new FakeHttpMessageHandler((_, _) => Task.FromResult(new HttpResponseMessage(HttpStatusCode.Forbidden)));
            using var client = new HttpClient(handler); using var evidence = Fixtures.Capture(expand: _ => Task.FromResult<ImageEvidence?>(Fixtures.Image()));
            await Check.ThrowsAsync(() => Service(client).GenerateAsync(ActionKind.Explain, evidence, _ => { }, default));
            Check.Equal(1, handler.Requests.Count); Check.True(handler.Requests[0].Path.EndsWith("decision"));
        }));
        tests.Add(("gateway-http400-zero-retries-and-no-response-body-errors", async () =>
        {
            using var handler = new FakeHttpMessageHandler((_, _) => Task.FromResult(new HttpResponseMessage(HttpStatusCode.BadRequest) { Content = new StringContent("private-captured-content") }));
            using var client = new HttpClient(handler); using var evidence = Fixtures.Capture(text: "selection", image: false);
            try { await Service(client).GenerateAsync(ActionKind.Explain, evidence, _ => { }, default); throw new Exception("Must fail"); }
            catch (GatewayException error) { Check.True(!error.Message.Contains("private-captured-content")); }
            Check.Equal(1, handler.Requests.Count);
        }));
        tests.Add(("gateway-cancellation-stops-body-and-callbacks", async () =>
        {
            using var cancellation = new CancellationTokenSource();
            using var handler = new FakeHttpMessageHandler((_, _) => Task.FromResult(Response(Sse("first", "late"))));
            using var client = new HttpClient(handler); using var evidence = Fixtures.Capture(text: "selection", image: false); int callbacks = 0;
            await Check.ThrowsAsync(() => Service(client).GenerateAsync(ActionKind.Explain, evidence, _ => { callbacks++; cancellation.Cancel(); }, cancellation.Token));
            Check.Equal(1, callbacks); Check.Equal(1, handler.Requests.Count);
        }));
        tests.Add(("gateway-incomplete-stream-not-success", async () =>
        {
            using var handler = new FakeHttpMessageHandler((_, _) => Task.FromResult(Response(Sse("partial").Replace("data: [DONE]\r\n\r\n", ""))));
            using var client = new HttpClient(handler); using var evidence = Fixtures.Capture(text: "selection", image: false);
            await Check.ThrowsAsync(() => Service(client).GenerateAsync(ActionKind.Explain, evidence, _ => { }, default));
        }));
        tests.Add(("gateway-rewrite-translate-followup-disable-thinking", async () =>
        {
            using var handler = new FakeHttpMessageHandler((_, _) => Task.FromResult(Response(Sse("结果")))); using var client = new HttpClient(handler); var service = Service(client);
            using var evidence = Fixtures.Capture(text: "中文内容", image: false);
            await service.GenerateAsync(ActionKind.Translate, evidence, _ => { }, default);
            await service.GenerateAsync(ActionKind.Rewrite, evidence, _ => { }, default);
            await service.FollowupAsync(ActionKind.Explain, new("中文内容", "", null, "", ""), "结果", [new("Q", "A")], "继续", _ => { }, default);
            foreach (var request in handler.Requests)
            {
                using var body = JsonDocument.Parse(request.Body!); Check.Equal("disabled", body.RootElement.GetProperty("thinking").GetProperty("type").GetString());
                Check.True(!body.RootElement.TryGetProperty("reasoning_effort", out _));
            }
            using var translate = JsonDocument.Parse(handler.Requests[0].Body!); Check.Equal(240, translate.RootElement.GetProperty("max_tokens").GetInt32());
            Check.True(translate.RootElement.GetProperty("messages")[0].GetProperty("content").GetString()!.Contains("译成英语"));
        }));
        tests.Add(("gateway-saved-description-budget-and-json", async () =>
        {
            using var handler = new FakeHttpMessageHandler((_, _) => Task.FromResult(Response(Sse("{\"text\":\"\",\"tags\":[\" 工作 \",\"工作\"]}"))));
            using var client = new HttpClient(handler); var result = await Service(client).DescribeSavedAsync(new("原文", "", null, "", ""), ["工作"], default);
            Check.Equal("原文", result.Text); Check.Sequence(new[] { "工作" }, result.Tags);
            using var body = JsonDocument.Parse(handler.Requests.Single().Body!); Check.Equal(200, body.RootElement.GetProperty("max_tokens").GetInt32());
        }));
        tests.Add(("gateway-prewarm-no-token-no-content-throttled", async () =>
        {
            using var handler = new FakeHttpMessageHandler((_, _) => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)));
            using var client = new HttpClient(handler); var service = Service(client); await service.PrewarmAsync(default); await service.PrewarmAsync(default);
            Check.Equal(1, handler.Requests.Count); Check.Equal(HttpMethod.Get, handler.Requests[0].Method); Check.Equal("/ping/health", handler.Requests[0].Path);
            Check.Equal<string?>(null, handler.Requests[0].Authorization); Check.Equal<string?>(null, handler.Requests[0].Body);
        }));
        tests.Add(("gateway-selected-explain-local-context-body-without-jev", async () =>
        {
            using var handler = new FakeHttpMessageHandler((_, _) => Task.FromResult(Response(Sse("完整回答"))));
            using var client = new HttpClient(handler); var service = Service(client);
            foreach (var action in new[] { ActionKind.Explain, ActionKind.Translate, ActionKind.Rewrite, ActionKind.Save })
            {
                int supplements = 0;
                using var evidence = Fixtures.Capture(text: "明确选中文字", image: false, expand: _ =>
                { supplements++; return Task.FromResult<ImageEvidence?>(Fixtures.Image()); });
                var context = action == ActionKind.Save ? await service.PrepareSaveAsync(evidence, default) :
                    (await service.GenerateAsync(action, evidence, _ => { }, default)).Context;
                Check.Equal(action == ActionKind.Explain ? 1 : 0, supplements);
                Check.Equal("明确选中文字", context.SelectedText); Check.Equal(action == ActionKind.Explain, context.Image is not null);
            }
            Check.Equal(3, handler.Requests.Count); Check.True(handler.Requests.All(x => x.Path == "/ping/v1/explanation"));
            using var body = JsonDocument.Parse(handler.Requests[0].Body!); var content = body.RootElement.GetProperty("messages")[1].GetProperty("content");
            Check.Equal(2, content.GetArrayLength()); Check.Equal("image_url", content[1].GetProperty("type").GetString());
            using var input = JsonDocument.Parse(content[0].GetProperty("text").GetString()!);
            Check.True(input.RootElement.GetProperty("capture_metadata").GetProperty("has_selection").GetBoolean());
            Check.Equal("明确选中文字", input.RootElement.GetProperty("evidence").GetProperty("target").GetString());
            Check.Equal(.25, input.RootElement.GetProperty("evidence").GetProperty("point_in_image").GetProperty("x").GetDouble());
            Check.Equal("top_left_normalized", input.RootElement.GetProperty("evidence").GetProperty("point_in_image").GetProperty("origin").GetString());
        }));
        tests.Add(("gateway-native-frame-released-before-held-answer-stream", async () =>
        {
            int released = 0;
            var payload = Sse("完整", "流式正文🙂"); int first = payload.IndexOf("data: ", StringComparison.Ordinal);
            int second = payload.IndexOf("data: ", first + 1, StringComparison.Ordinal);
            int pauseAt = Encoding.UTF8.GetByteCount(payload[..(payload.IndexOf("\r\n\r\n", second, StringComparison.Ordinal) + 4)]);
            using var held = new HeldAnswerStream(Encoding.UTF8.GetBytes(payload), pauseAt);
            using var handler = new FakeHttpMessageHandler((_, _) =>
            {
                var response = new HttpResponseMessage(HttpStatusCode.OK) { Content = new StreamContent(held) };
                response.Content.Headers.ContentType = new("text/event-stream"); return Task.FromResult(response);
            });
            using var client = new HttpClient(handler); var service = Service(client);
            using var evidence = Fixtures.Capture(release: () => Interlocked.Increment(ref released));
            var streamed = new List<string>(); var task = service.GenerateAsync(ActionKind.Explain, evidence, streamed.Add, default);
            await held.Paused.Task; Check.Equal(1, released); Check.True(!task.IsCompleted); Check.Equal("完整", streamed.Last());
            await Check.ThrowsAsync(() => evidence.ExpandAsync(default));
            held.Continue.SetResult(); var result = await task;
            Check.Equal("完整流式正文🙂", result.Text); Check.Equal(result.Text, streamed.Last()); Check.Equal(1, released);
            evidence.Dispose(); Check.Equal(1, released);
        }));
    }
}
