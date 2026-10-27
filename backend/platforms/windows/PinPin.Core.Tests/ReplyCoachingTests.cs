using System.Net;
using System.Text.Json;
using PinPin.Core;

namespace PinPin.Core.Tests;

internal static class ReplyCoachingTests
{
    private static readonly string[] Intents=["ask_information","request_action","share_update","seek_support","set_boundary","disagreement","unclear","not_chat"];
    private static readonly string[] Strategies=["承接","降压","调侃","轻推","约见","澄清","收线"];
    private static string Judgment(string intent="seek_support",string strategy="承接",string model="jev-1.14",double intentProbability=1,double? confidence=null) => JsonSerializer.Serialize(new
    {
        model,answers=new { intent=Choice(intent,Intents,intentProbability,confidence),reply_strategy=Choice(strategy,Strategies) }
    });
    private static object Choice(string selected,string[] keys,double probability=1,double? confidence=null)
    {
        var choice=new Dictionary<string,object> { ["type"]="choice",["choice"]=selected,
            ["probabilities"]=keys.ToDictionary(x=>x,x=>x==selected ? probability : (1-probability)/(keys.Length-1)) };
        if(confidence is {} value) choice["confidence"]=value;
        return choice;
    }
    private static GatewayModelService Service(HttpClient client,TimeSpan? total=null) => new(client,new(new("https://reply.invalid/ping"),"synthetic-token")
    { DecisionTimeout=TimeSpan.FromMilliseconds(1),TotalTimeout=total ?? TimeSpan.FromSeconds(20) });
    private static CapturedEvidence Capture(Func<CancellationToken,Task<ImageEvidence?>> window,Action? release=null,
        Func<CancellationToken,Task<ImageEvidence?>>? local=null) =>
        new(Fixtures.Anchor(),"selected fragment","","Public fixture","Visible chat",Fixtures.Image(),local,release,window);
    private static string Answer(string reply) => "对方意图：继续这段对话\n建议回复："+reply;
    private static string FormattedAnswer(string reply,int percent) => $"对方意图：继续这段对话（{percent}%）\n建议回复：{reply}";
    private static async Task<string> RenderAnswerAsync(string text,double? probability)
    {
        using var handler=new FakeHttpMessageHandler((_,_)=>Task.FromResult(GatewayTests.Response(GatewayTests.Sse(text))));
        using var client=new HttpClient(handler);var context=new PromptContext("","",Fixtures.Image(),"Fixture","Chat",new("seek_support","承接",probability));
        var result=await Service(client).FollowupAsync(ActionKind.ReplyCoach,context,"",[],"自然一点",_=>{},default);
        return result.Text;
    }
    internal static void Register(List<(string,Func<Task>)> tests)
    {
        tests.Add(("reply-coach.intent-probability-is-exact-selected-value-not-confidence",async () =>
        {
            foreach(var probability in new[]{.834321,.625,.125})
            {
                using var handler=new FakeHttpMessageHandler((sent,_)=>Task.FromResult(sent.Path.EndsWith("decision")
                    ? GatewayTests.Response(Judgment(intentProbability:probability,confidence:probability==.834321 ? .12 : null),false)
                    : GatewayTests.Response(GatewayTests.Sse(Answer("好的")))));
                using var client=new HttpClient(handler);using var evidence=Capture(_=>Task.FromResult<ImageEvidence?>(Fixtures.Image()));
                var result=await Service(client).GenerateAsync(ActionKind.ReplyCoach,evidence,_=>{},default);
                var judgment=result.Context.ReplyCoaching!;
                Check.Equal("seek_support",judgment.Intent);Check.Equal("承接",judgment.Strategy);
                Check.Equal<double?>(probability,judgment.IntentProbability);
            }
            Check.Equal<double?>(null,new ReplyCoachingContext("unclear","澄清").IntentProbability);
        }));
        tests.Add(("reply-coach.percentage-rounds-half-away-from-zero-and-keeps-unknown",async () =>
        {
            foreach(var (probability,percent) in new[]{(0d,0),(.0049,0),(.005,1),(.1249,12),(.125,13),(.624999,62),(.625,63),(.9949,99),(.995,100),(1d,100)})
                Check.Equal(FormattedAnswer("好的",percent),await RenderAnswerAsync(Answer("好的"),probability));
            Check.Equal(Answer("好的"),await RenderAnswerAsync(Answer("好的"),null));
            Check.Equal(Answer("好的"),await RenderAnswerAsync("对方意图：继续这段对话（99%）\n建议回复：好的",null));
            Check.Equal("对方意图：继续这段对话（63%）",await RenderAnswerAsync("对方意图：继续这段对话",.625));
            foreach(var invalid in new[]{double.NaN,double.PositiveInfinity,-.1,1.1})
                Check.Equal(Answer("好的"),await RenderAnswerAsync(Answer("好的"),invalid));
        }));
        tests.Add(("reply-coach.chunked-stream-inserts-jev-percentage-before-reply-and-final-matches",async () =>
        {
            const string raw="对方意图：寻求支持（99%）\r\n建议回复：我在，慢慢说。";
            using var handler=new FakeHttpMessageHandler((sent,_)=>Task.FromResult(sent.Path.EndsWith("decision")
                ? GatewayTests.Response(Judgment(intentProbability:.834321,confidence:.12),false)
                : GatewayTests.Response(GatewayTests.Sse(raw.Select(x=>x.ToString()).ToArray()))));
            using var client=new HttpClient(handler);using var evidence=Capture(_=>Task.FromResult<ImageEvidence?>(Fixtures.Image()));
            var streamed=new List<string>();var result=await Service(client).GenerateAsync(ActionKind.ReplyCoach,evidence,streamed.Add,default);
            Check.True(streamed.Count>2);Check.Equal("对方意图：寻求支持（83%）\n建议回复：我在，慢慢说。",result.Text);
            Check.Equal(result.Text,streamed.Last());Check.True(result.Metrics.FirstTextMilliseconds>=0);
            foreach(var text in streamed)
            {
                Check.True(text.StartsWith("对方意图：寻求支持（83%）\n",StringComparison.Ordinal));
                Check.True(!text.Contains("99%") && !text.Contains("12%"));
            }
            for(int i=1;i<streamed.Count;i++) Check.True(streamed[i].StartsWith(streamed[i-1],StringComparison.Ordinal));
        }));
        tests.Add(("reply-coach.unreadable-sentinel-never-decorated-and-keeps-original-error",async () =>
        {
            using var handler=new FakeHttpMessageHandler((_,_)=>Task.FromResult(GatewayTests.Response(GatewayTests.Sse("无","法读取","所指内容"))));
            using var client=new HttpClient(handler);var context=new PromptContext("","",Fixtures.Image(),"Fixture","Chat",new("unclear","澄清",.625));
            var streamed=new List<string>();await Check.ThrowsAsync(()=>Service(client).FollowupAsync(ActionKind.ReplyCoach,context,"",[],"自然一点",streamed.Add,default));
            Check.Equal("无法读取所指内容",streamed.Last());Check.True(streamed.All(x=>"无法读取所指内容".StartsWith(x,StringComparison.Ordinal)));
            Check.Equal(1,handler.Requests.Count);
        }));
        tests.Add(("reply-coach.whitespace-deltas-do-not-emit-or-count-as-first-visible-text",async () =>
        {
            Check.Equal(FormattedAnswer("我在。",63),await RenderAnswerAsync(" \t"+Answer("我在。"),.625));
            using var handler=new FakeHttpMessageHandler((_,_)=>Task.FromResult(GatewayTests.Response(GatewayTests.Sse(" \t\n","无法读取所指内容"))));
            using var client=new HttpClient(handler);var context=new PromptContext("","",Fixtures.Image(),"Fixture","Chat",new("unclear","澄清",.625));
            var streamed=new List<string>();await Check.ThrowsAsync(()=>Service(client).FollowupAsync(ActionKind.ReplyCoach,context,"",[],"自然一点",streamed.Add,default));
            Check.True(streamed.Count>0 && streamed.All(x=>!string.IsNullOrWhiteSpace(x)));
            Check.Equal("无法读取所指内容",streamed.Last().Trim());
        }));
        tests.Add(("reply-coach.same-frame-two-questions-one-jev-one-ds-unmarked",async () =>
        {
            int expanded=0,released=0,local=0;
            var full=Fixtures.Image() with { UnmarkedPng=[9,8,7],PointInImage=new(.5,.5),OriginalPointInImage=new(.3,.7),SourceCrop=new(0,0,1300,900),Width=1300,Height=900 };
            using var handler=new FakeHttpMessageHandler((sent,_)=>
            {
                using var json=JsonDocument.Parse(sent.Body!);var body=json.RootElement;
                if(sent.Path.EndsWith("decision"))
                {
                    Check.True(body.GetProperty("questions").EnumerateObject().Select(x=>x.Name).ToHashSet().SetEquals(new[]{"intent","reply_strategy"}));
                    foreach(var name in new[]{"intent","reply_strategy"})
                    {
                        string instructions=body.GetProperty("questions").GetProperty(name).GetProperty("instructions").GetString()!;
                        Check.True(instructions.Contains("main message area of the currently open conversation"));
                        Check.True(instructions.Contains("other participant's latest message"));
                        Check.True(instructions.Contains("Ignore sidebar conversation lists, other conversations and toolbars."));
                        Check.True(instructions.Contains("do not attribute the user's outgoing messages to the other participant"));
                        Check.True(instructions.Contains("choose unclear and keep those details unknown"));
                    }
                    Check.Equal(Convert.ToBase64String(full.UnmarkedPng),body.GetProperty("assets").GetProperty("screen").GetProperty("data_base64").GetString());
                    Check.Equal("png",body.GetProperty("assets").GetProperty("screen").GetProperty("format").GetString());
                    return Task.FromResult(GatewayTests.Response(Judgment(),false));
                }
                Check.Equal(1600,body.GetProperty("max_tokens").GetInt32());Check.Equal("enabled",body.GetProperty("thinking").GetProperty("type").GetString());
                Check.Equal("low",body.GetProperty("reasoning_effort").GetString());
                string system=body.GetProperty("messages")[0].GetProperty("content").GetString()!;
                Check.True(system.Contains("每次回答及追问都只输出以下两行"));Check.True(system.Contains("意图行不输出概率、百分比或置信度数值"));
                Check.True(system.Contains("建议回复：一条可直接复制的自然回复"));
                Check.True(system.Contains("从当前打开聊天的主体消息区域理解最近对方发言及相关可见上下文"));
                Check.True(system.Contains("无法辨认双方或当前对方消息时按unclear处理，并保留未知"));
                var user=body.GetProperty("messages")[1].GetProperty("content");
                Check.Equal("data:image/png;base64,"+Convert.ToBase64String(full.UnmarkedPng),user[1].GetProperty("image_url").GetProperty("url").GetString());
                using var input=JsonDocument.Parse(user[0].GetProperty("text").GetString()!);Check.Equal("",input.RootElement.GetProperty("evidence").GetProperty("text").GetString());
                return Task.FromResult(GatewayTests.Response(GatewayTests.Sse("对方意图：寻求支持","\n建议回复：听起来你最近挺累的，想聊聊吗？")));
            });
            using var client=new HttpClient(handler);using var evidence=Capture(_=> { expanded++;return Task.FromResult<ImageEvidence?>(full); },()=>released++,
                _=> { local++;return Task.FromResult<ImageEvidence?>(Fixtures.Image()); });
            var result=await Service(client).GenerateAsync(ActionKind.ReplyCoach,evidence,_=>{},default);
            Check.Equal(1,expanded);Check.Equal(0,local);Check.Equal(1,released);Check.Equal(2,handler.Requests.Count);
            Check.Equal("seek_support",result.Context.ReplyCoaching!.Intent);Check.Equal<double?>(1,result.Context.ReplyCoaching.IntentProbability);
            Check.Equal("对方意图：寻求支持（100%）\n建议回复：听起来你最近挺累的，想聊聊吗？",result.Text);
            Check.Equal(new ScreenPoint(.3,.7),result.Context.Image!.PointInImage);Check.Equal(new ScreenRect(0,0,1300,900),result.Context.Image.SourceCrop);
        }));
        tests.Add(("reply-coach.selection-explain-keeps-local-window-callback-unused",async () =>
        {
            int local=0,window=0;
            using var handler=new FakeHttpMessageHandler((_,_)=>Task.FromResult(GatewayTests.Response(GatewayTests.Sse("解释选区"))));
            using var client=new HttpClient(handler);using var evidence=Capture(_=> { window++;return Task.FromResult<ImageEvidence?>(Fixtures.Image()); },
                local:_=> { local++;return Task.FromResult<ImageEvidence?>(Fixtures.Image()); });
            var result=await Service(client).GenerateAsync(ActionKind.Explain,evidence,_=>{},default);
            Check.Equal(Fixtures.Image().SourceCrop,result.Context.Image!.SourceCrop);
            Check.Equal(1,local);Check.Equal(0,window);Check.Equal(1,handler.Requests.Count);
        }));
        tests.Add(("reply-coach.mandatory-jev-errors-never-fallback",async () =>
        {
            foreach(var response in new[]{Judgment(model:"wrong"),Judgment().Replace("\"choice\":\"seek_support\"","\"choice\":\"unclear\""),
                Judgment().Replace("\"seek_support\":1","\"seek_support\":true"),Judgment().Replace("\"seek_support\":1","\"seek_support\":0.8"),
                Judgment(intentProbability:.1249),Judgment(confidence:1.1),Judgment().Replace("\"seek_support\":1","\"seek_support\":-1"),"{}"})
            {
                using var handler=new FakeHttpMessageHandler((_,_)=>Task.FromResult(GatewayTests.Response(response,false)));
                using var client=new HttpClient(handler);using var evidence=Capture(_=>Task.FromResult<ImageEvidence?>(Fixtures.Image()));
                await Check.ThrowsAsync(()=>Service(client).GenerateAsync(ActionKind.ReplyCoach,evidence,_=>throw new Exception("No text"),default));
                Check.Equal(1,handler.Requests.Count);Check.True(handler.Requests[0].Path.EndsWith("decision"));
            }
            foreach(var status in new[]{HttpStatusCode.Unauthorized,HttpStatusCode.Forbidden,HttpStatusCode.ServiceUnavailable})
            {
                using var handler=new FakeHttpMessageHandler((_,_)=>Task.FromResult(new HttpResponseMessage(status)));
                using var client=new HttpClient(handler);using var evidence=Capture(_=>Task.FromResult<ImageEvidence?>(Fixtures.Image()));
                await Check.ThrowsAsync(()=>Service(client).GenerateAsync(ActionKind.ReplyCoach,evidence,_=>{},default));Check.Equal(1,handler.Requests.Count);
            }
        }));
        tests.Add(("reply-coach.not-chat-no-ds-unclear-may-generate",async () =>
        {
            foreach(var intent in new[]{"not_chat","unclear"})
            {
                using var handler=new FakeHttpMessageHandler((sent,_)=>Task.FromResult(sent.Path.EndsWith("decision") ? GatewayTests.Response(Judgment(intent,"澄清"),false) : GatewayTests.Response(GatewayTests.Sse("还不确定，可先澄清。"))));
                using var client=new HttpClient(handler);using var evidence=Capture(_=>Task.FromResult<ImageEvidence?>(Fixtures.Image()));
                if(intent=="not_chat") { await Check.ThrowsAsync(()=>Service(client).GenerateAsync(ActionKind.ReplyCoach,evidence,_=>{},default));Check.Equal(1,handler.Requests.Count); }
                else { await Service(client).GenerateAsync(ActionKind.ReplyCoach,evidence,_=>{},default);Check.Equal(2,handler.Requests.Count); }
            }
        }));
        tests.Add(("reply-coach.cancelled-expansion-no-requests-releases-once",async () =>
        {
            int released=0;using var cancel=new CancellationTokenSource();
            using var handler=new FakeHttpMessageHandler((_,_)=>throw new Exception("No request"));using var client=new HttpClient(handler);
            using var evidence=Capture(_=> { cancel.Cancel();return Task.FromResult<ImageEvidence?>(Fixtures.Image()); },()=>released++);
            await Check.ThrowsAsync(()=>Service(client).GenerateAsync(ActionKind.ReplyCoach,evidence,_=>{},cancel.Token));
            Check.Equal(0,handler.Requests.Count);Check.Equal(1,released);
        }));
        tests.Add(("reply-coach.cancelled-jev-no-ds",async () =>
        {
            using var cancel=new CancellationTokenSource();using var handler=new FakeHttpMessageHandler(async (_,token)=>
            { cancel.Cancel();await Task.Delay(100,token);return GatewayTests.Response(Judgment(),false); });
            using var client=new HttpClient(handler);using var evidence=Capture(_=>Task.FromResult<ImageEvidence?>(Fixtures.Image()));
            await Check.ThrowsAsync(()=>Service(client).GenerateAsync(ActionKind.ReplyCoach,evidence,_=>{},cancel.Token));Check.Equal(1,handler.Requests.Count);
        }));
        tests.Add(("reply-coach.followup-keeps-context-and-no-jev",async () =>
        {
            using var handler=new FakeHttpMessageHandler((sent,_)=>
            {
                Check.True(sent.Path.EndsWith("explanation"));using var body=JsonDocument.Parse(sent.Body!);
                using var input=JsonDocument.Parse(body.RootElement.GetProperty("messages")[1].GetProperty("content")[0].GetProperty("text").GetString()!);
                Check.Equal("set_boundary",input.RootElement.GetProperty("reply_coaching").GetProperty("intent").GetString());
                Check.Equal("previous A",input.RootElement.GetProperty("previous_result").GetString());
                Check.Equal(2,input.RootElement.GetProperty("earlier").GetArrayLength());
                return Task.FromResult(GatewayTests.Response(GatewayTests.Sse("对方意图：暂时不想继续聊\n建议回复：好，那你先忙。")));
            });
            using var client=new HttpClient(handler);var context=new PromptContext("","",Fixtures.Image(),"Fixture","Chat",new("set_boundary","收线"));
            var result=await Service(client).FollowupAsync(ActionKind.ReplyCoach,context,"previous A",Enumerable.Range(0,4).Select(x=>new FollowupExchange("A"+x,"answer")).ToArray(),"自然一点",_=>{},default);
            Check.Equal(1,handler.Requests.Count);Check.Equal(context,result.Context);
            Check.Equal("对方意图：暂时不想继续聊\n建议回复：好，那你先忙。",result.Text);
        }));
        tests.Add(("reply-coach.coordinator-initial-followup-image-point-and-session-identity",async () =>
        {
            using var temp=new Temp();var presentation=new FakePresentation();var capture=new FakeCapture();
            var a=Fixtures.Anchor();var b=Fixtures.Anchor();int expanded=0,released=0;
            var images=new Dictionary<Guid,ImageEvidence>
            {
                [a.Id]=Fixtures.Image() with { UnmarkedPng=[9,8,7],MarkedJpeg=[0xff,0xd8,1],PointInImage=new(.01,.02),OriginalPointInImage=new(.3,.7) },
                [b.Id]=Fixtures.Image() with { UnmarkedPng=[6,5,4],MarkedJpeg=[0xff,0xd8,2],PointInImage=new(.03,.04),OriginalPointInImage=new(.8,.2) }
            };
            var aImage="data:image/png;base64,"+Convert.ToBase64String(images[a.Id].UnmarkedPng);
            var bImage="data:image/png;base64,"+Convert.ToBase64String(images[b.Id].UnmarkedPng);
            capture.Capture=(anchor,_)=>Task.FromResult(new CapturedEvidence(anchor,"selected fragment","","Public fixture","Chat",
                Fixtures.Image(),release:()=>Interlocked.Increment(ref released),expandWindow:_=>
                { Interlocked.Increment(ref expanded);return Task.FromResult<ImageEvidence?>(images[anchor.Id]); }));
            var answers=new System.Collections.Concurrent.ConcurrentQueue<(string Image,JsonElement Input)>();
            using var handler=new FakeHttpMessageHandler((sent,_)=>
            {
                using var body=JsonDocument.Parse(sent.Body!);var root=body.RootElement;
                if(sent.Path.EndsWith("decision"))
                {
                    var data=root.GetProperty("assets").GetProperty("screen").GetProperty("data_base64").GetString();
                    bool ownA=data==Convert.ToBase64String(images[a.Id].UnmarkedPng);
                    Check.True(ownA || data==Convert.ToBase64String(images[b.Id].UnmarkedPng));
                    return Task.FromResult(GatewayTests.Response(ownA ? Judgment(intentProbability:.834321) : Judgment("set_boundary","收线",intentProbability:.625),false));
                }
                Check.True(sent.Path.EndsWith("explanation"));var content=root.GetProperty("messages")[1].GetProperty("content");
                var image=content[1].GetProperty("image_url").GetProperty("url").GetString()!;
                using var input=JsonDocument.Parse(content[0].GetProperty("text").GetString()!);
                answers.Enqueue((image,input.RootElement.Clone()));
                string tag=image==aImage ? "A" : image==bImage ? "B" : throw new Exception("Unexpected session image");
                string question=input.RootElement.GetProperty("question").GetString()!;
                return Task.FromResult(GatewayTests.Response(GatewayTests.Sse(Answer(question.Length==0 ? "initial "+tag : "answer "+question))));
            });
            using var client=new HttpClient(handler);
            using var coordinator=new ActionCoordinator(presentation,capture,new FakePixel(),Service(client),new JsonAssetStore(temp.Path),
                new JsonWheelSettingsStore(Path.Combine(temp.Path,"wheel.json")),()=>[new(0,0,1000,1000)]);
            await Task.WhenAll(coordinator.ExecuteAsync(ActionKind.ReplyCoach,a),coordinator.ExecuteAsync(ActionKind.ReplyCoach,b));
            Check.Equal(FormattedAnswer("initial A",83),presentation.Results[a.Id].Text);Check.Equal(FormattedAnswer("initial B",63),presentation.Results[b.Id].Text);
            await Task.WhenAll(coordinator.FollowupAsync(a.Id,"A1"),coordinator.FollowupAsync(b.Id,"B1"));
            Check.Equal(FormattedAnswer("answer A1",83),presentation.Results[a.Id].Text);Check.Equal(FormattedAnswer("answer B1",63),presentation.Results[b.Id].Text);
            await coordinator.FollowupAsync(a.Id,"A2");Check.Equal(FormattedAnswer("answer A2",83),presentation.Results[a.Id].Text);
            Check.Equal(2,capture.Calls);Check.Equal(2,expanded);Check.Equal(2,released);
            Check.Equal(2,handler.Requests.Count(x=>x.Path.EndsWith("decision")));Check.Equal(5,answers.Count);
            foreach(var (image,input) in answers)
            {
                bool ownA=image==aImage;var original=images[ownA ? a.Id : b.Id];string tag=ownA ? "A" : "B";
                var point=input.GetProperty("evidence").GetProperty("point_in_image");
                Check.Equal(original.OriginalPointInImage.X,point.GetProperty("x").GetDouble());
                Check.Equal(original.OriginalPointInImage.Y,point.GetProperty("y").GetDouble());
                Check.Equal(ownA ? "seek_support" : "set_boundary",input.GetProperty("reply_coaching").GetProperty("intent").GetString());
                Check.Equal(ownA ? "承接" : "收线",input.GetProperty("reply_coaching").GetProperty("reply_strategy").GetString());
                string question=input.GetProperty("question").GetString()!;var earlier=input.GetProperty("earlier");
                if(question.Length==0) { Check.Equal("",input.GetProperty("previous_result").GetString());Check.Equal(0,earlier.GetArrayLength()); }
                else if(question==tag+"1") { Check.Equal(FormattedAnswer("initial "+tag,ownA ? 83 : 63),input.GetProperty("previous_result").GetString());Check.Equal(0,earlier.GetArrayLength()); }
                else
                {
                    Check.Equal("A2",question);Check.Equal(FormattedAnswer("answer A1",83),input.GetProperty("previous_result").GetString());Check.Equal(1,earlier.GetArrayLength());
                    Check.Equal("A1",earlier[0].GetProperty("question").GetString());Check.Equal(FormattedAnswer("answer A1",83),earlier[0].GetProperty("answer").GetString());
                }
            }
        }));
        tests.Add(("reply-coach.coordinator-retains-one-encoding-old-action-trimming-unchanged",async () =>
        {
            foreach(var (action,png) in new[]{(ActionKind.ReplyCoach,true),(ActionKind.ReplyCoach,false),
                (ActionKind.Explain,true),(ActionKind.Translate,true),(ActionKind.Rewrite,true),(ActionKind.Save,true)})
            {
                using var rig=new Rig();var anchor=Fixtures.Anchor();
                var image=Fixtures.Image() with { UnmarkedPng=png ? new byte[]{9,8,7} : [],PointInImage=new(.1,.2),OriginalPointInImage=new(.7,.8) };
                var context=new PromptContext("","",image,"Fixture","Chat",action==ActionKind.ReplyCoach ? new("seek_support","承接") : null);
                rig.Models.Generate=(_,_,_,_)=>Task.FromResult(new GenerationResult("initial",context,new(1,2)));
                rig.Models.Prepare=(_,_)=>Task.FromResult(context);
                PromptContext? kept=null;
                rig.Models.Followup=call=> { kept=call.Context;return Task.FromResult(new GenerationResult("followup",call.Context,new(1,2))); };
                await rig.Coordinator.ExecuteAsync(action,anchor);await rig.Coordinator.FollowupAsync(anchor.Id,"question");
                Check.True(kept?.Image is not null);var retained=kept!.Image!;
                if(action==ActionKind.ReplyCoach && png)
                {
                    Check.True(ReferenceEquals(image.UnmarkedPng,retained.UnmarkedPng));Check.Equal(0,retained.MarkedJpeg.Length);
                    Check.Equal(image.OriginalPointInImage,retained.PointInImage);
                }
                else
                {
                    Check.Equal(0,retained.UnmarkedPng.Length);Check.True(ReferenceEquals(image.MarkedJpeg,retained.MarkedJpeg));
                    Check.Equal(image.PointInImage,retained.PointInImage);
                }
            }
            using var color=new Rig();int colorFollowups=0;var colorAnchor=Fixtures.Anchor();
            color.Models.Followup=call=> { colorFollowups++;return Task.FromResult(new GenerationResult("unexpected",call.Context,new(1,2))); };
            await color.Coordinator.ExecuteAsync(ActionKind.PickColor,colorAnchor);await color.Coordinator.FollowupAsync(colorAnchor.Id,"question");
            await color.Coordinator.DrainAsync();Check.Equal(0,colorFollowups);Check.Equal(0,color.Capture.Calls);
        }));
    }
}
