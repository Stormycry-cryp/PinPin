using System.Windows;
using System.Windows.Interop;
using System.Windows.Threading;
using PinPin.Core;
using PinPin.Presentation.Models;

namespace PinPin.Presentation.Checks;

internal static class ResultDispatchChecks
{
    // Hold the STA only while a finite producer fills the pending slots. This makes overwrite,
    // cancellation and input-order checks deterministic; the native performance load stays asynchronous.
    private static void Produce(Action action) => Task.Run(action).GetAwaiter().GetResult();
    private static ResultState Initial(Guid id) => new(id, ActionKind.Explain, Program.Anchor(id), "旧完整回答", false, true);

    internal static async Task RunOffscreen()
    {
        Guid id = Guid.NewGuid(); var initial = Initial(id);
        ProductionStateChecks(initial);
        var pending = new WindowsPresentation.PendingResult();
        var loading = initial with { Text = "", IsLoading = true, IsComplete = false };
        pending.Add(loading);
        for (int i = 1; i <= 500; i++) pending.Add(initial with { Text = new string('甲', i), IsAnswering = true, IsComplete = false });
        var complete = initial with { Text = new string('甲', 500) };
        pending.Add(complete);
        Program.Check(pending.Count == 3, "成功终态已包含全文时仅保留加载、首段及终态");
        Program.Check(pending.Take() == loading && pending.Take().Text == "甲", "首个正文不会被终段替换");
        Program.Check(pending.Take() == complete && pending.Count == 0, "最终全文和完成状态完整且不重复发布近完整尾项");

        ResultState[] transitions = [complete, loading with { Question = "问题一" },
            initial with { Text = "第一问", IsComplete = false, IsAnswering = true, Question = "问题一" },
            initial with { Text = "", IsComplete = false, Error = "请求失败", Question = "问题一" },
            loading with { Question = "问题二" }, initial with { Text = "第二问", Question = "问题二" },
            initial with { Action = ActionKind.PickColor, Color = Program.Color().Color, ColorPersistence = PersistenceState.Saving },
            initial with { Action = ActionKind.PickColor, Color = Program.Color().Color, ColorPersistence = PersistenceState.Failed },
            initial with { Action = ActionKind.PickColor, Color = Program.Color().Color, ColorPersistence = PersistenceState.Saved }];
        foreach (var state in transitions) pending.Add(state);
        Program.Check(transitions.All(x => pending.Take() == x) && pending.Count == 0,
            "完成、加载、两次追问、错误与颜色保存状态转换不被合并");
        var stream = initial with { IsComplete = false, IsAnswering = true };
        pending.Add(stream with { Text = "甲乙丙" }); pending.Add(stream with { Text = "丁" });
        pending.Add(stream with { Text = "丁戊", Anchor = initial.Anchor with { Point = new(100, 100) } });
        Program.Check(pending.Count == 3, "非前缀正文重置及锚点变化保留顺序");

        var followupPending = new WindowsPresentation.PendingResult();
        for (int i = 1; i <= 500; i++) followupPending.Add(initial with { Text = new string('追', i), IsAnswering = true, Question = "追问" });
        followupPending.Add(initial with { Text = new string('追', 500), Question = "追问" });
        Program.Check(followupPending.Count == 2 && followupPending.Take().Text == "追" &&
            followupPending.Take() is { Text.Length: 500, IsAnswering: false },
            "后端沿用IsComplete时，追问仍保留首段并合并累计正文");

        var answer = initial with { Text = "首", IsComplete = false, IsAnswering = true };
        var tail = answer with { Text = "首段累计" };
        var final = initial with { Text = "首段累计完整" };
        ResultState[] incompatibleFinals = [final with { Error = "失败" }, final with { Text = "正文重置" },
            final with { Text = "首" }, final with { Question = "另一代问题" },
            final with { Anchor = final.Anchor with { Point = new(100, 100) } },
            final with { ColorPersistence = PersistenceState.Saved }, final with { Color = Program.Color().Color },
            final with { Saved = Program.Saved() }, final with { Action = ActionKind.Translate },
            final with { IsLoading = true }, final with { IsAnswering = true }, final with { IsComplete = false }];
        foreach (var incompatible in incompatibleFinals)
        {
            var retained = new WindowsPresentation.PendingResult(); retained.Add(answer); retained.Add(tail); retained.Add(incompatible);
            Program.Check(retained.Count == 3 && retained.Take() == answer && retained.Take() == tail && retained.Take() == incompatible,
                "错误、重置、缩短或语义不兼容的终态不得删除未发尾项");
        }
        var firstOnly = new WindowsPresentation.PendingResult(); firstOnly.Add(answer); firstOnly.Add(final);
        Program.Check(firstOnly.Count == 2 && firstOnly.Take() == answer && firstOnly.Take() == final,
            "只有首段和终态时，首段不可被包含它的终态替换");
        var alreadyPublished = new WindowsPresentation.PendingResult(); alreadyPublished.Add(answer); alreadyPublished.Add(tail);
        Program.Check(alreadyPublished.Take() == answer && alreadyPublished.Take() == tail, "首段及尾项可以在终态到达前发布");
        alreadyPublished.Add(final);
        Program.Check(alreadyPublished.Count == 1 && alreadyPublished.Take() == final, "已发状态不被回改，晚到终态仍正常发布");

        using var presentation = new WindowsPresentation(Dispatcher.CurrentDispatcher);
        Guid savedId = Guid.NewGuid(); var saved = Program.Saved();
        var savedState = new ResultState(savedId, ActionKind.Save, Program.Anchor(savedId) with { Window = new nint(1) },
            IsLoading: false, IsComplete: true, Saved: saved);
        Produce(() => presentation.ShowResult(savedState));
        saved.Tags[0] = "调用方后续修改";
        presentation.UpdateSourceWindow(new(new nint(1), false, new(0, 0, 1200, 800)));
        await Program.Idle();
        Program.Check(presentation.TestResult(savedId)?.State.Saved?.Tags[0] == "工作" && presentation.GetDiagnostics().OwnedWindows == 0,
            "待发收藏保留调用时标签快照，隐藏来源不创建窗口");
        presentation.ClearResults();
        Guid deletedId = Guid.NewGuid(); int closed = 0;
        presentation.SetCallbacks(new() { ResultClosed = _ => closed++ });
        presentation.UpdateAssets([Program.Saved()]);
        Produce(() => presentation.ShowResult(savedState with { Id = deletedId, Anchor = Program.Anchor(deletedId), Saved = Program.Saved() }));
        presentation.UpdateAssets([]);
        await Program.Idle();
        Program.Check(presentation.TestResult(deletedId) is null && presentation.TestPendingResultCount == 0 && closed == 1,
            "资产删除包含尚未呈现的收藏结果且只通知关闭一次");
        Guid removed = Guid.NewGuid(), cleared = Guid.NewGuid();
        Produce(() => presentation.ShowResult(Initial(removed)));
        Program.Check(presentation.TestPendingResultCount == 1, "后台结果只挂一个待发ID");
        presentation.RemoveResult(removed);
        Produce(() => presentation.ShowResult(Initial(removed)));
        await Program.Idle();
        Program.Check(presentation.TestPendingResultCount == 0 && presentation.TestResult(removed) is null,
            "尚未创建模型的结果关闭后，晚到回调无法复活");
        Produce(() => presentation.ShowResult(Initial(cleared)));
        presentation.ClearResults();
        Produce(() => presentation.ShowResult(Initial(cleared)));
        await Program.Idle();
        Program.Check(presentation.TestPendingResultCount == 0 && presentation.TestResult(cleared) is null,
            "全清包含尚未呈现的ID，晚到回调无法复活");
        Produce(() => presentation.ShowResult(Initial(Guid.NewGuid())));
        presentation.Dispose();
        Produce(() => presentation.ShowResult(Initial(Guid.NewGuid())));
        await Program.Idle();
        Program.Check(presentation.TestPendingResultCount == 0 && presentation.GetDiagnostics().OwnedWindows == 0 &&
            presentation.GetDiagnostics().ResultModels == 0, "Dispose撤销未发更新且不创建原生窗口");
        Program.Passed("离屏累计正文合并、状态顺序与未发更新清理");
    }

    private static void ProductionStateChecks(ResultState initial)
    {
        // ActionCoordinator's first generation changes only Text until its successful completion.
        // Keep this separate from the historical native stress load's answering flags.
        foreach (ActionKind action in new[] { ActionKind.Explain, ActionKind.Translate, ActionKind.Rewrite })
        {
            var loading = new ResultState(initial.Id, action, initial.Anchor);
            var pending = new WindowsPresentation.PendingResult(); pending.Add(loading);
            for (int i = 1; i <= 500; i++) pending.Add(loading with { Text = new string('初', i) });
            var done = loading with { Text = new string('初', 500), IsLoading = false, IsComplete = true };
            pending.Add(done);
            Program.Check(pending.Count == 3 && pending.Take() == loading &&
                pending.Take() is { Text: "初", IsLoading: true, IsAnswering: false, IsComplete: false } && pending.Take() == done,
                "Core首次回答flags保留加载入场、首段和成功终态，并合并未发累计正文");
            ResultState[] stops = [done with { IsComplete = false, Error = "首次请求失败" }, done with { Text = "正文重新开始" }];
            foreach (var stop in stops)
            {
                var kept = new WindowsPresentation.PendingResult();
                var first = loading with { Text = "初" }; var tail = loading with { Text = "初次累计" };
                kept.Add(loading); kept.Add(first); kept.Add(tail); kept.Add(stop);
                Program.Check(kept.Count == 4 && kept.Take() == loading && kept.Take() == first && kept.Take() == tail && kept.Take() == stop,
                    "Core首次回答错误或正文重置不删除累计尾项");
            }
        }
        var mixedLoading = initial with { Text = "初", IsLoading = true, IsComplete = false, IsAnswering = true };
        var mixedTail = mixedLoading with { Text = "初次累计" };
        var mixedDone = mixedLoading with { Text = "初次累计完成", IsLoading = false, IsComplete = true, IsAnswering = false };
        var mixed = new WindowsPresentation.PendingResult(); mixed.Add(mixedLoading); mixed.Add(mixedTail); mixed.Add(mixedDone);
        Program.Check(mixed.Count == 3 && mixed.Take() == mixedLoading && mixed.Take() == mixedTail && mixed.Take() == mixedDone,
            "Loading与Answering同时为true的其他状态不套用首次回答结束规则");
        var saved = Program.Saved() with { Tags = ["A", "B"] };
        var savedAnswer = initial with { Action = ActionKind.Save, Text = "存", IsAnswering = true, Question = "收藏追问", Saved = saved };
        var sameTags = new WindowsPresentation.PendingResult();
        for (int i = 1; i <= 500; i++)
            sameTags.Add(savedAnswer with { Text = new string('存', i), Saved = saved with { Tags = saved.Tags.ToArray() } });
        sameTags.Add(savedAnswer with { Text = new string('存', 500), IsAnswering = false, Saved = saved with { Tags = saved.Tags.ToArray() } });
        Program.Check(sameTags.Count == 2 && sameTags.Take().Text == "存" && sameTags.Take() is { Text.Length: 500, IsAnswering: false },
            "收藏追问标签内容一致时，独立数组不阻止累计正文合并及成功终态替换");
        AssetRecord[] changedSaved = [saved with { Tags = ["A", "C"] }, saved with { Tags = ["B", "A"] },
            saved with { Tags = ["a", "B"] }, saved with { Tags = ["A", "B", "C"] }, saved with { Tags = ["A"] },
            saved with { Text = "收藏正文更新" }, saved with { AppName = "不同来源" }, saved with { ImagePath = "different.png" }];
        foreach (var changed in changedSaved)
        {
            var retained = new WindowsPresentation.PendingResult();
            var tail = savedAnswer with { Text = "存下更多", Saved = saved with { Tags = saved.Tags.ToArray() } };
            var done = savedAnswer with { Text = "存下更多全文", IsAnswering = false, Saved = changed };
            retained.Add(savedAnswer); retained.Add(tail); retained.Add(done);
            Program.Check(retained.Count == 3 && retained.Take() == savedAnswer && retained.Take() == tail && retained.Take() == done,
                "标签内容、顺序、大小写及收藏其他字段变化不被终态合并忽略");
        }
        var tagTransition = new WindowsPresentation.PendingResult();
        var oldTail = savedAnswer with { Text = "存一" };
        var newTags = savedAnswer with { Text = "存一二", Saved = saved with { Tags = ["新标签"] } };
        tagTransition.Add(savedAnswer); tagTransition.Add(oldTail); tagTransition.Add(newTags);
        tagTransition.Add(newTags with { Text = "存一二三", Saved = saved with { Tags = ["新标签"] } });
        var finalTags = newTags with { Text = "存一二三四", IsAnswering = false };
        tagTransition.Add(finalTags);
        Program.Check(tagTransition.Count == 4 && tagTransition.Take() == savedAnswer && tagTransition.Take() == oldTail &&
            tagTransition.Take() == newTags && tagTransition.Take() == finalTags,
            "收藏追问中途标签变化保留边界，之后的同标签正文仍可合并");
    }

    internal static async Task RunNative()
    {
        var dispatcher = Dispatcher.CurrentDispatcher;
        var source = new Window { Title = "PinPin 调度边界合成来源", Width = 400, Height = 200, ShowActivated = false };
        source.Show();
        using var presentation = new WindowsPresentation(dispatcher);
        try
        {
            nint hwnd = new WindowInteropHelper(source).Handle;
            Guid a = Guid.NewGuid(), b = Guid.NewGuid(), colorId = Guid.NewGuid();
            ResultState first = Initial(a) with { Anchor = Program.Anchor(a) with { Window = hwnd } };
            ResultState second = Initial(b) with { Anchor = Program.Anchor(b, 850) with { Window = hwnd } };
            presentation.ShowResult(first); presentation.ShowResult(second);
            var model = presentation.TestResult(a)!; var other = presentation.TestResult(b)!;
            presentation.TestOpen(a); presentation.TestOpen(b);
            model.Draft = "问题一"; other.Draft = "另一草稿";
            Program.Check(model.Submit((_, _) => { }), "调度测试进入真实追问状态");
            var seen = new List<ResultState>(); var otherSeen = new List<ResultState>();
            bool inputSeen = false;
            model.Changed += () =>
            {
                seen.Add(model.State);
                if (seen.Count == 1) dispatcher.BeginInvoke(DispatcherPriority.Input, new Action(() => inputSeen = true));
            };
            other.Changed += () => otherSeen.Add(other.State);
            Produce(() =>
            {
                for (int i = 1; i <= 500; i++)
                {
                    presentation.ShowResult(first with { Text = new string('甲', i), IsAnswering = true, Question = "问题一" });
                    presentation.ShowResult(second with { Text = new string('乙', i), IsComplete = false, IsAnswering = true });
                }
                presentation.ShowResult(first with { Text = "", Error = "合成失败", Question = "问题一" });
                presentation.ShowResult(second with { Text = new string('乙', 500) });
            });
            // An STA result that arrives after the producer must not overtake its queued predecessors.
            presentation.ShowResult(second with { Text = new string('乙', 500) + "最终校正" });
            Program.Check(presentation.TestPendingResultCount == 2, "两个ID各自只保留一个待发调度");
            bool inputBeforeTerminal = false;
            other.Changed += () => { if (other.State.IsComplete) inputBeforeTerminal = inputSeen; };
            await Program.Idle();
            Program.Check(seen.Count == 3 && seen[0].Text == "甲" && seen[1].Text.Length == 500 && seen[2].Error == "合成失败",
                "实际Dispatcher发布首段、最新正文及错误，各自只有一次");
            Program.Check(otherSeen.Count == 3 && otherSeen[0].Text == "乙" && otherSeen[1].Text.Length == 500 &&
                otherSeen[1].IsComplete && other.DisplayText.EndsWith("最终校正") && other.Draft == "另一草稿",
                "跨ID成功流保留首段与全文终态，UI线程更新遵守已有待发顺序");
            Program.Check(inputBeforeTerminal, "首段后Input优先级回调在终态之前获得执行机会");
            Program.Check(model.DisplayText == "旧完整回答" && model.Draft == "问题一" && model.CanFollowup,
                "合并后追问失败仍恢复上一完整回答和原问题");
            int firstBurstChanges = seen.Count, otherBurstChanges = otherSeen.Count;
            ResultState[] distinctEnds = [second with { Text = "重置后正文" },
                second with { Text = "丁戊完整", Question = "不同问题" },
                second with { Text = "丁戊完整", Anchor = second.Anchor with { Point = new(650, 500) } }];
            foreach (var end in distinctEnds)
            {
                int start = otherSeen.Count;
                Produce(() =>
                {
                    presentation.ShowResult(second with { Text = "丁", IsComplete = false, IsAnswering = true });
                    presentation.ShowResult(second with { Text = "丁戊", IsComplete = false, IsAnswering = true });
                    presentation.ShowResult(end);
                });
                await Program.Idle();
                Program.Check(otherSeen.Count == start + 3 && otherSeen[start].Text == "丁" && otherSeen[start + 1].Text == "丁戊" &&
                    otherSeen[start + 2] == end, "真实Dispatcher保留重置、不同问题和不同锚点之前的未发尾项");
            }
            model.Draft = "问题二"; Program.Check(model.Submit((_, _) => { }), "失败后可以提交下一代追问");
            Produce(() =>
            {
                presentation.ShowResult(first with { Text = "", IsLoading = true, IsComplete = false, IsAnswering = true, Question = "问题二" });
                presentation.ShowResult(first with { Text = "第二代首段", IsComplete = false, IsAnswering = true, Question = "问题二" });
                presentation.ShowResult(first with { Text = "第二代完整回答", Question = "问题二" });
            });
            presentation.UpdateSourceWindow(new(hwnd, false, new(0, 0, 400, 200)));
            await Program.Idle();
            Program.Check(model.DisplayText == "第二代完整回答" && model.LastCompleteAnswer == model.DisplayText && model.CanFollowup &&
                presentation.GetDiagnostics().CardWindows == 0, "隐藏来源期间仍完成下一代回答且不创建可见卡片");
            presentation.UpdateSourceWindow(new(hwnd, true, new(0, 0, 400, 200))); await Program.Idle();
            Program.Check(presentation.GetDiagnostics().CardWindows == 2 && model.Mode == CardMode.Dialog && model.DisplayText == "第二代完整回答",
                "来源恢复保留独立对话模式与最新全文");

            ResultState color = new(colorId, ActionKind.PickColor, Program.Anchor(colorId), IsLoading: false, IsComplete: true,
                Color: Program.Color().Color, ColorPersistence: PersistenceState.Saving);
            presentation.ShowResult(color); var colorModel = presentation.TestResult(colorId)!;
            var persistence = new List<PersistenceState?>(); colorModel.Changed += () => persistence.Add(colorModel.State.ColorPersistence);
            Produce(() =>
            {
                presentation.ShowResult(color with { ColorPersistence = PersistenceState.Failed });
                presentation.ShowResult(color with { ColorPersistence = PersistenceState.Saving });
                presentation.ShowResult(color with { ColorPersistence = PersistenceState.Saved });
            });
            await Program.Idle();
            Program.Check(persistence.SequenceEqual(new PersistenceState?[] { PersistenceState.Failed, PersistenceState.Saving, PersistenceState.Saved }) &&
                colorModel.State.Color == color.Color, "颜色保存失败、重试和成功全部到达且色值保持");

            Produce(() => presentation.ShowResult(first with { Text = "关闭前未发" }));
            presentation.TestClose(a);
            Produce(() => presentation.ShowResult(first with { Text = "关闭后晚到" }));
            await Program.Idle();
            Program.Check(presentation.TestResult(a) is null && presentation.TestResult(b) == other && presentation.TestPendingResultCount == 0,
                "单关清除待发更新，另一结果保持且关闭项无法复活");
            presentation.ClearResults();
            Guid hiddenId = Guid.NewGuid(); var hidden = Initial(hiddenId) with { Anchor = Program.Anchor(hiddenId) with { Window = hwnd } };
            Produce(() => presentation.ShowResult(hidden));
            presentation.UpdateSourceWindow(new(hwnd, false, new(0, 0, 400, 200)));
            await Program.Idle();
            Program.Check(presentation.TestResult(hiddenId)?.SourceVisible == false && presentation.GetDiagnostics().CardWindows == 0,
                "来源隐藏先于第一条待发更新时，卡片也不意外出现");
            presentation.UpdateSourceWindow(new(hwnd, true, new(0, 0, 400, 200))); await Program.Idle();
            Program.Check(presentation.GetDiagnostics().MarkerVisuals == 1 && presentation.GetDiagnostics().CardWindows == 0,
                "首条隐藏结果在来源恢复后按原有隐藏模式显示标注");
            presentation.ClearResults();
            Program.Evidence.Add(new { Kind = "native-result-dispatch-boundaries", InitialPacketsPerId = 500,
                FirstIdPublishedStates = firstBurstChanges, OtherIdPublishedStates = otherBurstChanges, InputBeforeTerminal = inputBeforeTerminal,
                PendingAfterClear = presentation.TestPendingResultCount,
                Boundary = "合成Dispatcher行为检查；不证明模型首字或显示器呈现时间" });
            await ProductionStateNativeChecks(presentation, hwnd);
        }
        finally { source.Close(); }
        Program.Passed("真实Dispatcher首段、输入机会、跨ID、追问代次、取色与来源显隐");
    }

    private static async Task ProductionStateNativeChecks(WindowsPresentation presentation, nint hwnd)
    {
        Guid id = Guid.NewGuid();
        var loading = new ResultState(id, ActionKind.Explain, Program.Anchor(id) with { Window = hwnd });
        presentation.ShowResult(loading);
        var model = presentation.TestResult(id)!;
        Program.Check(model.State == loading && model.Busy, "真实窗口保留Core初次加载状态");
        var seen = new List<ResultState>(); model.Changed += () => seen.Add(model.State);
        Produce(() =>
        {
            for (int i = 1; i <= 500; i++) presentation.ShowResult(loading with { Text = new string('初', i) });
            presentation.ShowResult(loading with { Text = new string('初', 500), IsLoading = false, IsComplete = true });
        });
        await Program.Idle();
        Program.Check(seen.Count == 2 && seen[0] is { Text: "初", IsLoading: true, IsAnswering: false } &&
            seen[1] is { Text.Length: 500, IsLoading: false, IsComplete: true, IsAnswering: false } && !model.Busy,
            "真实Dispatcher按Core初次flags保留首段和成功全文，Loading在完成时结束");
        int successfulInitialChanges = seen.Count;
        foreach (var stop in new[] { loading with { Text = "", IsLoading = false, Error = "首次失败" },
            loading with { Text = "重置后的完成内容", IsLoading = false, IsComplete = true } })
        {
            int start = seen.Count;
            Produce(() =>
            {
                presentation.ShowResult(loading);
                presentation.ShowResult(loading with { Text = "初" });
                presentation.ShowResult(loading with { Text = "初次累计" });
                presentation.ShowResult(stop);
            });
            await Program.Idle();
            Program.Check(seen.Count == start + 4 && seen[start] == loading && seen[start + 1].Text == "初" &&
                seen[start + 2].Text == "初次累计" && seen[start + 3] == stop,
                "真实Dispatcher的首次flags错误或重置保留加载、首段及累计尾项");
        }
        presentation.ClearResults();
        Guid savedId = Guid.NewGuid(); var asset = Program.Saved();
        var savedState = new ResultState(savedId, ActionKind.Save, Program.Anchor(savedId) with { Window = hwnd },
            "收藏原文", false, true, Question: "收藏追问", Saved: asset);
        presentation.ShowResult(savedState); var savedModel = presentation.TestResult(savedId)!;
        var savedSeen = new List<ResultState>(); savedModel.Changed += () => savedSeen.Add(savedModel.State);
        Produce(() =>
        {
            for (int i = 1; i <= 500; i++) presentation.ShowResult(savedState with { Text = new string('存', i), IsAnswering = true });
            presentation.ShowResult(savedState with { Text = new string('存', 500) });
        });
        await Program.Idle();
        Program.Check(savedSeen.Count == 2 && savedSeen[0].Text == "存" && savedSeen[1] is { Text.Length: 500, IsAnswering: false } &&
            !ReferenceEquals(savedSeen[0].Saved!.Tags, savedSeen[1].Saved!.Tags) && savedSeen[1].Saved!.Tags.SequenceEqual(asset.Tags),
            "真实ShowResult标签快照数组不同但内容相同时，收藏追问可合并为首段和终态");
        int sameTagsChanges = savedSeen.Count;
        Produce(() =>
        {
            presentation.ShowResult(savedState with { Text = "存", IsAnswering = true });
            presentation.ShowResult(savedState with { Text = "存下更多", IsAnswering = true });
            presentation.ShowResult(savedState with { Text = "存下更多全文", Saved = asset with { Tags = ["已变更"] } });
        });
        await Program.Idle();
        Program.Check(savedSeen.Count == sameTagsChanges + 3 && savedSeen[sameTagsChanges + 1].Text == "存下更多" &&
            savedSeen[^1].Saved!.Tags.SequenceEqual(new[] { "已变更" }), "真实收藏追问终态标签变化保留累计尾项与实际新标签");
        presentation.ClearResults();
        Program.Evidence.Add(new { Kind = "native-core-flags-dispatch-boundaries", SyntheticPackets = 500,
            InitialSuccessChanges = successfulInitialChanges, SameTagSavedFollowupChanges = sameTagsChanges,
            Boundary = "使用Core实际flags的单结果行为断言，不替代固定8×500性能负载，也不证明真实模型或初次回答CPU收益" });
    }
}
