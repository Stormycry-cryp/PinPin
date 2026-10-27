namespace PinPin.Core;

public enum ActionKind { Explain, Translate, Rewrite, Save, PickColor, ReplyCoach }
public enum AssetKind { Saved, Color }
public enum PersistenceState { Saving, Saved, Failed }
public enum GesturePhase { Began, Moved, Released, ModifierReleased, ClearAll, OpenSettings }
public readonly record struct ScreenPoint(double X, double Y);
public readonly record struct ScreenRect(double X, double Y, double Width, double Height)
{
    public double Right => X + Width;
    public double Bottom => Y + Height;
    public bool Contains(ScreenPoint p) => p.X >= X && p.Y >= Y && p.X < Right && p.Y < Bottom;
}
// Windows coordinates are signed global PHYSICAL pixels, with y increasing downward.
public sealed record TargetAnchor(Guid Id, ScreenPoint Point, nint Window, int ProcessId,
    ScreenRect WindowBounds, double Scale = 1);
public sealed record SourceWindowState(nint Window, bool Visible, ScreenRect Bounds);
public sealed record GestureEvent(GesturePhase Phase, TargetAnchor? Anchor, ScreenPoint Point);
public sealed record FeatureColor(byte Red, byte Green, byte Blue);
public sealed record PixelColor(byte Red, byte Green, byte Blue, string ColorSpace)
{
    public string Hex => $"#{Red:X2}{Green:X2}{Blue:X2}";
    public string Rgb => $"{Red}, {Green}, {Blue}";
}
public sealed record WheelSettings(ActionKind?[] Slots, Dictionary<ActionKind, FeatureColor> Colors, bool TriggerEnabled = true)
{
    public static WheelSettings Default => new([ActionKind.Save, ActionKind.Translate, ActionKind.Rewrite, ActionKind.Explain], []);
    public bool IsValid => Slots.Length is >= 1 and <= 8 && Slots.All(s => s is null || Enum.IsDefined(s.Value));
    public WheelSettings Copy() => new((ActionKind?[])Slots.Clone(), new(Colors), TriggerEnabled);
}
// Angles follow the Mac geometry: radians counterclockwise from +x, y upward.
public sealed record WheelSlot(int Index, double Mid, double Half);
public sealed record WheelSnapshot(TargetAnchor Anchor, WheelSettings Settings,
    IReadOnlyList<WheelSlot> Slots, IReadOnlyList<ScreenRect> Screens, double CancelRadius, double OuterRadius);
// Image points are TOP-LEFT NORMALIZED [0,1], matching the accepted Mac request contract.
// SourceCrop remains a global PHYSICAL-pixel rectangle.
public sealed record ImageEvidence(byte[] UnmarkedPng, byte[] MarkedJpeg, int Width, int Height,
    ScreenPoint PointInImage, ScreenPoint OriginalPointInImage, ScreenRect SourceCrop);

public sealed class CapturedEvidence : IDisposable
{
    public TargetAnchor Anchor { get; }
    public string SelectedText { get; }
    public string SurroundingText { get; }
    public string AppName { get; }
    public string WindowTitle { get; }
    public ImageEvidence? LocalImage { get; }
    public bool CanExpand => expand is not null;
    private readonly Func<CancellationToken, Task<ImageEvidence?>>? expand;
    private readonly Action? release;
    private readonly Func<CancellationToken,Task<ImageEvidence?>>? expandWindow;
    private int disposed;
    public CapturedEvidence(TargetAnchor anchor, string selectedText, string surroundingText,
        string appName, string windowTitle, ImageEvidence? localImage,
        Func<CancellationToken, Task<ImageEvidence?>>? expand = null, Action? release = null,
        Func<CancellationToken,Task<ImageEvidence?>>? expandWindow = null)
    { Anchor=anchor; SelectedText=selectedText; SurroundingText=surroundingText; AppName=appName;
      WindowTitle=windowTitle; LocalImage=localImage; this.expand=expand; this.release=release; this.expandWindow=expandWindow; }
    public Task<ImageEvidence?> ExpandAsync(CancellationToken cancellationToken)
    { ObjectDisposedException.ThrowIf(Volatile.Read(ref disposed)!=0,this); return expand?.Invoke(cancellationToken) ?? Task.FromResult<ImageEvidence?>(null); }
    public Task<ImageEvidence?> ExpandWindowAsync(CancellationToken token)
    { ObjectDisposedException.ThrowIf(Volatile.Read(ref disposed)!=0,this); return expandWindow?.Invoke(token) ?? Task.FromResult<ImageEvidence?>(null); }
    public void Dispose() { if (Interlocked.Exchange(ref disposed,1)==0) release?.Invoke(); }
}
public sealed record ReplyCoachingContext(string Intent, string Strategy, double? IntentProbability = null);
public sealed record PromptContext(string SelectedText, string SurroundingText, ImageEvidence? Image,
    string AppName, string WindowTitle, ReplyCoachingContext? ReplyCoaching = null);
public sealed record FollowupExchange(string Question, string Answer);
public sealed record ModelMetrics(double FirstTextMilliseconds, double CompleteMilliseconds,
    string? Model = null, bool ReasoningReturned = false);
public sealed record GenerationResult(string Text, PromptContext Context, ModelMetrics Metrics);
public sealed record SavedDescription(string Text, string[] Tags);
public readonly record struct AssetId(AssetKind Kind, Guid Id);
public sealed record AssetRecord(Guid Id, AssetKind Kind, DateTimeOffset CreatedAt, string Text,
    string[] Tags, string AppName, string WindowTitle, string? ImagePath = null,
    ScreenPoint? PointInImage = null, PixelColor? Color = null)
{ public AssetId Key => new(Kind, Id); }
public sealed record ResultState(Guid Id, ActionKind Action, TargetAnchor Anchor,
    string Text = "", bool IsLoading = true, bool IsComplete = false, string? Error = null,
    string? Question = null, bool IsAnswering = false, PixelColor? Color = null,
    AssetRecord? Saved = null, PersistenceState? ColorPersistence = null);
public abstract record AssetEdit
{
    public sealed record Delete(AssetId Key) : AssetEdit;
    public sealed record AddTag(Guid Id, string Tag) : AssetEdit;
    public sealed record RemoveTag(Guid Id, string Tag) : AssetEdit;
}
public sealed class PresentationCallbacks
{
    public Action<Guid>? ResultClosed { get; init; }
    public Action<Guid,string>? FollowupRequested { get; init; }
    public Action<AssetEdit>? AssetEdited { get; init; }
    public Func<WheelSettings,Task<bool>>? WheelSettingsChanged { get; init; }
    public Action? AssetsRequested { get; init; }
    public Action? SettingsRequested { get; init; }
    public Action? ClearRequested { get; init; }
    public Action? QuitRequested { get; init; }
    public Action<nint>? OwnWindowCreated { get; init; }
    public Action<nint>? SourceWindowWatched { get; init; }
    public Action<nint>? SourceWindowUnwatched { get; init; }
}
public interface IPinPinPresentation : IDisposable
{
    void SetCallbacks(PresentationCallbacks callbacks);
    void UpdateSourceWindow(SourceWindowState state) { }
    void UpdateWheelSettings(WheelSettings settings);
    void ShowWheel(WheelSnapshot snapshot);
    void MoveWheel(ScreenPoint point);
    void HideWheel();
    void ShowResult(ResultState state);
    void RemoveResult(Guid id);
    void ClearResults();
    void UpdateAssets(IReadOnlyList<AssetRecord> assets);
    void ShowAssets();
    void ShowSettings();
}
public interface IInputSource : IDisposable
{
    event Action<GestureEvent>? Gesture;
    IReadOnlyList<ScreenRect> Screens { get; }
    void Start();
    void SetWheelTriggerEnabled(bool enabled) { }
}
public interface ICaptureService
{ Task<CapturedEvidence> CaptureAsync(TargetAnchor anchor, CancellationToken cancellationToken); }
public interface IPixelSampler
{ Task<PixelColor> SampleAsync(TargetAnchor anchor, CancellationToken cancellationToken); }
public interface IModelService
{
    Task<GenerationResult> GenerateAsync(ActionKind action, CapturedEvidence evidence,
        Action<string> onText, CancellationToken cancellationToken);
    Task<GenerationResult> FollowupAsync(ActionKind action, PromptContext context, string previous,
        IReadOnlyList<FollowupExchange> earlier, string question, Action<string> onText,
        CancellationToken cancellationToken);
    Task<PromptContext> PrepareSaveAsync(CapturedEvidence evidence, CancellationToken cancellationToken);
    Task<SavedDescription> DescribeSavedAsync(PromptContext context, IReadOnlyList<string> existingTags, CancellationToken cancellationToken);
    Task PrewarmAsync(CancellationToken cancellationToken);
}
public interface IAssetStore
{
    Task<IReadOnlyList<AssetRecord>> LoadAsync(CancellationToken cancellationToken = default);
    Task<AssetRecord> SaveOriginalAsync(Guid id, PromptContext context, CancellationToken cancellationToken);
    Task<AssetRecord> SaveColorAsync(Guid id, PixelColor color, string appName, string windowTitle, CancellationToken cancellationToken);
    Task<AssetRecord?> EnrichAsync(Guid id, SavedDescription description, CancellationToken cancellationToken);
    Task ApplyAsync(AssetEdit edit, CancellationToken cancellationToken = default);
}
public interface IWheelSettingsStore
{
    Task<WheelSettings> LoadAsync(CancellationToken cancellationToken = default);
    Task<bool> SaveAsync(WheelSettings settings, CancellationToken cancellationToken = default);
}
