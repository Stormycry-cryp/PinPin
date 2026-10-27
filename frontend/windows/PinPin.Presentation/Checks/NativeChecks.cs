using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using PinPin.Core;
using PinPin.Presentation.Views;

namespace PinPin.Presentation.Checks;

internal static class NativeChecks
{
    [DllImport("user32.dll")] private static extern uint GetGuiResources(nint process, uint flags);
    [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] private static extern nint GetThreadDpiAwarenessContext();
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool AreDpiAwarenessContextsEqual(nint a, nint b);
    private sealed record Resources(long WorkingSet, long PrivateBytes, int ProcessHandles, uint Gdi, uint User);
    private sealed record StreamPublication(int Sequence, double Milliseconds, int Characters, string Stage,
        bool IsComplete, bool IsAnswering);
    private static Resources Snapshot()
    { using var process = Process.GetCurrentProcess(); process.Refresh(); return new(process.WorkingSet64, process.PrivateMemorySize64, process.HandleCount, GetGuiResources(process.Handle, 0), GetGuiResources(process.Handle, 1)); }
    private static Dictionary<int, double> ThreadCpu()
    {
        var values = new Dictionary<int, double>(); using var process = Process.GetCurrentProcess();
        foreach (ProcessThread thread in process.Threads)
            using (thread)
                try { values[thread.Id] = thread.TotalProcessorTime.TotalMilliseconds; }
                catch (Exception error) when (error is InvalidOperationException or System.ComponentModel.Win32Exception) { }
        return values;
    }
    private static async Task MeasureIdle(WindowsPresentation presentation, int count, int seconds, bool observeRendering)
    {
        var elapsed = new Stopwatch(); var rendered = new List<double>();
        EventHandler onRender = (_, _) => rendered.Add(elapsed.Elapsed.TotalMilliseconds);
        using var process = Process.GetCurrentProcess();
        uint uiThread = GetCurrentThreadId();
        var beforeThreads = ThreadCpu(); var beforeResources = Snapshot();
        var beforeGc = Enumerable.Range(0, 3).Select(GC.CollectionCount).ToArray();
        long beforeAllocated = GC.GetTotalAllocatedBytes(false), beforeHeap = GC.GetTotalMemory(false);
        TimeSpan beforeCpu = process.TotalProcessorTime;
        try
        {
            elapsed.Start(); if (observeRendering) CompositionTarget.Rendering += onRender;
            await Task.Delay(TimeSpan.FromSeconds(seconds));
        }
        finally { if (observeRendering) CompositionTarget.Rendering -= onRender; elapsed.Stop(); }
        process.Refresh(); double cpu = (process.TotalProcessorTime - beforeCpu).TotalMilliseconds;
        var afterThreads = ThreadCpu();
        Program.Evidence.Add(new { Kind = "native-synthetic-marker-idle-stage", Count = count, RequestedSeconds = seconds,
            ElapsedMilliseconds = elapsed.Elapsed.TotalMilliseconds, CpuMilliseconds = cpu,
            EquivalentOneCorePercent = elapsed.Elapsed.TotalMilliseconds > 0 ? cpu / elapsed.Elapsed.TotalMilliseconds * 100 : 0,
            RenderingObserver = observeRendering, RenderingEventCount = observeRendering ? (int?)rendered.Count : null,
            RenderingEventMilliseconds = rendered, BeforeResources = beforeResources, AfterResources = Snapshot(),
            AllocatedBytes = GC.GetTotalAllocatedBytes(false) - beforeAllocated, ManagedHeapBefore = beforeHeap, ManagedHeapAfter = GC.GetTotalMemory(false),
            CollectionCounts = Enumerable.Range(0, 3).Select(i => GC.CollectionCount(i) - beforeGc[i]).ToArray(),
            ThreadCpu = afterThreads.Select(x => new { ThreadId = x.Key, UiThread = x.Key == uiThread,
                Milliseconds = x.Value - beforeThreads.GetValueOrDefault(x.Key) }).Where(x => x.Milliseconds > 0)
                .OrderByDescending(x => x.Milliseconds).Take(12).ToArray(), Diagnostics = presentation.GetDiagnostics(),
            Boundary = observeRendering
                ? "Rendering订阅会促使WPF继续调度帧，此阶段用于观察探针影响，不作为无探针空闲CPU结论"
                : "不订阅Rendering，不创建UI计时器，不强制GC；单次Task.Delay仅结束测量" });
    }
    internal static async Task Run()
    {
        var baseline = Snapshot();
        using (var process = Process.GetCurrentProcess())
            Program.Evidence.Add(new { Kind = "native-environment", Executable = Environment.ProcessPath, Environment.UserInteractive,
                process.SessionId, UiNativeThread = GetCurrentThreadId(), PerMonitorV2 = AreDpiAwarenessContextsEqual(GetThreadDpiAwarenessContext(), new nint(-4)) });
        var source = new Window { Title = "PinPin 合成验收来源", Width = 800, Height = 600, Left = 60, Top = 60,
            ShowActivated = false, Content = new TextBlock { Text = "此窗口仅用于 PinPin 前端合成验证。", Margin = new Thickness(24) } };
        source.Show(); await Program.Idle();
        nint hwnd = new WindowInteropHelper(source).Handle;
        int watched = 0, unwatched = 0, closed = 0;
        var presentation = new WindowsPresentation(Dispatcher.CurrentDispatcher);
        presentation.SetCallbacks(new() { SourceWindowWatched = _ => watched++, SourceWindowUnwatched = _ => unwatched++,
            ResultClosed = _ => closed++, WheelSettingsChanged = _ => Task.FromResult(true) });
        TargetAnchor Anchor(Guid id, int index) => Program.Anchor(id, 140 + (index % 8) * 72, 180 + (index / 8) * 46)
            with { Window = hwnd, WindowBounds = new(60, 60, 800, 600) };
        try
        {
            foreach (int count in new[] { 1, 16, 64 })
            {
                presentation.ClearResults();
                var duration = Stopwatch.StartNew();
                for (int i = 0; i < count; i++)
                {
                    Guid id = Guid.NewGuid();
                    presentation.ShowResult(new(id, ActionKind.Explain, Anchor(id, i), "合成完整回答", false, true));
                    presentation.TestCollapse(id);
                }
                await Program.Idle(); duration.Stop();
                var state = presentation.GetDiagnostics();
                Program.Check(state.MarkerVisuals == count && state.CardWindows == 0, $"{count}个收起结果只保留标记");
                Program.Check(state.MarkerWindows > 0 && state.MarkerWindows < Math.Max(2, count), "同屏多个标记共享原生窗口");
                Program.Check(state.ActiveUiTimers == 0, "静止标记没有常驻UI计时器");
                Program.Evidence.Add(new { Kind = "native-synthetic-markers", Count = count, SetupMilliseconds = duration.Elapsed.TotalMilliseconds,
                    Diagnostics = state, Resources = Snapshot() });
                foreach (int seconds in new[] { 1, 3, 5 }) await MeasureIdle(presentation, count, seconds, false);
                await MeasureIdle(presentation, count, 1, true);
            }
            presentation.ClearResults();
            var ids = Enumerable.Range(0, 8).Select(_ => Guid.NewGuid()).ToArray();
            for (int i = 0; i < ids.Length; i++)
            {
                presentation.ShowResult(new(ids[i], ActionKind.Explain, Anchor(ids[i], i), "准备接收", false, true));
                presentation.TestOpen(ids[i]); presentation.TestResult(ids[i])!.Draft = "独立草稿" + i;
            }
            await Program.Idle();
            Program.Check(presentation.GetDiagnostics().CardWindows == 8, "同时展开八个独立回答窗口");
            var beforeStream = presentation.GetDiagnostics();
            var expected = new string[8];
            var firstTextMs = new double?[8]; var completedMs = new double?[8];
            var modelChanges = new int[8]; var firstTextLength = new int[8];
            var publications = Enumerable.Range(0, 8).Select(_ => new List<StreamPublication>()).ToArray();
            var inputIntervals = new List<double>(); var renderingTimes = new List<double>();
            var streamWatch = new Stopwatch(); double lastInput = 0;
            var inputTimer = new DispatcherTimer(DispatcherPriority.Input, Dispatcher.CurrentDispatcher) { Interval = TimeSpan.FromMilliseconds(16) };
            EventHandler inputTick = (_, _) => { double now = streamWatch.Elapsed.TotalMilliseconds; inputIntervals.Add(now - lastInput); lastInput = now; };
            EventHandler rendering = (_, _) => renderingTimes.Add(streamWatch.Elapsed.TotalMilliseconds);
            var modelHandlers = new Action[8];
            for (int i = 0; i < ids.Length; i++)
            {
                int index = i;
                modelHandlers[index] = () =>
                {
                    var model = presentation.TestResult(ids[index])!;
                    modelChanges[index]++;
                    double now = streamWatch.Elapsed.TotalMilliseconds;
                    string stage = model.State.Error is not null ? "error" : model.State.IsComplete && !model.State.IsAnswering
                        ? "complete" : model.State.IsLoading ? "loading" : "answering";
                    publications[index].Add(new(modelChanges[index], now, model.DisplayText.Length, stage,
                        model.State.IsComplete, model.State.IsAnswering));
                    if (firstTextMs[index] is null && model.DisplayText.Length > 0)
                    { firstTextMs[index] = now; firstTextLength[index] = model.DisplayText.Length; }
                    if (model.State.IsComplete && !model.State.IsAnswering) completedMs[index] = now;
                };
                presentation.TestResult(ids[index])!.Changed += modelHandlers[index];
            }
            inputTimer.Tick += inputTick; CompositionTarget.Rendering += rendering;
            uint streamUiThread = GetCurrentThreadId(), producerThread = 0;
            var streamThreadsBefore = ThreadCpu();
            using var streamProcess = Process.GetCurrentProcess(); TimeSpan cpuBefore = streamProcess.TotalProcessorTime;
            double producerCompletedMs = 0;
            double drainedMs;
            try
            {
                streamWatch.Start(); inputTimer.Start();
                await Task.Run(() =>
                {
                    producerThread = GetCurrentThreadId();
                    var text = Enumerable.Range(0, 8).Select(_ => new StringBuilder()).ToArray();
                    for (int chunk = 0; chunk < 500; chunk++)
                        for (int index = 0; index < 8; index++)
                        {
                            text[index].Append($"回答{index}片段{chunk}；");
                            expected[index] = text[index].ToString();
                            presentation.ShowResult(new(ids[index], ActionKind.Explain, Anchor(ids[index], index), expected[index], false, chunk == 499, IsAnswering: chunk != 499));
                        }
                    producerCompletedMs = streamWatch.Elapsed.TotalMilliseconds;
                });
                await Program.Idle(); drainedMs = streamWatch.Elapsed.TotalMilliseconds;
                // Include the first input/render opportunity after the stream has drained, even if it was starved.
                await Task.Delay(60); await Program.Idle();
            }
            finally
            {
                inputTimer.Stop(); inputTimer.Tick -= inputTick; CompositionTarget.Rendering -= rendering;
                for (int i = 0; i < ids.Length; i++) if (presentation.TestResult(ids[i]) is { } model) model.Changed -= modelHandlers[i];
                streamWatch.Stop();
            }
            streamProcess.Refresh(); double streamCpuMs = (streamProcess.TotalProcessorTime - cpuBefore).TotalMilliseconds;
            var streamThreadsAfter = ThreadCpu();
            for (int i = 0; i < ids.Length; i++)
            {
                var model = presentation.TestResult(ids[i])!;
                Program.Check(model.DisplayText == expected[i] && model.Draft == "独立草稿" + i, "跨线程流式正文完整且草稿独立");
                Program.Check(firstTextMs[i] is not null && completedMs[i] is not null && modelChanges[i] is >= 2 and <= 500 &&
                    firstTextLength[i] == $"回答{i}片段0；".Length, "每个ID保留首片段及最终全文，允许合并未显示的累计正文");
                var card = presentation.TestWindows.OfType<ResultWindow>().Single(x => x.ResultId == ids[i]);
                Program.Check(AssetWindow.Descendants((DependencyObject)card.Content).OfType<TextBox>().Any(x => x.Text == expected[i]), "实际展开组件持有全部500个片段");
                Program.Check(AssetWindow.Descendants((DependencyObject)card.Content).OfType<TextBox>().Any(x => !x.IsReadOnly && x.Text == "独立草稿" + i), "实际追问输入保留独立草稿");
            }
            var afterStream = presentation.GetDiagnostics();
            Program.Check(afterStream.OwnedWindows == beforeStream.OwnedWindows && afterStream.CardWindows == 8, "流式更新不新建窗口");
            static double Percentile(IReadOnlyList<double> values, double percentile)
            { if (values.Count == 0) return 0; var sorted = values.Order().ToArray(); return sorted[Math.Clamp((int)Math.Ceiling(percentile * sorted.Length) - 1, 0, sorted.Length - 1)]; }
            var delays = inputIntervals.Select(x => Math.Max(0, x - 16)).ToArray();
            var frameIntervals = renderingTimes.Skip(1).Select((time, i) => time - renderingTimes[i]).ToArray();
            Program.Evidence.Add(new { Kind = "native-synthetic-stream", Results = 8, ChunksPerResult = 500,
                MillisecondsToQueueDrained = drainedMs, InstrumentationWindowMilliseconds = streamWatch.Elapsed.TotalMilliseconds,
                Scheduling = "每ID保留首条及语义转换，兼容的成功终态替换未发累计尾条；Background每次发布一条",
                CpuMilliseconds = streamCpuMs, Characters = expected.Sum(x => x.Length), Diagnostics = afterStream, Resources = Snapshot(),
                ProducerCompletedMilliseconds = producerCompletedMs,
                ThreadCpu = streamThreadsAfter.Select(x => new { ThreadId = x.Key, UiThread = x.Key == streamUiThread,
                    ProducerThread = x.Key == producerThread, PresentBefore = streamThreadsBefore.ContainsKey(x.Key),
                    Milliseconds = x.Value - streamThreadsBefore.GetValueOrDefault(x.Key) })
                    .Where(x => x.Milliseconds > 0 || x.UiThread || x.ProducerThread).OrderByDescending(x => x.Milliseconds).ToArray(),
                ThreadsMissingAtEnd = streamThreadsBefore.Keys.Except(streamThreadsAfter.Keys).ToArray(),
                ModelChanges = ids.Select((id, i) => new { Id = id, FirstTextMilliseconds = firstTextMs[i], FirstTextCharacters = firstTextLength[i],
                    CompleteMilliseconds = completedMs[i], Changes = modelChanges[i], FinalCharacters = expected[i].Length,
                    Publications = publications[i] }).ToArray(),
                InputPriorityProbe = new { ExpectedIntervalMilliseconds = 16, TickCount = inputIntervals.Count,
                    MaxDelayMilliseconds = delays.DefaultIfEmpty(0).Max(), P50DelayMilliseconds = Percentile(delays, .50),
                    P95DelayMilliseconds = Percentile(delays, .95), P99DelayMilliseconds = Percentile(delays, .99),
                    RawIntervalMilliseconds = inputIntervals, StoppedAfterMeasurement = !inputTimer.IsEnabled },
                CompositionRendering = new { EventCount = renderingTimes.Count, EventsBeforeQueueDrained = renderingTimes.Count(x => x <= drainedMs),
                    FirstEventMilliseconds = renderingTimes.Count == 0 ? (double?)null : renderingTimes[0],
                    MaxEventIntervalMilliseconds = frameIntervals.DefaultIfEmpty(0).Max(), RawEventMilliseconds = renderingTimes },
                Boundaries = new[] { "仅合成输入负载；Changed证明文本进入模型，Rendering事件不等同显示器呈现或GPU占用",
                    "Rendering订阅会促使WPF继续调度帧，数值包含观察开销", "16ms Input探针只存在于此验证器，已停止并解绑",
                    "线程CPU为整段区间差值，UI线程由8个结果共享，不能分摊为每ID成本；新增线程记可读生命周期CPU，结束前退出线程不在末次快照",
                    "发布阶段与长度在Changed中记录，不记录正文；线程快照在计时区间外采样，报告精度受操作系统CPU计时粒度限制" } });
            presentation.UpdateSourceWindow(new(hwnd, false, new(60, 60, 800, 600))); await Program.Idle();
            Program.Check(presentation.GetDiagnostics().CardWindows == 0 && presentation.GetDiagnostics().MarkerVisuals == 0, "来源隐藏时全部随之隐藏");
            presentation.UpdateSourceWindow(new(hwnd, true, new(90, 90, 800, 600))); await Program.Idle();
            Program.Check(presentation.GetDiagnostics().CardWindows == 8, "来源恢复后展开模式恢复");
            Program.Check(closed == 0, "收起和来源隐藏不发送删除回调");
            presentation.ClearResults(); await Program.Idle();
            Program.Check(watched == unwatched && presentation.GetDiagnostics().WatchedSourceWindows == 0, "同来源引用计数归零并停止观察");

            var many = Enumerable.Range(0, 10_000).Select(i => Program.Saved($"资产{i} 完整正文") with { Id = Guid.NewGuid(), CreatedAt = DateTimeOffset.Now.AddSeconds(-i) }).ToArray();
            presentation.UpdateAssets(many); presentation.ShowAssets(); presentation.ShowSettings(); await Program.Idle();
            var board = presentation.TestWindows.OfType<AssetWindow>().Single();
            var list = AssetWindow.Descendants((DependencyObject)board.Content).OfType<ListBox>().Single();
            Program.Check(board.RealizedRows > 0 && board.RealizedRows < 100, "一万条资产只实现视口附近条目");
            var scroll = AssetWindow.Descendants(list).OfType<ScrollViewer>().First();
            double beforeWrongScroll = scroll.VerticalOffset;
            list.ScrollIntoView(many[^1]); await Program.Idle(); list.UpdateLayout();
            var actualLast = list.Items.Cast<AssetRecord>().Single(x => x.Key == many[^1].Key);
            Program.Evidence.Add(new { Kind = "native-asset-old-object-scroll-reproduction", list.Items.Count,
                OldObjectIsItem = list.Items.Contains(many[^1]), OldObjectEqualsCurrent = actualLast == many[^1],
                TagArrayReferenceEqual = ReferenceEquals(actualLast.Tags, many[^1].Tags), StableKeyEqual = actualLast.Key == many[^1].Key,
                OldObjectHasContainer = list.ItemContainerGenerator.ContainerFromItem(many[^1]) is not null,
                BeforeOffset = beforeWrongScroll, AfterOffset = scroll.VerticalOffset, CurrentLastIndex = list.Items.IndexOf(actualLast) });
            Program.Check(!list.Items.Contains(many[^1]) && actualLast.Key == many[^1].Key && actualLast.Text == many[^1].Text,
                "旧对象因线程快照数组克隆不在列表，但稳定类型ID与全文一致");
            list.ScrollIntoView(actualLast); await Program.Idle(); list.UpdateLayout(); await Program.Idle();
            var lastContainer = list.ItemContainerGenerator.ContainerFromItem(actualLast) as ListBoxItem;
            Program.Evidence.Add(new { Kind = "native-asset-stable-key-scroll", LastKey = actualLast.Key.ToString(),
                LastIndex = list.Items.IndexOf(actualLast), HasContainer = lastContainer is not null, scroll.VerticalOffset, scroll.ExtentHeight,
                scroll.ViewportHeight, RealizedRows = board.RealizedRows });
            Program.Check(list.Items.Count == 10_000 && list.Items.IndexOf(actualLast) == 9_999 && lastContainer is not null,
                "实际列表的一万条末项在真实窗口生成容器");
            Program.Check(AssetWindow.Descendants(lastContainer!).OfType<TextBlock>().Any(x => x.Text == actualLast.Text), "末项容器实际显示完整资产9999正文");
            scroll.ScrollToTop(); await Program.Idle(); list.UpdateLayout();
            scroll.ScrollToEnd(); await Program.Idle(); list.UpdateLayout(); await Program.Idle();
            lastContainer = list.ItemContainerGenerator.ContainerFromItem(actualLast) as ListBoxItem;
            bool lastTextRealized = lastContainer is not null && AssetWindow.Descendants(lastContainer).OfType<TextBlock>().Any(x => x.Text == actualLast.Text);
            Rect? lastBounds = lastContainer?.TransformToAncestor(scroll).TransformBounds(new Rect(lastContainer.RenderSize));
            bool lastInViewport = lastBounds is { } bounds && bounds.Bottom > 0 && bounds.Top < scroll.ActualHeight;
            Program.Evidence.Add(new { Kind = "native-asset-scroll-to-end", HasContainer = lastContainer is not null,
                LastTextRealized = lastTextRealized, LastBounds = lastBounds, LastInViewport = lastInViewport,
                scroll.VerticalOffset, scroll.ScrollableHeight, scroll.ViewportHeight, RealizedRows = board.RealizedRows });
            Program.Check(lastTextRealized && lastInViewport && scroll.VerticalOffset > 0 && Math.Abs(scroll.VerticalOffset - scroll.ScrollableHeight) < 2,
                "从列表顶部滚到末尾后真实末项和正文可达");
            Program.Check(board.RealizedRows < 100, "滚至末项后仍保持虚拟化");
            Program.Check(presentation.TestWindows.OfType<SettingsWindow>().Single().Topmost == false && !board.Topmost, "设置和资产保持普通窗口层级");
            string retained = "资产9999";
            var search = AssetWindow.Descendants((DependencyObject)board.Content).OfType<TextBox>()
                .Single(x => AutomationProperties.GetName(x) == "搜索内容、标签或色值");
            search.Text = retained; board.Dismiss(); presentation.ShowAssets(); await Program.Idle();
            Program.Check(search.Text == retained && presentation.TestAssets.Query == retained && presentation.GetDiagnostics().AssetResults == 1, "重新打开资产保留实际搜索输入和结果");
            Program.Evidence.Add(new { Kind = "native-synthetic-assets", Records = 10_000, Diagnostics = presentation.GetDiagnostics(), Resources = Snapshot() });
        }
        finally { presentation.Dispose(); source.Close(); }
        await Program.Idle();
        var final = presentation.GetDiagnostics();
        Program.Check(final.ResultModels == 0 && final.MarkerWindows == 0 && final.OwnedWindows == 0 && final.ActiveUiTimers == 0, "释放后窗口模型和计时器全部回收");
        Program.Evidence.Add(new { Kind = "native-cleanup", Before = baseline, After = Snapshot(), Diagnostics = final });
        await ResultDispatchChecks.RunNative();
        Program.Passed("真实HWND标记、八路流式、来源显隐、资产虚拟化与释放");
    }
}
