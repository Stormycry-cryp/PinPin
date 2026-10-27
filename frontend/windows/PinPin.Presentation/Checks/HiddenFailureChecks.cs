using System.Windows;
using System.Windows.Interop;
using System.Windows.Threading;
using PinPin.Core;
using PinPin.Presentation.Models;
using PinPin.Presentation.Views;

namespace PinPin.Presentation.Checks;

// Uses the production Dispatcher, pending queue, model and native ResultWindow.
// Source visibility is synthetic: this check does not diagnose the user's window observer.
internal static class HiddenFailureChecks
{
    internal static async Task Run()
    {
        var source = new Window { Title = "PinPin 隐藏来源失败检查", Width = 400, Height = 240, ShowActivated = false };
        source.Show();
        using var presentation = new WindowsPresentation(Dispatcher.CurrentDispatcher);
        try
        {
            nint hwnd = new WindowInteropHelper(source).Handle;
            Guid id = Guid.NewGuid();
            var failed = new ResultState(id, ActionKind.Explain, Program.Anchor(id) with { Window = hwnd },
                IsLoading: false, Error: "合成首次请求失败");
            // Keep the STA occupied until the producer queues its state, then hide the source
            // before the production Background-priority dispatcher operation can apply it.
            Task.Run(() => presentation.ShowResult(failed)).GetAwaiter().GetResult();
            presentation.UpdateSourceWindow(new(hwnd, false, new(0, 0, 1200, 800)));
            await Program.Idle();
            var hidden = presentation.GetDiagnostics();
            Program.Check(hidden.ResultModels == 1 && hidden.MarkerVisuals == 0 && hidden.CardWindows == 0,
                "首次错误在隐藏来源中完成时不创建卡片或标记");
            presentation.UpdateSourceWindow(new(hwnd, true, new(0, 0, 1200, 800)));
            await Program.Idle();
            var restored = presentation.GetDiagnostics();
            Program.Evidence.Add(new { Kind = "hidden-first-failure-restore", Hidden = hidden, Restored = restored,
                Mode = presentation.TestResult(id)?.Mode.ToString(), Error = presentation.TestResult(id)?.State.Error });
            Program.Check(restored.ResultModels == 1 && restored.MarkerVisuals == 0 && restored.CardWindows == 1 &&
                presentation.TestResult(id)?.Mode == CardMode.Short &&
                presentation.TestWindows.OfType<ResultWindow>().Single().IsVisible,
                "来源恢复后，首次失败必须显示真实短卡片且没有错误标记");
            int closed = 0;
            presentation.SetCallbacks(new() { ResultClosed = _ => closed++ });
            presentation.TestClose(id);
            presentation.UpdateSourceWindow(new(hwnd, false, new(0, 0, 1200, 800)));
            presentation.ShowResult(failed);
            presentation.UpdateSourceWindow(new(hwnd, true, new(0, 0, 1200, 800)));
            await Program.Idle();
            Program.Check(closed == 1 && presentation.TestResult(id) is null && presentation.GetDiagnostics().CardWindows == 0,
                "关闭失败结果后，晚到回调和来源恢复都不重开");
            foreach (bool restoreBeforeWheelEnds in new[] { false, true })
                await WheelFailure(presentation, hwnd, restoreBeforeWheelEnds);
            await CollapsedAndIndependent(presentation, hwnd);
            Program.Passed("首次失败恢复、轮盘延后显示、关闭与收起隔离");
        }
        finally { presentation.Dispose(); source.Close(); }
    }

    private static async Task WheelFailure(WindowsPresentation presentation, nint hwnd, bool restoreBeforeWheelEnds)
    {
        presentation.ClearResults();
        Guid id = Guid.NewGuid();
        var loading = new ResultState(id, ActionKind.Translate, Program.Anchor(id) with { Window = hwnd });
        presentation.ShowWheel(WheelGeometry.Create(loading.Anchor, WheelSettings.Default, [new(0, 0, 1200, 800)]));
        // Use the same loading -> error sequence as the coordinator, while the wheel is still up.
        Task.Run(() => presentation.ShowResult(loading)).GetAwaiter().GetResult();
        presentation.UpdateSourceWindow(new(hwnd, false, new(0, 0, 1200, 800)));
        await Program.Idle();
        presentation.ShowResult(loading with { IsLoading = false, Error = "合成翻译失败" });
        if (restoreBeforeWheelEnds)
        {
            presentation.UpdateSourceWindow(new(hwnd, true, new(0, 0, 1200, 800)));
            Program.Check(presentation.GetDiagnostics().CardWindows == 0,
                "来源先恢复时，首次失败仍等轮盘关闭后再显示");
            presentation.HideWheel();
        }
        else
        {
            presentation.HideWheel();
            Program.Check(presentation.GetDiagnostics().CardWindows == 0,
                "轮盘先关闭时，隐藏来源不创建结果窗口");
            presentation.UpdateSourceWindow(new(hwnd, true, new(0, 0, 1200, 800)));
        }
        await Program.Idle();
        var restored = presentation.GetDiagnostics();
        Program.Evidence.Add(new { Kind = "hidden-wheel-failure-restore", RestoreBeforeWheelEnds = restoreBeforeWheelEnds,
            Restored = restored, Mode = presentation.TestResult(id)?.Mode.ToString() });
        Program.Check(restored.CardWindows == 1 && restored.MarkerVisuals == 0 &&
            presentation.TestResult(id)?.Mode == CardMode.Short &&
            presentation.TestWindows.OfType<ResultWindow>().Single().IsVisible,
            "轮盘关闭与来源恢复的两种顺序都显示失败卡片");
        presentation.TestCollapse(id);
        presentation.UpdateSourceWindow(new(hwnd, false, new(0, 0, 1200, 800)));
        presentation.UpdateSourceWindow(new(hwnd, true, new(0, 0, 1200, 800)));
        presentation.HideWheel();
        Program.Check(presentation.TestResult(id)?.Mode == CardMode.Hidden && presentation.GetDiagnostics().CardWindows == 0,
            "已显示后收起的失败卡片不被重复来源通知或HideWheel重开");
    }

    private static async Task CollapsedAndIndependent(WindowsPresentation presentation, nint hwnd)
    {
        presentation.ClearResults();
        Guid collapsedId = Guid.NewGuid(), failedId = Guid.NewGuid(), otherId = Guid.NewGuid();
        var collapsed = new ResultState(collapsedId, ActionKind.Explain, Program.Anchor(collapsedId) with { Window = hwnd });
        presentation.ShowResult(collapsed);
        presentation.TestCollapse(collapsedId);
        presentation.TestResult(collapsedId)!.Draft = "保留草稿";
        var other = new ResultState(otherId, ActionKind.Explain, Program.Anchor(otherId, 850), "另一来源完整回答", false, true);
        presentation.ShowResult(other); presentation.TestOpen(otherId);
        presentation.TestResult(otherId)!.Draft = "另一草稿";
        var failed = new ResultState(failedId, ActionKind.Rewrite, Program.Anchor(failedId) with { Window = hwnd },
            IsLoading: false, Error: "合成改写失败");
        Task.Run(() => presentation.ShowResult(failed)).GetAwaiter().GetResult();
        presentation.UpdateSourceWindow(new(hwnd, false, new(0, 0, 1200, 800)));
        Task.Run(() =>
        {
            for (int i = 1; i <= 500; i++) presentation.ShowResult(collapsed with { Text = new string('甲', i) });
            presentation.ShowResult(collapsed with { Text = new string('甲', 500), IsLoading = false, IsComplete = true });
        }).GetAwaiter().GetResult();
        await Program.Idle();
        presentation.UpdateSourceWindow(new(hwnd, true, new(0, 0, 1200, 800)));
        await Program.Idle();
        var state = presentation.GetDiagnostics();
        Program.Check(state.ResultModels == 3 && state.CardWindows == 2 && state.MarkerVisuals == 1 &&
            presentation.TestPendingResultCount == 0, "同来源失败恢复不展开已收起的流式结果，其他来源窗口保留");
        Program.Check(presentation.TestResult(collapsedId) is { Mode: CardMode.Hidden, DisplayText.Length: 500, Draft: "保留草稿" } &&
            presentation.TestResult(otherId) is { Mode: CardMode.Dialog, DisplayText: "另一来源完整回答", Draft: "另一草稿" },
            "多个ID的完整正文、模式及草稿保持独立");
        presentation.ClearResults();
        presentation.UpdateSourceWindow(new(hwnd, true, new(0, 0, 1200, 800)));
        presentation.HideWheel();
        Program.Check(presentation.GetDiagnostics() is { ResultModels: 0, CardWindows: 0, MarkerVisuals: 0 },
            "全清后来源恢复与轮盘关闭不恢复任何结果");
    }
}
