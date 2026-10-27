using PinPin.App;
using PinPin.Core;

namespace PinPin.App.Tests;

internal static class ConfigurableModelsChecks
{
    private sealed class Service(string name) : IModelService
    {
        internal readonly string Name=name;
        internal int Generates,Prewarms,Followups,Preparations,Descriptions;
        internal CancellationToken GenerateToken;
        internal Task<GenerationResult>? PendingGenerate;
        internal Task? PendingPrewarm;
        internal Action? DuringGenerate;
        internal CapturedEvidence? LastEvidence;
        internal PromptContext? LastContext;
        internal IReadOnlyList<FollowupExchange>? Earlier;
        internal IReadOnlyList<string>? Tags;
        internal string? Previous,Question;
        internal Action<string>? OnText;
        public Task PrewarmAsync(CancellationToken token)
        { Prewarms++;return PendingPrewarm ?? Task.CompletedTask; }
        public Task<GenerationResult> GenerateAsync(ActionKind action,CapturedEvidence evidence,Action<string> onText,CancellationToken token)
        { Generates++;LastEvidence=evidence;OnText=onText;GenerateToken=token;DuringGenerate?.Invoke();return PendingGenerate ?? Task.FromResult(Result(Name)); }
        public Task<GenerationResult> FollowupAsync(ActionKind action,PromptContext context,string previous,IReadOnlyList<FollowupExchange> earlier,string question,Action<string> onText,CancellationToken token)
        { Followups++;LastContext=context;Earlier=earlier;Previous=previous;Question=question;OnText=onText;return Task.FromResult(Result(Name)); }
        public Task<PromptContext> PrepareSaveAsync(CapturedEvidence evidence,CancellationToken token)
        { Preparations++;LastEvidence=evidence;return Task.FromResult(Context()); }
        public Task<SavedDescription> DescribeSavedAsync(PromptContext context,IReadOnlyList<string> existingTags,CancellationToken token)
        { Descriptions++;LastContext=context;Tags=existingTags;return Task.FromResult(new SavedDescription(Name,[])); }
    }
    private static PromptContext Context() => new("synthetic selection","",null,"Test","Window");
    private static GenerationResult Result(string text) => new(text,Context(),new(1,2));
    internal static async Task RunAsync(Action<bool,string> check)
    {
        var old=new Service("old");var next=new Service("new");var models=new ConfigurableModels(old);
        var held=new TaskCompletionSource<GenerationResult>(TaskCreationOptions.RunContinuationsAsynchronously);
        var warm=new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        old.PendingGenerate=held.Task;old.PendingPrewarm=warm.Task;
        using var lifetime=new CancellationTokenSource();
        var anchor=new TargetAnchor(Guid.NewGuid(),new(1,2),0,0,new(0,0,10,10));
        using var evidence=new CapturedEvidence(anchor,"synthetic selection","","Test","Window",null,null,null);
        Action<string> stream=_=>{};
        Task<GenerationResult> before=models.GenerateAsync(ActionKind.Explain,evidence,stream,lifetime.Token);
        Task beforeWarm=models.PrewarmAsync(lifetime.Token);
        models.Replace(next);
        check(ReferenceEquals(before,held.Task) && ReferenceEquals(beforeWarm,warm.Task),"wrapper returns original in-flight tasks without an extra queue");
        check(old.Generates==1 && old.Prewarms==1 && old.GenerateToken==lifetime.Token && !old.GenerateToken.IsCancellationRequested && !before.IsCompleted,"switch leaves original calls running without cancellation");
        check(ReferenceEquals(old.LastEvidence,evidence) && ReferenceEquals(old.OnText,stream),"original call receives same evidence and callback");
        var after=await models.GenerateAsync(ActionKind.Rewrite,evidence,stream,lifetime.Token);
        check(after.Text=="new" && next.Generates==1 && old.Generates==1,"new call uses newly configured service");
        held.SetResult(Result("old completed"));warm.SetResult();
        check((await before).Text=="old completed","original response remains deliverable after switch");await beforeWarm;
        var context=Context();IReadOnlyList<FollowupExchange> earlier=[];IReadOnlyList<string> tags=["tag"];
        await models.FollowupAsync(ActionKind.Explain,context,"previous",earlier,"question",stream,lifetime.Token);
        await models.PrepareSaveAsync(evidence,lifetime.Token);await models.DescribeSavedAsync(context,tags,lifetime.Token);
        check(next.Followups==1 && next.Preparations==1 && next.Descriptions==1 && ReferenceEquals(next.LastContext,context) && ReferenceEquals(next.Earlier,earlier) && ReferenceEquals(next.Tags,tags) && next.Previous=="previous" && next.Question=="question","all model methods forward to one current service with original arguments");
        var third=new Service("third");next.DuringGenerate=()=>models.Replace(third);
        check((await models.GenerateAsync(ActionKind.Explain,evidence,stream,lifetime.Token)).Text=="new","call captures a single instance even when replacement happens inside that call");
        check((await models.GenerateAsync(ActionKind.Explain,evidence,stream,lifetime.Token)).Text=="third","following call observes replacement published by prior call");
        var offline=new ConfigurableModels(new UnconfiguredModels());
        check(!offline.IsConfigured,"unconfigured state is observable without a provider probe");
        var saved=await offline.PrepareSaveAsync(evidence,default);await offline.PrewarmAsync(default);
        check(saved.SelectedText==evidence.SelectedText,"unconfigured mode still prepares local original content");
        offline.Replace(third);check(offline.IsConfigured,"configuration presence changes immediately without network validation");
    }
}
