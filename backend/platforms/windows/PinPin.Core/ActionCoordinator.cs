namespace PinPin.Core;

/// Thread-safe session owner. Presentation implementations dispatch their own UI work.
public sealed class ActionCoordinator : IDisposable
{
    private sealed class Session
    {
        public readonly TargetAnchor Anchor;
        public readonly ActionKind Action;
        public readonly CancellationTokenSource Cancellation;
        public readonly CancellationToken Token;
        public CancellationTokenSource RequestCancellation;
        public ResultState State;
        public PromptContext? Context;
        public readonly List<FollowupExchange> Exchanges = [];
        public int Generation;
        public Session(ActionKind action, TargetAnchor anchor, CancellationToken lifetime)
        {
            Action = action; Anchor = anchor; Cancellation = CancellationTokenSource.CreateLinkedTokenSource(lifetime);
            Token = Cancellation.Token; RequestCancellation = CancellationTokenSource.CreateLinkedTokenSource(Token);
            State = new(anchor.Id, action, anchor);
        }
        public void Cancel() { RequestCancellation.Cancel(); RequestCancellation.Dispose(); Cancellation.Cancel(); Cancellation.Dispose(); }
    }
    private sealed class Preparation
    {
        public readonly CancellationTokenSource Cancellation;
        public readonly Task<CapturedEvidence> Task;
        public Preparation(TargetAnchor anchor, ICaptureService capture, CancellationToken lifetime)
        {
            Cancellation = CancellationTokenSource.CreateLinkedTokenSource(lifetime);
            var token = Cancellation.Token;
            Task = System.Threading.Tasks.Task.Run(() => capture.CaptureAsync(anchor, token));
        }
    }
    private readonly object sync = new();
    private readonly IPinPinPresentation presentation;
    private readonly ICaptureService capture;
    private readonly IPixelSampler sampler;
    private readonly IModelService models;
    private readonly IAssetStore assets;
    private readonly IWheelSettingsStore settingsStore;
    private readonly IInputSource? input;
    private readonly Func<IReadOnlyList<ScreenRect>> screens;
    private readonly Func<TargetAnchor, (string AppName, string WindowTitle)> colorSource;
    private readonly Dictionary<Guid, Session> sessions = [];
    private readonly HashSet<Task> tasks = [];
    private readonly CancellationTokenSource lifetime = new();
    private readonly CancellationToken lifetimeToken;
    private Preparation? preparation;
    private WheelSnapshot? wheel;
    private bool consumed;
    private WheelSettings settings = WheelSettings.Default;
    private bool disposed;
    private long settingsRevision;
    private long publishRevision;
    private long appliedPublishRevision;
    public event Action<Exception>? BackgroundError;

    public ActionCoordinator(IPinPinPresentation presentation, ICaptureService capture, IPixelSampler sampler,
        IModelService models, IAssetStore assets, IWheelSettingsStore settingsStore,
        Func<IReadOnlyList<ScreenRect>> screens, PresentationCallbacks? hostCallbacks = null,
        Func<TargetAnchor, (string AppName, string WindowTitle)>? colorSource = null, IInputSource? input = null)
    {
        this.presentation = presentation; this.capture = capture; this.sampler = sampler; this.models = models;
        this.assets = assets; this.settingsStore = settingsStore; this.screens = screens;
        this.input = input;
        this.colorSource = colorSource ?? (_ => ("", "")); lifetimeToken = lifetime.Token;
        presentation.SetCallbacks(new PresentationCallbacks
        {
            ResultClosed = Close, FollowupRequested = (id, question) => Track(FollowupAsync(id, question)),
            AssetEdited = edit => _ = EditAssetAsync(edit), WheelSettingsChanged = ChangeWheelSettingsAsync,
            AssetsRequested = () => Track(ShowAssetsAsync()), SettingsRequested = OpenSettings,
            ClearRequested = Clear, QuitRequested = hostCallbacks?.QuitRequested, OwnWindowCreated = hostCallbacks?.OwnWindowCreated,
            SourceWindowWatched = hostCallbacks?.SourceWindowWatched, SourceWindowUnwatched = hostCallbacks?.SourceWindowUnwatched
        });
    }
    private void Track(Task task)
    {
        lock (sync) tasks.Add(task);
        _ = task.ContinueWith(done =>
        {
            lock (sync) tasks.Remove(done);
            if (done.Exception is { } error) Report(error.GetBaseException());
        }, CancellationToken.None, TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
    }
    private void Report(Exception error) { try { BackgroundError?.Invoke(error); } catch { /* Error reporting cannot corrupt sessions. */ } }
    public async Task DrainAsync()
    {
        while (true)
        {
            Task[] pending; lock (sync) pending = tasks.ToArray(); if (pending.Length == 0) return;
            try { await Task.WhenAll(pending).ConfigureAwait(false); } catch { /* Individual errors are reported. */ }
        }
    }
    public async Task InitializeAsync(CancellationToken cancellationToken = default)
    {
        var revision = Interlocked.Read(ref settingsRevision);
        try
        {
            var loaded = await settingsStore.LoadAsync(cancellationToken).ConfigureAwait(false);
            lock (sync) if (!disposed && revision == settingsRevision) ApplyWheelSettings(loaded);
        }
        catch (Exception e) when (e is not OperationCanceledException)
        { Report(e); lock (sync) if (!disposed) ApplyWheelSettings(settings); }
        try { await PublishAssetsAsync(cancellationToken).ConfigureAwait(false); }
        catch (Exception e) when (e is not OperationCanceledException) { Report(e); }
    }
    public void Receive(GestureEvent gesture)
    {
        lock (sync)
        {
            if (disposed) return;
            switch (gesture.Phase)
            {
                case GesturePhase.Began when settings.TriggerEnabled && gesture.Anchor is { } anchor:
                    AbandonPreparation();
                    consumed = false;
                    wheel = WheelGeometry.Create(anchor, settings, screens());
                    preparation = new Preparation(anchor, capture, lifetimeToken);
                    presentation.ShowWheel(wheel);
                    Track(models.PrewarmAsync(lifetimeToken));
                    break;
                case GesturePhase.Moved:
                    if (wheel is not null) presentation.MoveWheel(gesture.Point);
                    break;
                case GesturePhase.Released:
                    if (consumed || wheel is not { } snapshot) return;
                    consumed = true;
                    var selected = WheelGeometry.ActionAt(snapshot, gesture.Point);
                    if (selected is null) { AbandonPreparation(); return; }
                    var ready = preparation; preparation = null;
                    if (selected == ActionKind.PickColor) { Abandon(ready); ready = null; }
                    Track(ExecuteCoreAsync(selected.Value, snapshot.Anchor, ready));
                    break;
                case GesturePhase.ModifierReleased:
                    consumed = true;
                    wheel = null; presentation.HideWheel(); AbandonPreparation();
                    break;
                case GesturePhase.ClearAll when gesture.Anchor is { } clearAnchor &&
                    (!settings.TriggerEnabled || wheel is null || wheel.Anchor.Id != clearAnchor.Id):
                    break; // A queued native clear cannot outlive its wheel; explicit UI clear has no anchor.
                case GesturePhase.ClearAll:
                    consumed = true;
                    AbandonPreparation(); ClearResultsCore();
                    break;
                case GesturePhase.OpenSettings:
                    OpenSettings();
                    break;
            }
        }
    }
    public void OpenSettings()
    {
        lock (sync)
        {
            if (disposed) return;
            consumed = true;
            wheel = null; presentation.HideWheel(); AbandonPreparation();
            presentation.ShowSettings();
        }
    }
    private void AbandonPreparation() { var old = preparation; preparation = null; Abandon(old); }
    private void Abandon(Preparation? old)
    {
        if (old is null) return;
        old.Cancellation.Cancel();
        Track(Task.Run(async () =>
        {
            try { (await old.Task.ConfigureAwait(false)).Dispose(); } catch (Exception e) when (e is OperationCanceledException) { }
            finally { old.Cancellation.Dispose(); }
        }));
    }
    public Task ExecuteAsync(ActionKind action, TargetAnchor anchor) => ExecuteCoreAsync(action, anchor, null);
    private bool Current(Session session, int generation) => !disposed && !session.Token.IsCancellationRequested &&
        sessions.TryGetValue(session.Anchor.Id, out var current) && ReferenceEquals(current, session) && session.Generation == generation;
    private bool Update(Session session, int generation, Func<ResultState, ResultState> change)
    {
        lock (sync)
        {
            if (!Current(session, generation)) return false;
            session.State = change(session.State); presentation.ShowResult(session.State); return true;
        }
    }
    private static PromptContext Kept(PromptContext context, bool replyCoach = false) => context with
    {
        Image = context.Image is { } image
            ? replyCoach && image.UnmarkedPng.Length > 0
                // Keep only the encoding used by this session, with its own normalized point.
                ? image with { MarkedJpeg = [], PointInImage = image.OriginalPointInImage }
                : image with { UnmarkedPng = [] }
            : null
    };
    private async Task ExecuteCoreAsync(ActionKind action, TargetAnchor anchor, Preparation? ready)
    {
        Session session; int generation; CancellationToken token;
        lock (sync)
        {
            if (disposed) { Abandon(ready); return; }
            if (sessions.Remove(anchor.Id, out var old)) old.Cancel();
            session = new(action, anchor, lifetimeToken); sessions[anchor.Id] = session; generation = ++session.Generation;
            token = session.RequestCancellation.Token;
            presentation.ShowResult(session.State);
        }
        CapturedEvidence? evidence = null;
        using var cancelPreparation = token.Register(() => { if (ready is not null) { try { ready.Cancellation.Cancel(); } catch (ObjectDisposedException) { } } });
        try
        {
            if (action == ActionKind.PickColor)
            {
                var color = await Task.Run(() => sampler.SampleAsync(anchor, token), token).ConfigureAwait(false);
                (string AppName, string WindowTitle) source;
                try { source = colorSource(anchor); }
                catch (Exception error) { Report(error); source = ("", ""); }
                // From this point history outlives the result card, including a synchronous close callback.
                if (!Update(session, generation, state => state with { Text = color.Hex, Color = color, IsLoading = false,
                    IsComplete = true, ColorPersistence = PersistenceState.Saving })) return;
                Track(PersistColorAsync(session, color, source.AppName, source.WindowTitle));
                return;
            }
            evidence = ready is null ? await Task.Run(() => capture.CaptureAsync(anchor, token), token).ConfigureAwait(false) : await ready.Task.ConfigureAwait(false);
            lock (sync) if (!Current(session, generation)) return;
            if (evidence.Anchor.Id != anchor.Id) throw new OperationCanceledException();
            if (action == ActionKind.Save)
            {
                // Original persistence is independent of optional later classification.
                var context = await models.PrepareSaveAsync(evidence, token).ConfigureAwait(false);
                lock (sync) if (!Current(session, generation)) return;
                var saved = await assets.SaveOriginalAsync(anchor.Id, context, CancellationToken.None).ConfigureAwait(false);
                context = Kept(context);
                evidence.Dispose(); evidence = null;
                lock (sync) { if (!Current(session, generation)) return; session.Context = Kept(context); }
                if (!Update(session, generation, state => state with { Saved = saved, Text = saved.Text, IsLoading = false, IsComplete = true })) return;
                await PublishAssetsAsync(lifetimeToken).ConfigureAwait(false);
                try
                {
                    var snapshot = await assets.LoadAsync(token).ConfigureAwait(false);
                    var existingTags = snapshot.SelectMany(x => x.Tags).GroupBy(x => x, StringComparer.OrdinalIgnoreCase)
                        .OrderByDescending(x => x.Count()).ThenBy(x => x.Key, StringComparer.Ordinal).Select(x => x.Key).Take(40).ToArray();
                    var description = await models.DescribeSavedAsync(context, existingTags, token).ConfigureAwait(false);
                    lock (sync) if (!Current(session, generation)) return;
                    await assets.EnrichAsync(saved.Id, description, CancellationToken.None).ConfigureAwait(false);
                    await PublishAssetsAsync(CancellationToken.None).ConfigureAwait(false);
                }
                catch (Exception e) { if (!token.IsCancellationRequested) Report(e); }
            }
            else
            {
                var result = await models.GenerateAsync(action, evidence,
                    text => Update(session, generation, state => state with { Text = text }), token).ConfigureAwait(false);
                lock (sync) { if (!Current(session, generation)) return; session.Context = Kept(result.Context, action == ActionKind.ReplyCoach); }
                Update(session, generation, state => state with { Text = result.Text, IsLoading = false, IsComplete = true });
            }
        }
        catch (OperationCanceledException)
        {
            if (!token.IsCancellationRequested)
                Update(session, generation, state => state with { IsLoading = false, IsAnswering = false, Error = "超时了，请重试。" });
        }
        catch (Exception error)
        {
            Update(session, generation, state => state with { IsLoading = false, IsAnswering = false, Error = UserMessage(error) });
        }
        finally { evidence?.Dispose(); ready?.Cancellation.Dispose(); }
    }
    private async Task PersistColorAsync(Session session, PixelColor color, string app, string window)
    {
        try
        {
            await assets.SaveColorAsync(session.Anchor.Id, color, app, window, CancellationToken.None).ConfigureAwait(false);
            await PublishAssetsAsync(CancellationToken.None).ConfigureAwait(false);
            lock (sync)
            {
                if (!disposed && sessions.TryGetValue(session.Anchor.Id, out var current) && ReferenceEquals(current, session))
                { session.State = session.State with { ColorPersistence = PersistenceState.Saved }; presentation.ShowResult(session.State); }
            }
        }
        catch (Exception error)
        {
            lock (sync)
            {
                if (!disposed && sessions.TryGetValue(session.Anchor.Id, out var current) && ReferenceEquals(current, session))
                { session.State = session.State with { ColorPersistence = PersistenceState.Failed }; presentation.ShowResult(session.State); }
            }
            Report(error);
        }
    }
    public async Task FollowupAsync(Guid id, string question)
    {
        Session session; int generation; PromptContext context; string previous; FollowupExchange[] earlier; CancellationToken token;
        lock (sync)
        {
            if (disposed || !sessions.TryGetValue(id, out session!) || session.Action == ActionKind.PickColor ||
                !session.State.IsComplete || string.IsNullOrWhiteSpace(question)) return;
            generation = ++session.Generation; previous = session.State.Text; earlier = session.Exchanges.ToArray();
            session.RequestCancellation.Cancel(); session.RequestCancellation.Dispose();
            session.RequestCancellation = CancellationTokenSource.CreateLinkedTokenSource(session.Token); token = session.RequestCancellation.Token;
            context = session.Context ?? new(previous, "", null, "", "");
            session.State = session.State with { IsAnswering = true, Question = question, Error = null };
            presentation.ShowResult(session.State);
        }
        try
        {
            var result = await models.FollowupAsync(session.Action, context, previous, earlier, question,
                text => Update(session, generation, state => state with { Text = text }), token).ConfigureAwait(false);
            lock (sync)
            {
                if (!Current(session, generation)) return;
                session.Exchanges.Add(new(question, result.Text));
                if (session.Exchanges.Count > 4) session.Exchanges.RemoveAt(0);
            }
            Update(session, generation, state => state with { Text = result.Text, IsAnswering = false, Error = null });
        }
        catch (OperationCanceledException)
        {
            if (!token.IsCancellationRequested)
                Update(session, generation, state => state with { IsAnswering = false, Error = "超时了，请重试。" });
        }
        catch (Exception error) { Update(session, generation, state => state with { IsAnswering = false, Error = UserMessage(error) }); }
    }
    public Task EditAssetAsync(AssetEdit edit)
    {
        lock (sync)
        {
            if (disposed) return Task.CompletedTask;
            // Enter the serialized store in callback order so add/remove of the same tag cannot invert.
            var task = EditAssetCoreAsync(edit); Track(task); return task;
        }
    }
    private async Task EditAssetCoreAsync(AssetEdit edit)
    {
        try { await assets.ApplyAsync(edit, CancellationToken.None).ConfigureAwait(false); await PublishAssetsAsync(CancellationToken.None).ConfigureAwait(false); }
        catch (Exception error) { Report(error); }
    }
    private async Task PublishAssetsAsync(CancellationToken token)
    {
        var revision = Interlocked.Increment(ref publishRevision);
        var snapshot = await assets.LoadAsync(token).ConfigureAwait(false);
        lock (sync)
        {
            if (disposed || revision < appliedPublishRevision) return;
            appliedPublishRevision = revision; presentation.UpdateAssets(snapshot);
            foreach (var session in sessions.Values.ToArray())
            {
                if (!sessions.TryGetValue(session.Anchor.Id, out var active) || !ReferenceEquals(active, session)) continue;
                if (session.State.Saved is not { } saved) continue;
                var current = snapshot.FirstOrDefault(x => x.Key == saved.Key);
                if (current is null) continue;
                session.State = session.State with { Saved = current, Text = session.State.Question is null ? current.Text : session.State.Text };
                presentation.ShowResult(session.State);
            }
        }
    }
    private async Task ShowAssetsAsync()
    { await PublishAssetsAsync(lifetimeToken).ConfigureAwait(false); lock (sync) if (!disposed) presentation.ShowAssets(); }
    private void ApplyWheelSettings(WheelSettings value)
    {
        settings = value.Copy();
        if (!settings.TriggerEnabled)
        {
            consumed = true; wheel = null; presentation.HideWheel(); AbandonPreparation();
        }
        input?.SetWheelTriggerEnabled(settings.TriggerEnabled);
        presentation.UpdateWheelSettings(settings.Copy());
    }
    public Task<bool> ChangeWheelSettingsAsync(WheelSettings next)
    {
        lock (sync)
        {
            if (disposed || !next.IsValid || next.Colors.Keys.Any(k => !Enum.IsDefined(k))) return Task.FromResult(false);
            var copy = next.Copy(); var revision = Interlocked.Increment(ref settingsRevision);
            ApplyWheelSettings(copy);
            var task = Task.Run(() => SaveWheelSettingsCoreAsync(copy, revision)); Track(task); return task;
        }
    }
    private async Task<bool> SaveWheelSettingsCoreAsync(WheelSettings copy, long revision)
    {
        try
        {
            Task<bool> write;
            lock (sync)
            {
                if (revision != settingsRevision) return false;
                // Check and enter the store together: task scheduling must not invert user edit order.
                write = settingsStore.SaveAsync(copy, CancellationToken.None);
            }
            return await write.ConfigureAwait(false);
        }
        catch (Exception e) when (e is not OperationCanceledException) { Report(e); return false; }
    }
    public void Close(Guid id)
    {
        lock (sync)
        {
            if (!sessions.Remove(id, out var session)) return;
            session.Cancel(); presentation.RemoveResult(id);
        }
    }
    public void Clear()
    {
        lock (sync)
        {
            consumed = true;
            wheel = null; presentation.HideWheel(); AbandonPreparation();
            ClearResultsCore();
        }
    }
    private void ClearResultsCore()
    {
        foreach (var session in sessions.Values) session.Cancel();
        sessions.Clear(); presentation.ClearResults();
    }
    public int ActiveResultCount { get { lock (sync) return sessions.Count; } }
    public void Dispose()
    {
        lock (sync)
        {
            if (disposed) return; Clear(); disposed = true; lifetime.Cancel(); lifetime.Dispose();
            presentation.SetCallbacks(new PresentationCallbacks());
        }
    }
    private static string UserMessage(Exception error) => error switch
    { GatewayException => error.Message, UnauthorizedAccessException or IOException => "没能保存到本机，请重试。", _ => "没能完成，请重试。" };
}
