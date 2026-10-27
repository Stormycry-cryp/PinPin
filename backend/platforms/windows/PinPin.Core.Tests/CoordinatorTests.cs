using System.Collections.Concurrent;
using PinPin.Core;

namespace PinPin.Core.Tests;

internal sealed class FakePresentation : IPinPinPresentation
{
    public PresentationCallbacks Callbacks = new();
    public readonly ConcurrentDictionary<Guid, ResultState> Results = new();
    public readonly ConcurrentQueue<ResultState> History = new();
    public IReadOnlyList<AssetRecord> Assets = Array.Empty<AssetRecord>();
    public WheelSnapshot? Wheel;
    public Action<ResultState>? OnShow;
    public WheelSettings Settings = WheelSettings.Default;
    public int SettingsShows;
    public Action? OnSettings;
    public void SetCallbacks(PresentationCallbacks callbacks) => Callbacks = callbacks;
    public void UpdateWheelSettings(WheelSettings settings) => Settings = settings;
    public void ShowWheel(WheelSnapshot snapshot) => Wheel = snapshot;
    public void MoveWheel(ScreenPoint point) { }
    public void HideWheel() => Wheel = null;
    public void ShowResult(ResultState state) { Results[state.Id] = state; History.Enqueue(state); OnShow?.Invoke(state); }
    public void RemoveResult(Guid id) => Results.TryRemove(id, out _);
    public void ClearResults() => Results.Clear();
    public void UpdateAssets(IReadOnlyList<AssetRecord> assets) => Assets = assets;
    public void ShowAssets() { }
    public void ShowSettings() { Interlocked.Increment(ref SettingsShows); OnSettings?.Invoke(); }
    public void Dispose() { }
}
internal sealed class FakeCapture : ICaptureService
{
    public int Calls;
    public Func<TargetAnchor, CancellationToken, Task<CapturedEvidence>> Capture = (anchor, _) => Task.FromResult(Fixtures.Capture(anchor, "target", false));
    public Task<CapturedEvidence> CaptureAsync(TargetAnchor anchor, CancellationToken token) { Interlocked.Increment(ref Calls); return Capture(anchor, token); }
}
internal sealed class FakePixel : IPixelSampler
{
    public Func<TargetAnchor, CancellationToken, Task<PixelColor>> Sample = (_, _) => Task.FromResult(new PixelColor(17, 34, 51, "test"));
    public Task<PixelColor> SampleAsync(TargetAnchor anchor, CancellationToken token) => Sample(anchor, token);
}
internal sealed record FollowupCall(ActionKind Action, PromptContext Context, string Previous, IReadOnlyList<FollowupExchange> Earlier,
    string Question, Action<string> OnText, CancellationToken Token);
internal sealed class FakeModels : IModelService
{
    public int Generations; public int Prewarms; public int Descriptions; public int Preparations;
    public Func<ActionKind, CapturedEvidence, Action<string>, CancellationToken, Task<GenerationResult>> Generate = (_, evidence, onText, _) =>
    { onText("first"); onText("first+last"); return Task.FromResult(new GenerationResult("first+last", Fixtures.Context(evidence), new(1, 2))); };
    public Func<FollowupCall, Task<GenerationResult>> Followup = call =>
    { call.OnText(call.Question + ":answer"); return Task.FromResult(new GenerationResult(call.Question + ":answer", call.Context, new(1, 2))); };
    public Func<CapturedEvidence, CancellationToken, Task<PromptContext>> Prepare = (evidence, _) => Task.FromResult(Fixtures.Context(evidence));
    public Func<PromptContext, IReadOnlyList<string>, CancellationToken, Task<SavedDescription>> Describe = (context, _, _) => Task.FromResult(new SavedDescription("description", ["tag"]));
    public Task<GenerationResult> GenerateAsync(ActionKind action, CapturedEvidence evidence, Action<string> onText, CancellationToken token)
    { Interlocked.Increment(ref Generations); return Generate(action, evidence, onText, token); }
    public Task<GenerationResult> FollowupAsync(ActionKind action, PromptContext context, string previous, IReadOnlyList<FollowupExchange> earlier,
        string question, Action<string> onText, CancellationToken token) => Followup(new(action, context, previous, earlier, question, onText, token));
    public Task<PromptContext> PrepareSaveAsync(CapturedEvidence evidence, CancellationToken token) { Interlocked.Increment(ref Preparations); return Prepare(evidence, token); }
    public Task<SavedDescription> DescribeSavedAsync(PromptContext context, IReadOnlyList<string> existingTags, CancellationToken token)
    { Interlocked.Increment(ref Descriptions); return Describe(context, existingTags, token); }
    public Task PrewarmAsync(CancellationToken token) { Interlocked.Increment(ref Prewarms); return Task.CompletedTask; }
}
internal sealed class ControlledAssets(IAssetStore inner) : IAssetStore
{
    public bool HoldColor; public bool FailColor;
    public bool HoldEdits; public bool HoldOriginal;
    public int EditCalls;
    public CancellationToken EditToken;
    public readonly TaskCompletionSource ColorEntered = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public readonly TaskCompletionSource ReleaseColor = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public readonly TaskCompletionSource EditEntered = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public readonly TaskCompletionSource ReleaseEdit = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public readonly TaskCompletionSource OriginalEntered = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public readonly TaskCompletionSource ReleaseOriginal = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public Task<IReadOnlyList<AssetRecord>> LoadAsync(CancellationToken cancellationToken = default) => inner.LoadAsync(cancellationToken);
    public async Task<AssetRecord> SaveOriginalAsync(Guid id, PromptContext context, CancellationToken token)
    {
        OriginalEntered.TrySetResult(); if (HoldOriginal) await ReleaseOriginal.Task.WaitAsync(token);
        return await inner.SaveOriginalAsync(id, context, token);
    }
    public async Task<AssetRecord> SaveColorAsync(Guid id, PixelColor color, string app, string window, CancellationToken token)
    {
        ColorEntered.TrySetResult(); if (HoldColor) await ReleaseColor.Task;
        if (FailColor) throw new IOException("synthetic save failure");
        return await inner.SaveColorAsync(id, color, app, window, token);
    }
    public Task<AssetRecord?> EnrichAsync(Guid id, SavedDescription description, CancellationToken token) => inner.EnrichAsync(id, description, token);
    public async Task ApplyAsync(AssetEdit edit, CancellationToken cancellationToken = default)
    {
        Interlocked.Increment(ref EditCalls); EditToken = cancellationToken; EditEntered.TrySetResult();
        if (HoldEdits) await ReleaseEdit.Task.WaitAsync(cancellationToken);
        await inner.ApplyAsync(edit, cancellationToken);
    }
}
internal sealed class ControlledSettings(IWheelSettingsStore inner) : IWheelSettingsStore
{
    public Func<CancellationToken, Task<WheelSettings>>? Load;
    public bool Hold; public bool Fail;
    public int Saves;
    public CancellationToken SaveToken;
    public readonly TaskCompletionSource Entered = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public readonly TaskCompletionSource Release = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public Task<WheelSettings> LoadAsync(CancellationToken token = default) => Load?.Invoke(token) ?? inner.LoadAsync(token);
    public async Task<bool> SaveAsync(WheelSettings settings, CancellationToken token = default)
    {
        Interlocked.Increment(ref Saves); SaveToken = token; Entered.TrySetResult();
        if (Hold) await Release.Task.WaitAsync(token);
        if (Fail) return false;
        return await inner.SaveAsync(settings, token);
    }
}
internal sealed class FakeInput : IInputSource
{
    public bool TriggerEnabled;
    public readonly List<bool> TriggerUpdates = [];
    public event Action<GestureEvent>? Gesture { add { } remove { } }
    public IReadOnlyList<ScreenRect> Screens => [];
    public void Start() { }
    public void SetWheelTriggerEnabled(bool enabled) { TriggerEnabled = enabled; TriggerUpdates.Add(enabled); }
    public void Dispose() { }
}
internal sealed class Rig : IDisposable
{
    public readonly Temp Temp = new();
    public readonly FakePresentation Presentation = new(); public readonly FakeCapture Capture = new();
    public readonly FakePixel Pixel = new(); public readonly FakeModels Models = new();
    public readonly JsonAssetStore Store; public readonly ControlledAssets Assets; public readonly ActionCoordinator Coordinator;
    public readonly ControlledSettings Settings;
    public readonly FakeInput Input = new();
    public Rig()
    {
        Store = new(Temp.Path); Assets = new(Store);
        Settings = new(new JsonWheelSettingsStore(Path.Combine(Temp.Path, "wheel.json")));
        Coordinator = new(Presentation, Capture, Pixel, Models, Assets, Settings, () => [new(0, 0, 1000, 1000)], input: Input);
    }
    public void Dispose() { Coordinator.Dispose(); Temp.Dispose(); }
}
internal static class CoordinatorTests
{
    public static void Register(List<(string, Func<Task>)> tests)
    {
        tests.Add(("coordinator-settings-shortcut-does-not-prepare-evidence", async () =>
        {
            using var rig = new Rig();
            rig.Coordinator.Receive(new(GesturePhase.OpenSettings, null, new(300, 400)));
            await rig.Coordinator.DrainAsync();
            Check.Equal(1, rig.Presentation.SettingsShows); Check.True(rig.Presentation.Wheel is null);
            Check.Equal(0, rig.Capture.Calls); Check.Equal(0, rig.Models.Prewarms); Check.Equal(0, rig.Models.Generations);
            Check.Equal(0, rig.Coordinator.ActiveResultCount);
        }));
        tests.Add(("coordinator-settings-shortcut-abandons-wheel-preparation", async () =>
        {
            using var rig = new Rig(); var anchor = Fixtures.Anchor(); int released = 0;
            var captured = new TaskCompletionSource<CapturedEvidence>(TaskCreationOptions.RunContinuationsAsynchronously);
            var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            CancellationToken captureToken = default;
            rig.Capture.Capture = (_, token) => { captureToken = token; entered.SetResult(); return captured.Task; };
            rig.Coordinator.Receive(new(GesturePhase.Began, anchor, anchor.Point)); await entered.Task;
            rig.Presentation.OnSettings = () => Check.True(captureToken.IsCancellationRequested && rig.Presentation.Wheel is null);
            rig.Coordinator.Receive(new(GesturePhase.OpenSettings, null, anchor.Point));
            rig.Coordinator.Receive(new(GesturePhase.Released, null, new(300, 500)));
            captured.SetResult(Fixtures.Capture(anchor, release: () => Interlocked.Increment(ref released)));
            await rig.Coordinator.DrainAsync();
            Check.Equal(1, released); Check.Equal(1, rig.Presentation.SettingsShows);
            Check.Equal(0, rig.Models.Generations); Check.Equal(0, rig.Coordinator.ActiveResultCount);
        }));
        tests.Add(("coordinator-settings-disabled-trigger-preserves-completed-and-running-results", async () =>
        {
            using var rig = new Rig(); var completed = Fixtures.Anchor();
            await rig.Coordinator.ExecuteAsync(ActionKind.Explain, completed);
            var before = rig.Presentation.Results[completed.Id];
            var done = new TaskCompletionSource<GenerationResult>(TaskCreationOptions.RunContinuationsAsynchronously);
            var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            CancellationToken activeToken = default; PromptContext? context = null;
            rig.Models.Generate = (_, evidence, _, token) =>
            { activeToken = token; context = Fixtures.Context(evidence); entered.SetResult(); return done.Task; };
            var active = Fixtures.Anchor(); var running = rig.Coordinator.ExecuteAsync(ActionKind.Rewrite, active); await entered.Task;
            Check.True(await rig.Coordinator.ChangeWheelSettingsAsync(rig.Presentation.Settings with { TriggerEnabled = false }));
            Check.True(!rig.Input.TriggerEnabled);
            rig.Coordinator.Receive(new(GesturePhase.ClearAll, completed, completed.Point));
            rig.Presentation.Callbacks.SettingsRequested!();
            Check.Equal(1, rig.Presentation.SettingsShows); Check.True(!activeToken.IsCancellationRequested);
            Check.Equal(before, rig.Presentation.Results[completed.Id]); Check.Equal(2, rig.Coordinator.ActiveResultCount);
            Check.True(await rig.Coordinator.ChangeWheelSettingsAsync(rig.Presentation.Settings with { TriggerEnabled = true }));
            rig.Coordinator.Receive(new(GesturePhase.ClearAll, completed, completed.Point));
            Check.Equal(before, rig.Presentation.Results[completed.Id]); Check.True(!activeToken.IsCancellationRequested);
            done.SetResult(new("continued after settings", context!, new(1, 2))); await running;
            Check.Equal("continued after settings", rig.Presentation.Results[active.Id].Text);
            Check.True(rig.Presentation.Results[active.Id].IsComplete); Check.Equal(2, rig.Models.Generations);
        }));
        tests.Add(("coordinator-disabled-trigger-load-keeps-settings-shortcut", async () =>
        {
            using var rig = new Rig();
            var persisted = new JsonWheelSettingsStore(Path.Combine(rig.Temp.Path, "wheel.json"));
            Check.True(await persisted.SaveAsync(WheelSettings.Default with { TriggerEnabled = false }));
            await rig.Coordinator.InitializeAsync();
            Check.True(!rig.Input.TriggerEnabled); Check.True(!rig.Presentation.Settings.TriggerEnabled);
            var anchor = Fixtures.Anchor(); rig.Coordinator.Receive(new(GesturePhase.Began, anchor, anchor.Point));
            rig.Coordinator.Receive(new(GesturePhase.Released, anchor, new(300, 500)));
            rig.Coordinator.Receive(new(GesturePhase.OpenSettings, null, anchor.Point));
            await rig.Coordinator.DrainAsync();
            Check.Equal(1, rig.Presentation.SettingsShows); Check.True(rig.Presentation.Wheel is null);
            Check.Equal(0, rig.Capture.Calls); Check.Equal(0, rig.Models.Prewarms); Check.Equal(0, rig.Models.Generations);
        }));
        tests.Add(("coordinator-pending-load-keeps-input-unarmed-and-settings-available", async () =>
        {
            using var rig = new Rig();
            var loaded = new TaskCompletionSource<WheelSettings>(TaskCreationOptions.RunContinuationsAsynchronously);
            rig.Settings.Load = _ => loaded.Task;
            var initializing = rig.Coordinator.InitializeAsync();
            Check.True(!initializing.IsCompleted && !rig.Input.TriggerEnabled); Check.Equal(0, rig.Input.TriggerUpdates.Count);
            rig.Coordinator.Receive(new(GesturePhase.OpenSettings, null, default));
            Check.Equal(1, rig.Presentation.SettingsShows); Check.Equal(0, rig.Capture.Calls); Check.Equal(0, rig.Models.Prewarms);
            loaded.SetResult(WheelSettings.Default with { TriggerEnabled = false }); await initializing;
            Check.Sequence(new[] { false }, rig.Input.TriggerUpdates); Check.True(!rig.Input.TriggerEnabled);
        }));
        tests.Add(("coordinator-disable-trigger-immediate-even-when-save-fails", async () =>
        {
            using var rig = new Rig(); var anchor = Fixtures.Anchor();
            var file = Path.Combine(rig.Temp.Path, "wheel.json"); var persisted = new JsonWheelSettingsStore(file);
            Check.True(await persisted.SaveAsync(WheelSettings.Default)); var original = await File.ReadAllBytesAsync(file);
            await rig.Coordinator.InitializeAsync();
            var captured = new TaskCompletionSource<CapturedEvidence>(TaskCreationOptions.RunContinuationsAsynchronously);
            var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            CancellationToken captureToken = default; int released = 0;
            rig.Capture.Capture = (_, token) => { captureToken = token; entered.SetResult(); return captured.Task; };
            rig.Coordinator.Receive(new(GesturePhase.Began, anchor, anchor.Point)); await entered.Task;
            rig.Settings.Hold = true; rig.Settings.Fail = true;
            var saving = rig.Coordinator.ChangeWheelSettingsAsync(rig.Presentation.Settings with { TriggerEnabled = false });
            await rig.Settings.Entered.Task;
            Check.True(!saving.IsCompleted); Check.True(!rig.Input.TriggerEnabled && !rig.Presentation.Settings.TriggerEnabled);
            Check.True(captureToken.IsCancellationRequested && rig.Presentation.Wheel is null);
            rig.Coordinator.Receive(new(GesturePhase.Released, anchor, new(300, 500)));
            rig.Coordinator.Receive(new(GesturePhase.ClearAll, anchor, anchor.Point));
            rig.Coordinator.Receive(new(GesturePhase.Began, Fixtures.Anchor(), anchor.Point));
            captured.SetResult(Fixtures.Capture(anchor, release: () => Interlocked.Increment(ref released)));
            rig.Settings.Release.SetResult(); Check.True(!await saving); await rig.Coordinator.DrainAsync();
            Check.Equal(1, released); Check.Equal(1, rig.Capture.Calls); Check.Equal(0, rig.Models.Generations);
            Check.True(!rig.Input.TriggerEnabled); Check.Sequence(original, await File.ReadAllBytesAsync(file));
            Check.True((await new JsonWheelSettingsStore(file).LoadAsync()).TriggerEnabled);
        }));
        tests.Add(("coordinator-wheel-prewarm-does-not-send-content", async () =>
        {
            using var rig = new Rig(); var anchor = Fixtures.Anchor();
            rig.Coordinator.Receive(new(GesturePhase.Began, anchor, anchor.Point));
            await Check.Eventually(() => rig.Capture.Calls == 1); Check.Equal(0, rig.Models.Generations); Check.Equal(1, rig.Models.Prewarms);
            var frozen = rig.Presentation.Wheel;
            rig.Coordinator.Receive(new(GesturePhase.Released, null, new(300, 500))); await rig.Coordinator.DrainAsync();
            Check.Equal(1, rig.Models.Generations); Check.Equal("first+last", rig.Presentation.Results[anchor.Id].Text);
            Check.True(rig.Presentation.Results[anchor.Id].IsComplete); Check.True(ReferenceEquals(frozen, rig.Presentation.Wheel));
            rig.Coordinator.Receive(new(GesturePhase.Released, null, new(700, 500))); await rig.Coordinator.DrainAsync();
            Check.Equal(1, rig.Models.Generations); Check.Equal(1, rig.Capture.Calls); Check.Equal(1, rig.Models.Prewarms);
            rig.Coordinator.Receive(new(GesturePhase.ModifierReleased, null, new(700, 500)));
            Check.True(rig.Presentation.Wheel is null);
            rig.Coordinator.Receive(new(GesturePhase.Released, null, new(300, 500))); await rig.Coordinator.DrainAsync();
            Check.Equal(1, rig.Models.Generations);
        }));
        tests.Add(("coordinator-left-release-before-alt-keeps-pending-capture-and-result", async () =>
        {
            using var rig = new Rig(); var anchor = Fixtures.Anchor(); int released = 0;
            var captured = new TaskCompletionSource<CapturedEvidence>(TaskCreationOptions.RunContinuationsAsynchronously);
            var captureEntered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            var modelEntered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            var completed = new TaskCompletionSource<GenerationResult>(TaskCreationOptions.RunContinuationsAsynchronously);
            CancellationToken captureToken = default, modelToken = default; PromptContext? context = null;
            rig.Capture.Capture = (_, token) => { captureToken = token; captureEntered.SetResult(); return captured.Task; };
            rig.Models.Generate = (action, evidence, onText, token) =>
            {
                Check.Equal(ActionKind.Explain, action); modelToken = token; context = Fixtures.Context(evidence);
                onText("first"); modelEntered.SetResult(); return completed.Task;
            };
            rig.Coordinator.Receive(new(GesturePhase.Began, anchor, anchor.Point));
            await captureEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));
            // 原生队列可能合并全部移动事件；松左键事件自身携带最终物理坐标。
            rig.Coordinator.Receive(new(GesturePhase.Released, anchor, new(300, 500)));
            Check.Equal(1, rig.Coordinator.ActiveResultCount); Check.True(rig.Presentation.Results[anchor.Id].IsLoading);
            Check.Equal(ActionKind.Explain, rig.Presentation.Results[anchor.Id].Action);
            rig.Coordinator.Receive(new(GesturePhase.ModifierReleased, anchor, anchor.Point));
            Check.True(rig.Presentation.Wheel is null); Check.True(!captureToken.IsCancellationRequested);
            captured.SetResult(Fixtures.Capture(anchor, release: () => Interlocked.Increment(ref released)));
            await modelEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));
            Check.True(!modelToken.IsCancellationRequested); Check.Equal(1, rig.Capture.Calls); Check.Equal(1, rig.Models.Generations);
            Check.Equal("first", rig.Presentation.Results[anchor.Id].Text);
            completed.SetResult(new("complete", context!, new(1, 2))); await rig.Coordinator.DrainAsync();
            Check.Equal("complete", rig.Presentation.Results[anchor.Id].Text);
            Check.True(rig.Presentation.Results[anchor.Id].IsComplete); Check.Equal(1, released);
        }));
        tests.Add(("coordinator-center-empty-and-modifier-release-cancel", async () =>
        {
            using var rig = new Rig();
            foreach (var modifierRelease in new[] { false, true })
            {
                var anchor = Fixtures.Anchor(); rig.Coordinator.Receive(new(GesturePhase.Began, anchor, anchor.Point));
                rig.Coordinator.Receive(new(modifierRelease ? GesturePhase.ModifierReleased : GesturePhase.Released, null, anchor.Point));
                rig.Coordinator.Receive(new(GesturePhase.Released, null, new(300, 500)));
            }
            await rig.Coordinator.DrainAsync(); Check.Equal(0, rig.Models.Generations); Check.Equal(0, rig.Coordinator.ActiveResultCount);
        }));
        tests.Add(("coordinator-center-or-empty-release-consumes-without-hiding", async () =>
        {
            foreach (var emptySlot in new[] { false, true })
            {
                using var rig = new Rig(); var anchor = Fixtures.Anchor();
                if (emptySlot) Check.True(await rig.Coordinator.ChangeWheelSettingsAsync(new([null], [])));
                rig.Coordinator.Receive(new(GesturePhase.Began, anchor, anchor.Point));
                var frozen = rig.Presentation.Wheel;
                rig.Coordinator.Receive(new(GesturePhase.Released, null, emptySlot ? new(700, 500) : anchor.Point));
                rig.Coordinator.Receive(new(GesturePhase.Released, null, new(300, 500))); await rig.Coordinator.DrainAsync();
                Check.True(ReferenceEquals(frozen, rig.Presentation.Wheel));
                Check.Equal(0, rig.Models.Generations); Check.Equal(0, rig.Coordinator.ActiveResultCount);
                rig.Coordinator.Receive(new(GesturePhase.ModifierReleased, null, anchor.Point));
                Check.True(rig.Presentation.Wheel is null);
            }
        }));
        tests.Add(("coordinator-new-begin-replaces-consumed-wheel-and-clear-closes", async () =>
        {
            using var rig = new Rig(); var first = Fixtures.Anchor();
            rig.Coordinator.Receive(new(GesturePhase.Began, first, first.Point));
            var frozen = rig.Presentation.Wheel;
            rig.Coordinator.Receive(new(GesturePhase.Released, null, new(300, 500))); await rig.Coordinator.DrainAsync();
            Check.True(ReferenceEquals(frozen, rig.Presentation.Wheel));
            var next = Fixtures.Anchor(x: 600, y: 600); rig.Coordinator.Receive(new(GesturePhase.Began, next, next.Point));
            Check.Equal(next.Id, rig.Presentation.Wheel!.Anchor.Id); Check.Equal(next.Point, rig.Presentation.Wheel.Anchor.Point);
            Check.Equal(first.Point, frozen!.Anchor.Point);
            rig.Coordinator.Receive(new(GesturePhase.Released, null, next.Point)); await rig.Coordinator.DrainAsync();
            Check.Equal(1, rig.Models.Generations);
            rig.Coordinator.Clear(); Check.True(rig.Presentation.Wheel is null); Check.Equal(0, rig.Coordinator.ActiveResultCount);
            rig.Coordinator.Receive(new(GesturePhase.Released, null, new(300, 500))); await rig.Coordinator.DrainAsync();
            Check.Equal(1, rig.Models.Generations);
        }));
        tests.Add(("coordinator-native-clear-retains-wheel-until-alt-release", async () =>
        {
            foreach (var executed in new[] { false, true })
            {
                using var rig = new Rig(); var anchor = Fixtures.Anchor(); int released = 0;
                var capture = new TaskCompletionSource<CapturedEvidence>(TaskCreationOptions.RunContinuationsAsynchronously);
                rig.Capture.Capture = (_, _) => capture.Task;
                rig.Coordinator.Receive(new(GesturePhase.Began, anchor, anchor.Point));
                await Check.Eventually(() => rig.Capture.Calls == 1); var frozen = rig.Presentation.Wheel;
                if (executed)
                {
                    capture.SetResult(Fixtures.Capture(anchor, release: () => Interlocked.Increment(ref released)));
                    rig.Coordinator.Receive(new(GesturePhase.Released, null, new(300, 500))); await rig.Coordinator.DrainAsync();
                    Check.Equal(1, rig.Presentation.Results.Count);
                }
                rig.Coordinator.Receive(new(GesturePhase.ClearAll, null, anchor.Point));
                Check.True(ReferenceEquals(frozen, rig.Presentation.Wheel)); Check.Equal(0, rig.Presentation.Results.Count);
                rig.Coordinator.Receive(new(GesturePhase.Released, null, new(300, 500)));
                if (!executed) capture.SetResult(Fixtures.Capture(anchor, release: () => Interlocked.Increment(ref released)));
                await rig.Coordinator.DrainAsync();
                Check.Equal(executed ? 1 : 0, rig.Models.Generations); Check.Equal(1, rig.Capture.Calls); Check.Equal(1, released);
                Check.True(ReferenceEquals(frozen, rig.Presentation.Wheel)); Check.Equal(0, rig.Coordinator.ActiveResultCount);
                rig.Coordinator.Receive(new(GesturePhase.ModifierReleased, null, anchor.Point)); Check.True(rig.Presentation.Wheel is null);
            }
        }));
        tests.Add(("coordinator-settings-preview-applies-before-save-and-survives-failure", async () =>
        {
            using var rig = new Rig(); var file = Path.Combine(rig.Temp.Path, "wheel.json");
            var persisted = new JsonWheelSettingsStore(file); Check.True(await persisted.SaveAsync(WheelSettings.Default));
            var oldBytes = await File.ReadAllBytesAsync(file); await rig.Coordinator.InitializeAsync();
            rig.Settings.Hold = true; rig.Settings.Fail = true;
            var preview = new WheelSettings([ActionKind.PickColor, ActionKind.Save, null, ActionKind.Explain, ActionKind.Rewrite],
                new() { [ActionKind.PickColor] = new(12, 34, 56) });
            var saving = rig.Coordinator.ChangeWheelSettingsAsync(preview); await rig.Settings.Entered.Task;
            Check.True(!saving.IsCompleted); Check.Sequence(preview.Slots, rig.Presentation.Settings.Slots);
            foreach (var afterFailure in new[] { false, true })
            {
                if (afterFailure) { rig.Settings.Release.SetResult(); Check.True(!await saving); }
                var anchor = Fixtures.Anchor(); rig.Coordinator.Receive(new(GesturePhase.Began, anchor, anchor.Point));
                Check.Sequence(preview.Slots, rig.Presentation.Wheel!.Settings.Slots);
                Check.Equal(new FeatureColor(12, 34, 56), rig.Presentation.Wheel.Settings.Colors[ActionKind.PickColor]);
                rig.Coordinator.Receive(new(GesturePhase.ModifierReleased, null, anchor.Point));
            }
            await rig.Coordinator.DrainAsync(); Check.Sequence(oldBytes, await File.ReadAllBytesAsync(file));
            var restarted = await new JsonWheelSettingsStore(file).LoadAsync(); Check.Sequence(WheelSettings.Default.Slots, restarted.Slots);
            Check.Equal(0, restarted.Colors.Count);
            Check.True(!await rig.Coordinator.ChangeWheelSettingsAsync(new([], [])));
            Check.Sequence(preview.Slots, rig.Presentation.Settings.Slots);
        }));
        tests.Add(("coordinator-id-isolation-out-of-order-and-full-stream", async () =>
        {
            using var rig = new Rig(); var calls = new ConcurrentDictionary<Guid, (TaskCompletionSource<GenerationResult> Finish, Action<string> Stream, PromptContext Context)>();
            rig.Models.Generate = (_, evidence, stream, _) =>
            { var done = new TaskCompletionSource<GenerationResult>(TaskCreationOptions.RunContinuationsAsynchronously); calls[evidence.Anchor.Id] = (done, stream, Fixtures.Context(evidence)); return done.Task; };
            var a = Fixtures.Anchor(); var b = Fixtures.Anchor(); var ta = rig.Coordinator.ExecuteAsync(ActionKind.Explain, a); var tb = rig.Coordinator.ExecuteAsync(ActionKind.Rewrite, b);
            await Check.Eventually(() => calls.Count == 2);
            calls[b.Id].Stream("B first"); calls[b.Id].Finish.SetResult(new("B complete", calls[b.Id].Context, new(1, 2))); await tb;
            Check.Equal("B complete", rig.Presentation.Results[b.Id].Text); Check.True(rig.Presentation.Results[a.Id].IsLoading);
            var full = string.Concat(Enumerable.Repeat("full正文", 1000)); calls[a.Id].Stream(full); calls[a.Id].Finish.SetResult(new(full, calls[a.Id].Context, new(1, 2))); await ta;
            Check.Equal(full, rig.Presentation.Results[a.Id].Text); Check.Equal("B complete", rig.Presentation.Results[b.Id].Text);
        }));
        tests.Add(("coordinator-close-late-generation-disposes-evidence", async () =>
        {
            using var rig = new Rig(); var anchor = Fixtures.Anchor(); int released = 0;
            var done = new TaskCompletionSource<GenerationResult>(TaskCreationOptions.RunContinuationsAsynchronously); Action<string>? stream = null; PromptContext? context = null;
            rig.Capture.Capture = (a, _) => Task.FromResult(Fixtures.Capture(a, "target", false, release: () => Interlocked.Increment(ref released)));
            rig.Models.Generate = (_, evidence, callback, _) => { stream = callback; context = Fixtures.Context(evidence); return done.Task; };
            var task = rig.Coordinator.ExecuteAsync(ActionKind.Explain, anchor); await Check.Eventually(() => stream is not null);
            rig.Coordinator.Close(anchor.Id); stream!("late"); done.SetResult(new("late complete", context!, new(1, 2))); await task;
            Check.True(!rig.Presentation.Results.ContainsKey(anchor.Id)); Check.Equal(0, rig.Coordinator.ActiveResultCount); Check.Equal(1, released);
        }));
        tests.Add(("coordinator-save-original-before-description-and-tags", async () =>
        {
            using var rig = new Rig(); var anchor = Fixtures.Anchor(); rig.Capture.Capture = (a, _) => Task.FromResult(Fixtures.Capture(a));
            var describe = new TaskCompletionSource<SavedDescription>(TaskCreationOptions.RunContinuationsAsynchronously);
            rig.Models.Describe = async (_, _, _) =>
            {
                var original = (await rig.Store.LoadAsync()).Single(); Check.True(File.Exists(original.ImagePath)); Check.Equal(0, original.Tags.Length);
                Check.Sequence(Fixtures.Image().UnmarkedPng, await File.ReadAllBytesAsync(original.ImagePath!));
                return await describe.Task;
            };
            var task = rig.Coordinator.ExecuteAsync(ActionKind.Save, anchor); await Check.Eventually(() => rig.Models.Descriptions == 1);
            Check.True(rig.Presentation.Results[anchor.Id].IsComplete); Check.Equal(0, rig.Presentation.Results[anchor.Id].Saved!.Tags.Length);
            describe.SetResult(new("准确说明", ["topic"])); await task;
            Check.Equal("准确说明", rig.Presentation.Results[anchor.Id].Saved!.Text); Check.Sequence(new[] { "topic" }, rig.Presentation.Results[anchor.Id].Saved!.Tags);
            Check.Equal(1, rig.Models.Preparations); Check.Equal(0, rig.Models.Generations);
        }));
        tests.Add(("coordinator-color-visible-before-save-close-and-clear-survive", async () =>
        {
            foreach (var clear in new[] { false, true })
            {
                using var rig = new Rig(); rig.Assets.HoldColor = true; var anchor = Fixtures.Anchor();
                await rig.Coordinator.ExecuteAsync(ActionKind.PickColor, anchor); await rig.Assets.ColorEntered.Task;
                var state = rig.Presentation.Results[anchor.Id]; Check.Equal("#112233", state.Color!.Hex); Check.True(state.IsComplete);
                Check.Equal(PersistenceState.Saving, state.ColorPersistence!.Value); Check.Equal(0, (await rig.Store.LoadAsync()).Count);
                if (clear) rig.Coordinator.Clear(); else rig.Coordinator.Close(anchor.Id);
                rig.Assets.ReleaseColor.SetResult(); await rig.Coordinator.DrainAsync();
                Check.Equal(1, (await new JsonAssetStore(rig.Temp.Path).LoadAsync()).Count); Check.Equal(0, rig.Presentation.Results.Count); Check.Equal(0, rig.Models.Generations);
            }
        }));
        tests.Add(("coordinator-color-save-failure-keeps-copyable-success", async () =>
        {
            using var rig = new Rig(); rig.Assets.FailColor = true; var anchor = Fixtures.Anchor();
            await rig.Coordinator.ExecuteAsync(ActionKind.PickColor, anchor); await rig.Coordinator.DrainAsync();
            var result = rig.Presentation.Results[anchor.Id]; Check.Equal(PersistenceState.Failed, result.ColorPersistence!.Value);
            Check.Equal("#112233", result.Color!.Hex); Check.True(result.IsComplete); Check.Equal<string?>(null, result.Error); Check.Equal(0, rig.Presentation.Assets.Count);
        }));
        tests.Add(("coordinator-cancel-late-color-never-saves", async () =>
        {
            using var rig = new Rig(); var sampled = new TaskCompletionSource<PixelColor>(TaskCreationOptions.RunContinuationsAsynchronously); bool started = false;
            rig.Pixel.Sample = (_, _) => { started = true; return sampled.Task; }; var anchor = Fixtures.Anchor();
            var task = rig.Coordinator.ExecuteAsync(ActionKind.PickColor, anchor); await Check.Eventually(() => started);
            rig.Coordinator.Clear(); sampled.SetResult(new(1, 2, 3, "test")); await task; await rig.Coordinator.DrainAsync();
            Check.Equal(0, (await rig.Store.LoadAsync()).Count); Check.Equal(0, rig.Presentation.Results.Count);
        }));
        tests.Add(("coordinator-followup-replacement-cancels-and-rejects-late", async () =>
        {
            using var rig = new Rig(); var anchor = Fixtures.Anchor(); await rig.Coordinator.ExecuteAsync(ActionKind.Explain, anchor);
            var held = new ConcurrentDictionary<string, (FollowupCall Call, TaskCompletionSource<GenerationResult> Done)>();
            rig.Models.Followup = call => { var done = new TaskCompletionSource<GenerationResult>(TaskCreationOptions.RunContinuationsAsynchronously); held[call.Question] = (call, done); return done.Task; };
            var first = rig.Coordinator.FollowupAsync(anchor.Id, "first"); await Check.Eventually(() => held.ContainsKey("first"));
            var second = rig.Coordinator.FollowupAsync(anchor.Id, "second"); await Check.Eventually(() => held.ContainsKey("second"));
            Check.True(held["first"].Call.Token.IsCancellationRequested);
            held["second"].Call.OnText("second stream"); held["second"].Done.SetResult(new("second done", held["second"].Call.Context, new(1, 2))); await second;
            held["first"].Call.OnText("late first"); held["first"].Done.SetResult(new("late first done", held["first"].Call.Context, new(1, 2))); await first;
            Check.Equal("second done", rig.Presentation.Results[anchor.Id].Text); Check.True(!rig.Presentation.Results[anchor.Id].IsAnswering);
        }));
        tests.Add(("coordinator-rapid-tags-refresh-card-and-assets", async () =>
        {
            using var rig = new Rig(); var anchor = Fixtures.Anchor(); await rig.Coordinator.ExecuteAsync(ActionKind.Save, anchor);
            var second = Fixtures.Anchor(); await rig.Coordinator.ExecuteAsync(ActionKind.Save, second);
            Check.Equal(anchor.Id, rig.Presentation.Results[second.Id].Saved!.Id);
            await Task.WhenAll(rig.Coordinator.EditAssetAsync(new AssetEdit.AddTag(anchor.Id, "A")), rig.Coordinator.EditAssetAsync(new AssetEdit.AddTag(anchor.Id, "B")),
                rig.Coordinator.EditAssetAsync(new AssetEdit.RemoveTag(anchor.Id, "tag")));
            Check.Sequence(new[] { "A", "B" }, rig.Presentation.Results[anchor.Id].Saved!.Tags);
            Check.Sequence(new[] { "A", "B" }, rig.Presentation.Results[second.Id].Saved!.Tags);
            Check.Sequence(new[] { "A", "B" }, rig.Presentation.Assets.Single().Tags);
        }));
        tests.Add(("coordinator-clears-many-results-without-cap", async () =>
        {
            using var rig = new Rig(); await Task.WhenAll(Enumerable.Range(0, 70).Select(_ => rig.Coordinator.ExecuteAsync(ActionKind.Explain, Fixtures.Anchor())));
            Check.Equal(70, rig.Coordinator.ActiveResultCount); Check.Equal(70, rig.Presentation.Results.Count);
            rig.Coordinator.Clear(); Check.Equal(0, rig.Coordinator.ActiveResultCount); Check.Equal(0, rig.Presentation.Results.Count);
        }));
        tests.Add(("coordinator-internal-timeout-finishes-card-optional-enrichment-keeps-save", async () =>
        {
            using var rig = new Rig(); var anchor = Fixtures.Anchor();
            rig.Models.Generate = (_, _, _, _) => Task.FromException<GenerationResult>(new TaskCanceledException("internal model timeout"));
            await rig.Coordinator.ExecuteAsync(ActionKind.Explain, anchor);
            Check.True(!rig.Presentation.Results[anchor.Id].IsLoading); Check.Equal("超时了，请重试。", rig.Presentation.Results[anchor.Id].Error);
            var saved = Fixtures.Anchor(); rig.Models.Describe = (_, _, _) => Task.FromException<SavedDescription>(new TaskCanceledException("optional classification timeout"));
            await rig.Coordinator.ExecuteAsync(ActionKind.Save, saved);
            Check.True(rig.Presentation.Results[saved.Id].IsComplete); Check.Equal<string?>(null, rig.Presentation.Results[saved.Id].Error);
            Check.Equal(1, (await rig.Store.LoadAsync()).Count);
        }));
        tests.Add(("coordinator-synchronous-close-on-color-completion-still-saves", async () =>
        {
            using var rig = new Rig(); var anchor = Fixtures.Anchor();
            rig.Presentation.OnShow = state => { if (state.IsComplete && state.ColorPersistence == PersistenceState.Saving) rig.Coordinator.Clear(); };
            await rig.Coordinator.ExecuteAsync(ActionKind.PickColor, anchor); await rig.Coordinator.DrainAsync();
            Check.Equal(0, rig.Presentation.Results.Count); Check.Equal(1, (await rig.Store.LoadAsync()).Count);
        }));
        tests.Add(("coordinator-abandoned-preparation-releases-late-capture", async () =>
        {
            using var rig = new Rig(); var anchor = Fixtures.Anchor(); int released = 0;
            var capture = new TaskCompletionSource<CapturedEvidence>(TaskCreationOptions.RunContinuationsAsynchronously);
            rig.Capture.Capture = (_, _) => capture.Task;
            rig.Coordinator.Receive(new(GesturePhase.Began, anchor, anchor.Point)); await Check.Eventually(() => rig.Capture.Calls == 1);
            rig.Coordinator.Receive(new(GesturePhase.ModifierReleased, null, anchor.Point));
            capture.SetResult(Fixtures.Capture(anchor, release: () => Interlocked.Increment(ref released)));
            await rig.Coordinator.DrainAsync(); Check.Equal(1, released); Check.Equal(0, rig.Models.Generations);
        }));
        tests.Add(("coordinator-shutdown-drains-accepted-color-settings-tags-and-cancels-model", async () =>
        {
            using var rig = new Rig(); var savedId = Guid.NewGuid();
            using var evidence = Fixtures.Capture(text: "before shutdown", image: false);
            await rig.Store.SaveOriginalAsync(savedId, Fixtures.Context(evidence), default);
            rig.Assets.HoldColor = true; rig.Assets.HoldEdits = true; rig.Settings.Hold = true;
            var colorId = Fixtures.Anchor(); await rig.Coordinator.ExecuteAsync(ActionKind.PickColor, colorId); await rig.Assets.ColorEntered.Task.WaitAsync(TimeSpan.FromSeconds(10));
            var edit = rig.Coordinator.EditAssetAsync(new AssetEdit.AddTag(savedId, "before-exit")); await rig.Assets.EditEntered.Task.WaitAsync(TimeSpan.FromSeconds(10));
            var setting = rig.Coordinator.ChangeWheelSettingsAsync(new([ActionKind.PickColor, ActionKind.Explain], new() { [ActionKind.PickColor] = new(1, 2, 3) }));
            await rig.Settings.Entered.Task.WaitAsync(TimeSpan.FromSeconds(10));
            var modelEntered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously); CancellationToken modelToken = default;
            rig.Models.Generate = async (_, context, _, token) =>
            { modelToken = token; modelEntered.TrySetResult(); await Task.Delay(Timeout.Infinite, token); return new("unreachable", Fixtures.Context(context), new(0, 0)); };
            var modelAnchor = Fixtures.Anchor(); rig.Coordinator.Receive(new(GesturePhase.Began, modelAnchor, modelAnchor.Point));
            // The pending preview already applies: Explain is the lower slot of this two-slot wheel.
            rig.Coordinator.Receive(new(GesturePhase.Released, null, new(500, 700))); await modelEntered.Task.WaitAsync(TimeSpan.FromSeconds(10));
            int displayed = rig.Presentation.History.Count;
            rig.Coordinator.Dispose(); var draining = rig.Coordinator.DrainAsync();
            Check.True(modelToken.IsCancellationRequested); Check.True(!draining.IsCompleted);
            Check.True(!rig.Settings.SaveToken.CanBeCanceled); Check.True(!rig.Assets.EditToken.CanBeCanceled);
            Check.True(!await rig.Coordinator.ChangeWheelSettingsAsync(WheelSettings.Default));
            await rig.Coordinator.EditAssetAsync(new AssetEdit.AddTag(savedId, "after-exit"));
            Check.Equal(1, rig.Assets.EditCalls); Check.Equal(1, rig.Settings.Saves);
            rig.Assets.ReleaseColor.SetResult(); rig.Assets.ReleaseEdit.SetResult(); rig.Settings.Release.SetResult();
            await Task.WhenAll(edit, setting, draining).WaitAsync(TimeSpan.FromSeconds(10)); Check.True(await setting);
            var restored = await new JsonAssetStore(rig.Temp.Path).LoadAsync();
            Check.True(restored.Any(x => x.Key == new AssetId(AssetKind.Color, colorId.Id)));
            Check.Sequence(new[] { "before-exit" }, restored.Single(x => x.Key == new AssetId(AssetKind.Saved, savedId)).Tags);
            var wheel = await new JsonWheelSettingsStore(Path.Combine(rig.Temp.Path, "wheel.json")).LoadAsync();
            Check.Sequence(new ActionKind?[] { ActionKind.PickColor, ActionKind.Explain }, wheel.Slots); Check.Equal((byte)1, wheel.Colors[ActionKind.PickColor].Red);
            Check.Equal(displayed, rig.Presentation.History.Count);
        }));
        tests.Add(("coordinator-shutdown-keeps-original-write-already-started", async () =>
        {
            using var rig = new Rig(); rig.Assets.HoldOriginal = true; var anchor = Fixtures.Anchor();
            rig.Coordinator.Receive(new(GesturePhase.Began, anchor, anchor.Point));
            rig.Coordinator.Receive(new(GesturePhase.Released, null, new(500, 300))); await rig.Assets.OriginalEntered.Task;
            rig.Coordinator.Dispose(); var draining = rig.Coordinator.DrainAsync(); Check.True(!draining.IsCompleted);
            rig.Assets.ReleaseOriginal.SetResult(); await draining;
            Check.Equal(1, (await new JsonAssetStore(rig.Temp.Path).LoadAsync()).Count); Check.Equal(0, rig.Models.Descriptions);
            Check.Equal(0, rig.Presentation.Results.Count);
        }));
    }
}
