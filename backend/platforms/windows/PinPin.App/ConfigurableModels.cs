using PinPin.Core;

namespace PinPin.App;

// Each call owns one service snapshot. Reconfiguration does not cancel or dispose earlier calls.
internal sealed class ConfigurableModels(IModelService initial) : IModelService
{
    private IModelService current=initial ?? throw new ArgumentNullException(nameof(initial));
    internal bool IsConfigured => Volatile.Read(ref current) is not UnconfiguredModels;
    internal void Replace(IModelService next)
    { ArgumentNullException.ThrowIfNull(next); Interlocked.Exchange(ref current,next); }
    public Task PrewarmAsync(CancellationToken token)
    { var service=Volatile.Read(ref current); return service.PrewarmAsync(token); }
    public Task<GenerationResult> GenerateAsync(ActionKind action,CapturedEvidence evidence,Action<string> onText,CancellationToken token)
    { var service=Volatile.Read(ref current); return service.GenerateAsync(action,evidence,onText,token); }
    public Task<GenerationResult> FollowupAsync(ActionKind action,PromptContext context,string previous,
        IReadOnlyList<FollowupExchange> earlier,string question,Action<string> onText,CancellationToken token)
    { var service=Volatile.Read(ref current); return service.FollowupAsync(action,context,previous,earlier,question,onText,token); }
    public Task<PromptContext> PrepareSaveAsync(CapturedEvidence evidence,CancellationToken token)
    { var service=Volatile.Read(ref current); return service.PrepareSaveAsync(evidence,token); }
    public Task<SavedDescription> DescribeSavedAsync(PromptContext context,IReadOnlyList<string> existingTags,CancellationToken token)
    { var service=Volatile.Read(ref current); return service.DescribeSavedAsync(context,existingTags,token); }
}
