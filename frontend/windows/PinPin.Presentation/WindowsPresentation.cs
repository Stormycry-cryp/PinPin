using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using PinPin.Core;
using PinPin.Presentation.Controls;
using PinPin.Presentation.Models;
using PinPin.Presentation.Views;

namespace PinPin.Presentation;

public sealed record PresentationDiagnostics(int ResultModels, int MarkerVisuals, int MarkerWindows,
    int CardWindows, int SettingsWindows, int AssetWindows, int OwnedWindows,
    int WatchedSourceWindows, int ActiveUiTimers, int AssetRecords, int AssetResults, int RealizedAssetRows,
    long AssetIndexBuilds, int WpfRenderingTier);

/// Native Windows presentation. Construct on the application's STA Dispatcher; every interface call
/// may then originate on any thread. WPF's Dispatcher/layout system is the only UI scheduling layer.
public sealed class WindowsPresentation : IPinPinPresentation
{
    private readonly Dispatcher dispatcher;
    private readonly Theme theme;
    private readonly SettingsModel settings = new();
    private readonly AssetModel assets = new();
    private WheelSettings wheelSettings = WheelSettings.Default;
    private PresentationCallbacks callbacks = new();
    private readonly Dictionary<Guid, ResultModel> results = [];
    private readonly Dictionary<Guid, ResultWindow> cards = [];
    private readonly HashSet<Guid> removed = [];
    private readonly object resultGate = new();
    private readonly Dictionary<Guid, PendingResult> pendingResults = [];
    private readonly Dictionary<nint, int> sourceReferences = [];
    private readonly Dictionary<nint, SourceWindowState> sourceStates = [];
    private readonly HashSet<nint> ownHandles = [];
    private readonly MarkerLayers markers;
    private GestureWheelWindow? wheel;
    private SettingsWindow? settingsWindow;
    private AssetWindow? assetWindow;
    private readonly HashSet<Guid> afterWheel = [];
    private int disposed;

    public WindowsPresentation(Dispatcher dispatcher, string? appearancePreferencePath = null)
    {
        ArgumentNullException.ThrowIfNull(dispatcher); dispatcher.VerifyAccess();
        if (Thread.CurrentThread.GetApartmentState() != ApartmentState.STA)
            throw new InvalidOperationException("WindowsPresentation requires the WPF STA Dispatcher thread.");
        this.dispatcher = dispatcher;
        theme = new(appearancePreferencePath);
        markers = new(theme, wheelSettings, OwnWindowCreated, OpenResult, CloseFromUser, ClearFromUser);
        settings.Save = value => callbacks.WheelSettingsChanged?.Invoke(value) ?? Task.FromResult(false);
        settings.Previewed += ApplyPreview;
        assets.Edit = edit => callbacks.AssetEdited?.Invoke(edit);
        theme.Changed += ThemeChanged;
    }

    private void OnUi(Action action)
    {
        if (Volatile.Read(ref disposed) != 0 || dispatcher.HasShutdownStarted) return;
        if (dispatcher.CheckAccess()) action();
        else dispatcher.BeginInvoke(DispatcherPriority.Normal, new Action(() => { if (Volatile.Read(ref disposed) == 0) action(); }));
    }
    public void SetCallbacks(PresentationCallbacks value)
    {
        ArgumentNullException.ThrowIfNull(value);
        OnUi(() =>
        {
            foreach (nint source in sourceReferences.Keys) callbacks.SourceWindowUnwatched?.Invoke(source);
            callbacks = value;
            foreach (nint source in sourceReferences.Keys) callbacks.SourceWindowWatched?.Invoke(source);
            foreach (nint handle in ownHandles) callbacks.OwnWindowCreated?.Invoke(handle);
        });
    }
    public void UpdateWheelSettings(WheelSettings value)
    {
        if (!value.IsValid) return;
        var snapshot = value.Copy();
        OnUi(() => { settings.Receive(snapshot); ApplyPreview(settings.Value); });
    }
    private void ApplyPreview(WheelSettings value)
    {
        if (SettingsModel.Equal(wheelSettings, value)) return;
        wheelSettings = value.Copy();
        markers.Repaint(wheelSettings);
        foreach (var card in cards.Values) card.Recolor(wheelSettings);
        // Visible gesture geometry, actions and feature colors remain frozen in its WheelSnapshot.
    }
    public void ShowWheel(WheelSnapshot value)
    {
        var snapshot = value with { Settings = value.Settings.Copy(), Slots = value.Slots.ToArray(), Screens = value.Screens.ToArray() };
        OnUi(() =>
        {
            markers.CancelHover();
            foreach (var model in results.Values.Where(x => x.Peek && x.Mode == CardMode.Short).ToArray()) Collapse(model.Id);
            wheel ??= new(theme, OwnWindowCreated);
            wheel.ShowSnapshot(snapshot);
        });
    }
    public void MoveWheel(ScreenPoint point) => OnUi(() => wheel?.MovePointer(point));
    public void HideWheel() => OnUi(() =>
    {
        wheel?.Dismiss();
        foreach (Guid id in afterWheel.ToArray()) OpenResult(id, false, shortCard: true);
        afterWheel.Clear();
    });

    public void ShowResult(ResultState state)
    {
        // The array inside a Saved record is mutable by contract; snapshot before asynchronous UI dispatch.
        var snapshot = state.Saved is { } saved ? state with { Saved = saved with { Tags = saved.Tags.ToArray() } } : state;
        lock (resultGate)
        {
            if (Volatile.Read(ref disposed) != 0 || dispatcher.HasShutdownStarted || removed.Contains(state.Id)) return;
            if (pendingResults.TryGetValue(state.Id, out var pending)) { pending.Add(snapshot); return; }
            if (!dispatcher.CheckAccess())
            {
                pending = new(); pending.Add(snapshot); pendingResults.Add(state.Id, pending);
                ScheduleResult(state.Id, pending); return;
            }
        }
        ApplyResult(snapshot);
    }

    // Only cumulative text in an unchanged state may replace an unpublished tail. The first
    // text and each loading/completion/error/question/color/anchor transition retain their order.
    internal sealed class PendingResult
    {
        private readonly LinkedList<(ResultState State, bool Replaceable)> states = new();
        internal DispatcherOperation? Operation;
        internal int Count => states.Count;
        internal bool ReferencesSource(nint hwnd) => states.Any(x => x.State.Anchor.Window == hwnd);
        internal bool ReferencesSaved(IReadOnlySet<AssetId> deleted) => states.Any(x => x.State.Saved is { } saved && deleted.Contains(saved.Key));
        internal void Add(ResultState state)
        {
            var tail = states.Last;
            // A successful final snapshot already contains this unpublished cumulative tail.
            // Keep the first snapshot and every semantic boundary; only this replaceable tail
            // can disappear, avoiding a second near-identical full-text layout before completion.
            if (tail is { Value.Replaceable: true } && Completes(tail.Value.State, state))
            { states.RemoveLast(); states.AddLast((state, false)); return; }
            bool continuation = tail is not null && Continues(tail.Value.State, state);
            if (continuation && tail!.Value.Replaceable) tail.Value = (state, true);
            else states.AddLast((state, continuation));
        }
        private static bool Continues(ResultState previous, ResultState next) =>
            (!previous.IsComplete || previous.IsAnswering) && previous.Error is null && previous.Text.Length > 0 &&
            next.Text.StartsWith(previous.Text, StringComparison.Ordinal) &&
            SameState(previous with { Text = next.Text }, next);
        private static bool Completes(ResultState previous, ResultState next) =>
            (!previous.IsComplete || previous.IsAnswering) && previous.Error is null &&
            (!previous.IsLoading || (!previous.IsComplete && !previous.IsAnswering)) &&
            previous.Text.Length > 0 && next.IsComplete && !next.IsAnswering && !next.IsLoading && next.Error is null &&
            next.Text.StartsWith(previous.Text, StringComparison.Ordinal) &&
            SameState(previous with { Text = next.Text, IsLoading = false, IsComplete = true, IsAnswering = false }, next);
        private static bool SameState(ResultState previous, ResultState next)
        {
            if (previous == next) return true;
            // ShowResult snapshots the mutable tag array. Array identity may differ even when
            // content is unchanged; preserve order, case and every other saved-record field.
            return previous.Saved is { } before && next.Saved is { } after &&
                before.Tags.SequenceEqual(after.Tags, StringComparer.Ordinal) &&
                (before with { Tags = after.Tags }) == after &&
                (previous with { Saved = after }) == next;
        }
        internal ResultState Take()
        { var state = states.First!.Value.State; states.RemoveFirst(); return state; }
    }
    private void ScheduleResult(Guid id, PendingResult pending) =>
        pending.Operation = dispatcher.BeginInvoke(DispatcherPriority.Background, new Action(() => DrainResult(id, pending)));
    private void DrainResult(Guid id, PendingResult pending)
    {
        ResultState state;
        lock (resultGate)
        {
            if (Volatile.Read(ref disposed) != 0 || !pendingResults.TryGetValue(id, out var current) || current != pending) return;
            pending.Operation = null; state = pending.Take();
        }
        try { ApplyResult(state); }
        finally
        {
            lock (resultGate)
            {
                if (pendingResults.TryGetValue(id, out var current) && current == pending)
                {
                    if (pending.Count == 0) pendingResults.Remove(id);
                    else ScheduleResult(id, pending);
                }
            }
        }
    }
    private void ApplyResult(ResultState state)
    {
        lock (resultGate) if (removed.Contains(state.Id)) return;
        bool created = !results.TryGetValue(state.Id, out var model);
        if (created)
        { model = new(state); results.Add(state.Id, model); Watch(state.Anchor.Window); }
        else
        {
            nint previous = model!.State.Anchor.Window;
            if (previous != state.Anchor.Window) { Unwatch(previous); Watch(state.Anchor.Window); }
            model.Apply(state);
        }
        model!.SourceVisible = SourceVisible(state.Anchor.Window);
        if (created)
        {
            if (wheel?.Showing == true) afterWheel.Add(state.Id);
            else OpenResult(state.Id, false, shortCard: true);
        }
        else if (model.IsFailure && model.SourceVisible && model.Mode == CardMode.Hidden && wheel?.Showing != true)
            OpenResult(state.Id, false, shortCard: true);
        RefreshVisibility(model);
    }

    public void RemoveResult(Guid id) => OnUi(() => Remove(id));
    private void Remove(Guid id)
    {
        lock (resultGate)
        {
            removed.Add(id);
            if (pendingResults.Remove(id, out var pending)) pending.Operation?.Abort();
        }
        afterWheel.Remove(id); markers.Remove(id);
        DestroyCard(id);
        if (results.Remove(id, out var model)) Unwatch(model.State.Anchor.Window);
        lock (resultGate)
            foreach (nint source in sourceStates.Keys.Where(x => !sourceReferences.ContainsKey(x) &&
                !pendingResults.Values.Any(p => p.ReferencesSource(x))).ToArray()) sourceStates.Remove(source);
    }
    private void CloseFromUser(Guid id) { Remove(id); callbacks.ResultClosed?.Invoke(id); }
    public void ClearResults() => OnUi(Clear);
    private void Clear()
    {
        Guid[] ids;
        lock (resultGate) ids = results.Keys.Concat(pendingResults.Keys).Distinct().ToArray();
        foreach (Guid id in ids) Remove(id);
        afterWheel.Clear(); markers.CancelHover();
    }
    private void ClearFromUser() { Clear(); callbacks.ClearRequested?.Invoke(); }

    private void OpenResult(Guid id, bool peek) => OpenResult(id, peek, shortCard: peek);
    private void OpenResult(Guid id, bool peek, bool shortCard)
    {
        if (!results.TryGetValue(id, out var model)) return;
        model.Mode = shortCard ? CardMode.Short : CardMode.Dialog; model.Peek = peek;
        markers.Remove(id);
        if (!model.SourceVisible) return;
        if (cards.TryGetValue(id, out var existing)) { existing.SetMode(); return; }
        var card = new ResultWindow(theme, wheelSettings, model, VisualAnchor(model), OwnWindowCreated,
            () => Collapse(id), () => OpenResult(id, false, shortCard: false), () => CloseFromUser(id), RequestAssets,
            ClearFromUser, (resultId, question) => callbacks.FollowupRequested?.Invoke(resultId, question),
            edit => callbacks.AssetEdited?.Invoke(edit));
        cards.Add(id, card); card.Open();
    }
    private void Collapse(Guid id)
    {
        if (!results.TryGetValue(id, out var model)) return;
        model.Mode = CardMode.Hidden; model.Peek = false; DestroyCard(id); RefreshVisibility(model);
    }
    private void DestroyCard(Guid id)
    { if (cards.Remove(id, out var card)) card.Close(); }

    public void UpdateAssets(IReadOnlyList<AssetRecord> records)
    {
        var copy = records.Select(x => x with { Tags = x.Tags.ToArray() }).ToArray();
        OnUi(() =>
        {
            var previous = assets.Records.Select(x => x.Key).ToHashSet();
            assets.Receive(copy);
            var saved = copy.Where(x => x.Kind == AssetKind.Saved).ToDictionary(x => x.Id);
            var deleted = previous.Where(x => x.Kind == AssetKind.Saved && !saved.ContainsKey(x.Id)).ToHashSet();
            Guid[] pendingDeleted;
            lock (resultGate) pendingDeleted = pendingResults.Where(x => x.Value.ReferencesSaved(deleted)).Select(x => x.Key).ToArray();
            foreach (Guid id in pendingDeleted) { Remove(id); callbacks.ResultClosed?.Invoke(id); }
            foreach (var model in results.Values.ToArray())
            {
                if (model.State.Saved is not { } item) continue;
                if (saved.TryGetValue(item.Id, out var current)) model.Apply(model.State with { Saved = current });
                else if (previous.Contains(item.Key)) { Remove(model.Id); callbacks.ResultClosed?.Invoke(model.Id); }
            }
        });
    }
    private void RequestAssets() { ShowAssetsCore(); callbacks.AssetsRequested?.Invoke(); }
    public void ShowAssets() => OnUi(ShowAssetsCore);
    private void ShowAssetsCore() { assetWindow ??= new(theme, assets, OwnWindowCreated); assetWindow.Open(); }
    public void ShowSettings() => OnUi(() => { settingsWindow ??= new(theme, settings, RequestAssets, OwnWindowCreated); settingsWindow.Open(); });

    public void UpdateSourceWindow(SourceWindowState state) => OnUi(() =>
    {
        lock (resultGate)
            if (!sourceReferences.ContainsKey(state.Window) && !pendingResults.Values.Any(x => x.ReferencesSource(state.Window))) return;
        sourceStates[state.Window] = state;
        foreach (var model in results.Values.Where(x => x.State.Anchor.Window == state.Window).ToArray())
        { model.SourceVisible = state.Visible; RefreshVisibility(model); }
    });
    private bool SourceVisible(nint hwnd) => hwnd == 0 || !sourceStates.TryGetValue(hwnd, out var state) || state.Visible;
    private TargetAnchor VisualAnchor(ResultModel model)
    {
        var anchor = model.State.Anchor;
        if (!sourceStates.TryGetValue(anchor.Window, out var state)) return anchor;
        return anchor with { Point = new(anchor.Point.X + state.Bounds.X - anchor.WindowBounds.X,
            anchor.Point.Y + state.Bounds.Y - anchor.WindowBounds.Y) };
    }
    private void RefreshVisibility(ResultModel model)
    {
        if (!model.SourceVisible) { markers.Remove(model.Id); DestroyCard(model.Id); return; }
        var anchor = VisualAnchor(model);
        if (model.Mode == CardMode.Hidden && !model.IsFailure)
            markers.Put(new(model.Id, model.State.Action, anchor, model.Busy));
        else
        {
            markers.Remove(model.Id);
            if (model.Mode != CardMode.Hidden && !cards.ContainsKey(model.Id)) OpenResult(model.Id, model.Peek, model.Mode == CardMode.Short);
            if (cards.TryGetValue(model.Id, out var card)) card.SetAnchor(anchor);
        }
    }
    private void Watch(nint hwnd)
    {
        if (hwnd == 0) return;
        int count = sourceReferences.GetValueOrDefault(hwnd); sourceReferences[hwnd] = count + 1;
        if (count == 0) callbacks.SourceWindowWatched?.Invoke(hwnd);
    }
    private void Unwatch(nint hwnd)
    {
        if (hwnd == 0 || !sourceReferences.TryGetValue(hwnd, out int count)) return;
        if (count > 1) sourceReferences[hwnd] = count - 1;
        else
        {
            sourceReferences.Remove(hwnd);
            lock (resultGate)
                if (!pendingResults.Values.Any(x => x.ReferencesSource(hwnd))) sourceStates.Remove(hwnd);
            callbacks.SourceWindowUnwatched?.Invoke(hwnd);
        }
    }
    private void OwnWindowCreated(nint hwnd)
    {
        ownHandles.Add(hwnd);
        if (HwndSource.FromHwnd(hwnd) is { } source) source.Disposed += (_, _) => ownHandles.Remove(hwnd);
        callbacks.OwnWindowCreated?.Invoke(hwnd);
    }
    private void ThemeChanged() => OnUi(() =>
    {
        markers.Repaint(wheelSettings); wheel?.Repaint(); settingsWindow?.Repaint(); assetWindow?.Repaint();
        foreach (var card in cards.Values) card.Repaint(wheelSettings);
    });

    public PresentationDiagnostics GetDiagnostics()
    {
        PresentationDiagnostics Read() => new(results.Count, markers.VisualCount, markers.WindowCount, cards.Count,
            settingsWindow is null ? 0 : 1, assetWindow is null ? 0 : 1, ownHandles.Count, sourceReferences.Count,
            markers.ActiveHoverTimers + cards.Values.Sum(x => x.ActiveTimers) + (assetWindow?.ActiveTimers ?? 0),
            assets.Records.Count, assets.Results.Count, assetWindow?.RealizedRows ?? 0, assets.IndexBuilds, RenderCapability.Tier >> 16);
        return dispatcher.CheckAccess() ? Read() : dispatcher.Invoke(Read);
    }
    internal ResultModel? TestResult(Guid id) => results.GetValueOrDefault(id);
    internal int TestPendingResultCount { get { lock (resultGate) return pendingResults.Count; } }
    internal void TestOpen(Guid id) => OpenResult(id, false);
    internal void TestCollapse(Guid id) => Collapse(id);
    internal void TestClose(Guid id) => CloseFromUser(id);
    internal SettingsModel TestSettings => settings;
    internal AssetModel TestAssets => assets;
    internal void TestToggleAppearance() => theme.Toggle();
    internal IReadOnlyList<Window> TestWindows => cards.Values.Cast<Window>().Concat(new Window?[] { wheel, settingsWindow, assetWindow }.OfType<Window>()).ToArray();

    public void Dispose()
    {
        if (Interlocked.Exchange(ref disposed, 1) != 0) return;
        void Cleanup()
        {
            Clear(); markers.Dispose(); wheel?.Close(); settingsWindow?.Close(); assetWindow?.Close();
            wheel = null; settingsWindow = null; assetWindow = null;
            lock (resultGate) removed.Clear();
            theme.Changed -= ThemeChanged; theme.Dispose(); settings.Previewed -= ApplyPreview;
            callbacks = new(); ownHandles.Clear();
        }
        if (dispatcher.CheckAccess()) Cleanup();
        else if (!dispatcher.HasShutdownStarted) dispatcher.Invoke(Cleanup);
    }
}
