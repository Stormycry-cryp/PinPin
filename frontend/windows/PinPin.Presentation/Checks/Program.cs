using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Threading;
using PinPin.Core;
using PinPin.Presentation.Models;

namespace PinPin.Presentation.Checks;

internal static class Program
{
    internal static int Checks;
    internal static readonly List<object> Evidence = [];
    internal static string Output = "";
    internal static readonly Guid SavedId = Guid.Parse("11111111-1111-1111-1111-111111111111");
    internal static TargetAnchor Anchor(Guid id, double x = 500, double y = 500) => new(id, new(x, y), 0, 1, new(0, 0, 1200, 800));
    internal static AssetRecord Saved(string text = "Café ＡＢ：完整收藏内容") => new(SavedId, AssetKind.Saved,
        DateTimeOffset.Parse("2026-10-23T10:00:00+08:00"), text, ["工作", "学习"], "测试来源", "测试窗口");
    internal static AssetRecord Color() => new(SavedId, AssetKind.Color, DateTimeOffset.Parse("2026-10-23T10:00:01+08:00"),
        "", [], "测试来源", "取色样本", Color: new(46, 94, 158, "Windows GDI SDR RGB"));
    internal static void Check(bool condition, string message)
    { Checks++; if (!condition) throw new InvalidOperationException("FAIL: " + message); }
    internal static void Passed(string name) { Console.WriteLine("PASS " + name); }
    internal static async Task Idle() => await Dispatcher.CurrentDispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);

    [STAThread]
    public static int Main(string[] args)
    {
        int outputIndex = Array.IndexOf(args, "--output");
        if (outputIndex < 0 || outputIndex + 1 >= args.Length || !Path.IsPathFullyQualified(args[outputIndex + 1]))
        { Console.Error.WriteLine("Usage: PinPin.Presentation.Checks --output <absolute isolated directory> [--render] [--native-measure] [--hidden-failure-check]"); return 2; }
        Output = args[outputIndex + 1]; Directory.CreateDirectory(Output);
        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        app.Dispatcher.BeginInvoke(new Action(async () =>
        {
            int exit = 0; string? error = null;
            try
            {
                if (args.Contains("--hidden-failure-check")) await HiddenFailureChecks.Run();
                else if (args.Contains("--dpi-diagnostics")) DpiDiagnostics.Run();
                else
                {
                    ModelChecks(); await SettingsChecks(); await ResultDispatchChecks.RunOffscreen();
                    using (var presentation = new WindowsPresentation(app.Dispatcher))
                    {
                        Check(presentation.GetDiagnostics().OwnedWindows == 0, "构造不创建 HWND");
                        Check(presentation.GetDiagnostics().ActiveUiTimers == 0, "构造没有常驻计时器");
                    }
                    Passed("构造与无窗口生命周期");
                    if (args.Contains("--render")) await RenderChecks.Run();
                    if (args.Contains("--native-measure")) await NativeChecks.Run();
                }
                Console.WriteLine($"PASS {Checks} checks");
            }
            catch (Exception exception) { exit = 1; error = exception.ToString(); Console.Error.WriteLine(error); }
            var report = new { Checks, ExitCode = exit, Error = error, Environment.OSVersion, Environment.ProcessorCount,
                Runtime = Environment.Version.ToString(), NativeWindowsExplicitlyRequested = args.Contains("--native-measure") || args.Contains("--hidden-failure-check"), Evidence,
                Limits = new[] { "离屏渲染不等同桌面合成或鼠标验收", "测试仅使用合成数据，不验证真实模型或用户资产", "多屏、混合DPI与遮挡层级需要单独实机验收" } };
            File.WriteAllText(Path.Combine(Output, "presentation-report.json"), JsonSerializer.Serialize(report, new JsonSerializerOptions { WriteIndented = true }));
            app.Shutdown(exit);
        }));
        return app.Run();
    }

    private static void ModelChecks()
    {
        var id = Guid.NewGuid(); var initial = new ResultState(id, ActionKind.Explain, Anchor(id), "完整答案", false, true);
        var result = new ResultModel(initial) { Mode = CardMode.Dialog, Draft = "继续解释" };
        string? sent = null;
        Check(result.Submit((_, question) => sent = question), "完整结果可以追问");
        Check(sent == "继续解释" && result.RequestPending && result.Draft == "", "追问提交保留待恢复问题并停用输入");
        result.Mode = CardMode.Hidden;
        result.Apply(initial with { Text = "部分", IsAnswering = true, IsComplete = false });
        result.Apply(initial with { Text = "", Error = "网络失败", IsAnswering = false });
        Check(result.DisplayText == "完整答案" && result.Draft == "继续解释", "隐藏时追问失败恢复正文和独立草稿");
        Check(result.CanFollowup, "失败恢复后可继续追问");
        var other = new ResultModel(new(Guid.NewGuid(), ActionKind.Translate, Anchor(Guid.NewGuid()), "另一份答案", false, true)) { Draft = "另一草稿" };
        Check(other.DisplayText == "另一份答案" && other.Draft == "另一草稿", "不同ID的正文草稿互不影响");
        var sampled = new ResultModel(new(Guid.NewGuid(), ActionKind.PickColor, Anchor(Guid.NewGuid()), IsLoading: false,
            IsComplete: true, Color: Color().Color, ColorPersistence: PersistenceState.Failed));
        Check(sampled.State.Color?.Hex == "#2E5E9E" && !sampled.CanFollowup && !sampled.IsFailure, "颜色保存失败保留色值且没有AI追问");

        var coachId = Guid.NewGuid();
        var coach = new ResultModel(new(coachId, ActionKind.ReplyCoach, Anchor(coachId))) { Mode = CardMode.Dialog };
        coach.Apply(coach.State with { Text = "对方想确认进度。" });
        Check(coach.DisplayText == "对方想确认进度。", "嘴替复用流式结果");
        coach.Apply(coach.State with { Text = "对方想确认进度。\n\n可以回复：我下午确认后回复你。", IsLoading = false, IsComplete = true });
        string coachText = coach.DisplayText;
        coach.Draft = "语气更自然一点"; string? coachSent = null;
        Check(coach.CanFollowup && coachSent is null, "嘴替允许追问且草稿不会自动提交");
        Check(coach.Submit((_, question) => coachSent = question) && coachSent == "语气更自然一点", "明确提交才发送嘴替追问");
        coach.Apply(coach.State with { Error = "请稍后重试", Text = "", IsAnswering = false });
        Check(coach.DisplayText == coachText && coach.Draft == "语气更自然一点", "嘴替追问失败恢复完整建议与问题");

        var assets = new AssetModel(); assets.Receive([Saved(), Color()]);
        Check(assets.Records.Count == 2 && assets.Records.Select(x => x.Key).Distinct().Count() == 2, "同UUID按资产类型隔离");
        assets.Search("cafe ab"); Check(assets.Results.Count == 1 && assets.Results[0].Kind == AssetKind.Saved, "标签与正文折叠搜索");
        assets.Search("#2e5e9e"); Check(assets.Results.Single().Kind == AssetKind.Color, "HEX搜索");
        assets.Search(""); assets.SelectTag("工作"); assets.SelectScope(AssetScope.Color);
        Check(assets.Tag is null && assets.Results.Single().Kind == AssetKind.Color, "取色类型清理收藏标签筛选");
        assets.SelectScope(AssetScope.All);
        var edits = new List<AssetEdit>(); assets.Edit = edits.Add;
        assets.AddTag(SavedId, "新增A"); assets.AddTag(SavedId, "新增B"); assets.RemoveTag(SavedId, "工作");
        Check(edits.Count == 3 && edits[0] is AssetEdit.AddTag && edits[1] is AssetEdit.AddTag && edits[2] is AssetEdit.RemoveTag,
            "连续操作发送独立原子意图");
        Check(assets.Records.First(x => x.Kind == AssetKind.Saved).Tags.SequenceEqual(new[] { "工作", "学习" }), "无成功回传不冒称标签已保存");
        assets.Receive([Saved() with { Tags = ["学习", "新增B"] }, Color()]);
        Check(assets.Records.First(x => x.Kind == AssetKind.Saved).Tags.SequenceEqual(new[] { "学习", "新增B" }), "首笔失败、后两笔成功的宿主快照显示准确");
        assets.Delete(new(AssetKind.Color, SavedId)); Check(assets.Records.Count == 2, "删除等待成功快照");
        Check(edits.Last() is AssetEdit.Delete { Key.Kind: AssetKind.Color }, "删除带有准确类型");

        var many = Enumerable.Range(0, 10_000).Select(i => Saved($"记录{i} 完整文本") with { Id = Guid.NewGuid(), CreatedAt = DateTimeOffset.Now.AddSeconds(-i) }).ToArray();
        var watch = Stopwatch.StartNew(); assets.Receive(many); watch.Stop(); double indexMs = watch.Elapsed.TotalMilliseconds;
        long builds = assets.IndexBuilds; assets.Receive(many); Check(assets.IndexBuilds == builds, "未变化记录复用搜索索引");
        watch.Restart(); assets.Search("记录9999"); watch.Stop();
        Check(assets.Results.Count == 1 && assets.Results[0].Id == many[^1].Id, "一万条末项可搜索");
        Evidence.Add(new { Kind = "model-only-index", Records = many.Length, IndexMilliseconds = indexMs, SearchMilliseconds = watch.Elapsed.TotalMilliseconds });
        Passed("多ID草稿恢复、资产类型、原子意图与一万条索引");
    }

    private static async Task SettingsChecks()
    {
        await TriggerSettingsChecks();
        var model = new SettingsModel { Save = _ => Task.FromResult(true) };
        Check(FeatureNames.All.Length == 6 && FeatureNames.All[^1] == ActionKind.ReplyCoach, "功能库包含六个真实功能");
        Check(!model.Value.Slots.Contains(ActionKind.ReplyCoach) && SettingsModel.Equal(model.Value, WheelSettings.Default), "新增嘴替保留默认四格");
        for (int count = 1; count <= 8; count++)
        {
            model.Count(count); await Idle();
            Check(model.Value.Slots.Length == count && model.Value.IsValid, $"设置{count}格有效");
            var placed = SettingsModel.Drop(model.Value, ActionKind.PickColor, null, count - 1, false);
            Check(placed.Slots[^1] == ActionKind.PickColor, "从功能库拖入最后一格");
            var removed = SettingsModel.Drop(placed, ActionKind.PickColor, count - 1, null, true);
            Check(removed.Slots[^1] is null, "拖出托盘清空原格");
            var cancelled = SettingsModel.Drop(placed, ActionKind.PickColor, count - 1, null, false);
            Check(SettingsModel.Equal(cancelled, placed), "拖回中心取消不改变格子");
            var coachDrop = SettingsModel.Drop(model.Value, ActionKind.ReplyCoach, null, count - 1, false);
            Check(coachDrop.Slots[^1] == ActionKind.ReplyCoach && coachDrop.Slots.Take(count - 1).SequenceEqual(model.Value.Slots.Take(count - 1)), "嘴替可拖入1–8格且只替换目标格");
        }
        var original = WheelSettings.Default;
        var swapped = SettingsModel.Drop(original, ActionKind.Save, 0, 1, false);
        Check(swapped.Slots[0] == ActionKind.Translate && swapped.Slots[1] == ActionKind.Save, "格间交换而非覆盖");
        var pending = new List<TaskCompletionSource<bool>>();
        model.Save = _ => { var completion = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously); pending.Add(completion); return completion.Task; };
        model.Count(4); model.Count(5);
        model.Receive(WheelSettings.Default);
        Check(model.Value.Slots.Length == 5, "本地保存期间忽略迟到启动快照");
        pending[0].SetResult(false); await Idle();
        Check(!model.SaveFailed && model.Saving, "旧保存失败不覆盖最新待保存状态");
        pending[1].SetResult(false); await Idle();
        Check(model.SaveFailed && !model.Saving, "最新保存失败展示重试");
        model.Retry(); pending[^1].SetResult(true); await Idle();
        Check(!model.SaveFailed && !model.Saving && model.Value.Slots.Length == 5, "重试保留最新设置");
        model.Save = _ => Task.FromResult(true);
        model.Color(ActionKind.Explain, Palette.ColorValue(0x6A4A9E)); await Idle();
        Check(model.Value.Colors[ActionKind.Explain] == Palette.ColorValue(0x6A4A9E), "选择功能色板");
        model.Color(ActionKind.Explain, Palette.Default(ActionKind.Explain)); await Idle();
        Check(!model.Value.Colors.ContainsKey(ActionKind.Explain), "选择默认色删除冗余覆盖");
        model.Color(ActionKind.ReplyCoach, Palette.ColorValue(0xA53D2E)); await Idle();
        Check(model.Value.Colors[ActionKind.ReplyCoach] == Palette.ColorValue(0xA53D2E), "嘴替可编辑颜色");
        model.Color(ActionKind.ReplyCoach, Palette.Default(ActionKind.ReplyCoach)); await Idle();
        Check(Palette.Default(ActionKind.ReplyCoach) == Palette.ColorValue(0x4A6619) && !model.Value.Colors.ContainsKey(ActionKind.ReplyCoach), "嘴替绿色为默认且不存冗余覆盖");
        Passed("设置1–8格、拖放、保存代次、失败重试与颜色");
    }

    private static async Task TriggerSettingsChecks()
    {
        var model = new SettingsModel();
        var sent = new List<WheelSettings>(); var pending = new List<TaskCompletionSource<bool>>();
        model.Save = value =>
        {
            sent.Add(value);
            var completion = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
            pending.Add(completion); return completion.Task;
        };
        Check(model.Value.TriggerEnabled, "默认配置允许触发轮盘");
        var before = model.Value.Copy();
        model.Trigger(false);
        Check(!model.Value.TriggerEnabled && !SettingsModel.Equal(model.Value, before) &&
            model.Value.Slots.SequenceEqual(before.Slots), "触发开关参与设置相等判断且保留槽位");
        model.Count(5); model.Receive(WheelSettings.Default);
        Check(!model.Value.TriggerEnabled && model.Value.Slots.Length == 5 && sent.All(x => !x.TriggerEnabled),
            "改格数保留关闭状态，迟到启动读取不能重新开启");
        pending[0].SetResult(false); await Idle();
        Check(model.Saving && !model.SaveFailed, "旧开关保存失败不覆盖较新设置");
        pending[1].SetResult(false); await Idle();
        Check(model.SaveFailed && !model.Value.TriggerEnabled, "最新保存失败保留关闭状态");
        model.Retry(); pending[^1].SetResult(true); await Idle();
        Check(!model.SaveFailed && !sent[^1].TriggerEnabled, "重试保存当前关闭状态");
        model.Save = value => { sent.Add(value); return Task.FromResult(true); };
        model.Color(ActionKind.Translate, Palette.ColorValue(0x6A4A9E)); model.Assign(4, ActionKind.ReplyCoach);
        model.Apply(SettingsModel.Drop(model.Value, ActionKind.Explain, 0, 1, false)); await Idle();
        Check(!model.Value.TriggerEnabled && sent.All(x => !x.TriggerEnabled), "换色、功能分配与拖放保留关闭状态");
        var restored = new SettingsModel(); restored.Receive(model.Value);
        Check(!restored.Value.TriggerEnabled, "新模型从宿主已保存快照恢复关闭状态");
        model.Trigger(true); await Idle();
        Check(model.Value.TriggerEnabled && sent[^1].TriggerEnabled, "重新开启通过完整配置保存");
        int count = sent.Count; model.Trigger(true);
        Check(sent.Count == count, "相同触发状态不重复保存");
        Passed("触发开关、保存代次、失败重试与其他设置保留");
    }
}
