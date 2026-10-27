using System.IO;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using PinPin.Core;
using PinPin.Presentation.Controls;
using PinPin.Presentation.Models;
using PinPin.Presentation.Views;

namespace PinPin.Presentation.Checks;

internal static class RenderChecks
{
    internal static async Task Run()
    {
        foreach (string appearance in new[] { "light", "dark" })
        {
            string path = Path.Combine(Program.Output, "render-theme-" + appearance + ".txt");
            File.WriteAllText(path, appearance);
            using var theme = new Theme(path);
            var settings = new SettingsModel { Save = _ => Task.FromResult(true) };
            var window = new SettingsWindow(theme, settings, () => { }, _ => throw new InvalidOperationException("离屏验证意外创建HWND"));
            try
            {
                foreach (int count in new[] { 1, 4, 5, 8 })
                {
                    settings.Receive(WheelSettings.Default);
                    settings.Count(count); await Program.Idle();
                    Render((FrameworkElement)window.Content, 514, 294, $"settings-{count}-{appearance}");
                    Program.Check(new WindowInteropHelper(window).Handle == 0, "设置离屏渲染不创建HWND");
                    if (count == 4) Program.Check(settings.Value.Slots.SequenceEqual(WheelSettings.Default.Slots), "四格基准图保留完整默认功能");
                }
                settings.Receive(WheelSettings.Default);
                var trigger = AssetWindow.Descendants((DependencyObject)window.Content).OfType<MatteButton>()
                    .Single(x => AutomationProperties.GetAutomationId(x) == "wheel-trigger");
                trigger.RaiseEvent(new RoutedEventArgs(Button.ClickEvent)); await Program.Idle();
                Program.Check(!settings.Value.TriggerEnabled && AutomationProperties.GetName(trigger) == "轮盘触发：不触发",
                    "实际设置开关点击后更新关闭状态与辅助名称");
                Render((FrameworkElement)window.Content, 514, 294, $"settings-trigger-off-{appearance}");
                PolishChecks.Settings((FrameworkElement)window.Content, theme, settings.Value, appearance, "off");
                trigger.RaiseEvent(new RoutedEventArgs(Button.ClickEvent)); await Program.Idle();
                Program.Check(settings.Value.TriggerEnabled && AutomationProperties.GetName(trigger) == "轮盘触发：触发",
                    "实际设置开关再次点击开启且原生窗口不上屏");
                settings.Receive(new(FeatureNames.All.Select(action => (ActionKind?)action).ToArray(), []));
                Render((FrameworkElement)window.Content, 514, 294, $"settings-six-functions-{appearance}");
                PolishChecks.Settings((FrameworkElement)window.Content, theme, settings.Value, appearance, "on");
                settings.Receive(new([ActionKind.Save, null, null, null, null, null, null, null], []));
                Render((FrameworkElement)window.Content, 514, 294, $"settings-8-empty-slots-{appearance}");
                var wheel = AssetWindow.Descendants((DependencyObject)window.Content).OfType<WheelView>().Single();
                var preview = settings.Value.Copy(); preview.Slots[7] = ActionKind.PickColor;
                wheel.Configure(preview); wheel.PointTo(7);
                Render((FrameworkElement)window.Content, 514, 294, $"settings-drop-preview-{appearance}");
            }
            finally { window.Close(); }

            var assets = new AssetModel();
            assets.Receive([Program.Saved("如何把一个复杂概念解释清楚？先说明它解决什么问题，再用具体例子说明过程。"), Program.Color()]);
            var board = new AssetWindow(theme, assets, _ => throw new InvalidOperationException("离屏验证意外创建HWND"));
            try
            {
                Render((FrameworkElement)board.Content, 560, 500, $"assets-mixed-{appearance}");
                PolishChecks.Scales(() => new AssetWindow(theme, assets, _ => throw new InvalidOperationException("多DPI资产意外创建HWND")),
                    560, 500, $"assets-mixed-{appearance}");
                assets.Toggle(Program.Color().Key);
                // Offscreen elements are not Loaded; rebuild after the model's expansion changes.
                board.Repaint();
                Render((FrameworkElement)board.Content, 560, 500, $"assets-color-{appearance}");
                string fullText = string.Join("\n\n", Enumerable.Range(1, 40).Select(i => $"第{i:00}段：完整收藏正文必须保留，向下滚动应当能读到最后一段。"));
                assets.Receive([Program.Saved(fullText)]); assets.Toggle(Program.Saved().Key); board.Repaint();
                Render((FrameworkElement)board.Content, 560, 500, $"assets-long-top-{appearance}");
                var list = AssetWindow.Descendants((DependencyObject)board.Content).OfType<ListBox>().Single();
                var scroll = AssetWindow.Descendants(list).OfType<ScrollViewer>().First();
                scroll.ScrollToEnd(); list.UpdateLayout(); await Program.Idle();
                Render((FrameworkElement)board.Content, 560, 500, $"assets-long-bottom-{appearance}");
                var text = AssetWindow.Descendants(list).OfType<TextBox>().First(x => x.Text == fullText);
                Program.Check(text.Text.EndsWith("最后一段。") && text.ActualHeight > 800, "完整40段参与真实组件布局");
                Program.Check(scroll.VerticalOffset > 500, "完整正文可滚动到下方");
                Program.Evidence.Add(new { Kind = "offscreen-long-text", Appearance = appearance, Characters = fullText.Length,
                    TextHeight = text.ActualHeight, scroll.VerticalOffset, scroll.ExtentHeight, scroll.ViewportHeight });
                assets.Search("没有这个搜索结果"); board.Repaint(); Render((FrameworkElement)board.Content, 560, 500, $"assets-no-match-{appearance}");
                assets.Receive([]); Render((FrameworkElement)board.Content, 560, 500, $"assets-empty-{appearance}");
                Program.Check(new WindowInteropHelper(board).Handle == 0, "资产离屏渲染不创建HWND");
            }
            finally { board.Close(); }

            var id = Guid.NewGuid();
            var samples = new (string Name, ResultState State, CardMode Mode)[]
            {
                ("answer-short", new(id, ActionKind.Explain, Program.Anchor(id), "机会成本是做出一个选择时，放弃的最好替代方案的价值。", false, true), CardMode.Short),
                ("answer-dialog", new(id, ActionKind.Explain, Program.Anchor(id), "机会成本是做出一个选择时，放弃的最好替代方案的价值。\n\n例如：你花一小时读书，就放弃了这一小时用于休息或工作的收益。它帮助你比较不同选择，而不只看花了多少钱。", false, true), CardMode.Dialog),
                ("reply-coach-dialog", new(id, ActionKind.ReplyCoach, Program.Anchor(id), "对方想确认进度，也希望知道什么时候能收到结果。可以先说明当前进展，再给出明确时间。\n\n可以回复：我已经整理好主要内容，正在核对细节，今天下午四点前发给你。", false, true), CardMode.Dialog),
                ("answer-loading", new(id, ActionKind.Translate, Program.Anchor(id)), CardMode.Short),
                ("answer-failed", new(id, ActionKind.Explain, Program.Anchor(id), Error: "请求暂时失败，请重试。", IsLoading: false), CardMode.Short),
                ("color-save-failed", new(id, ActionKind.PickColor, Program.Anchor(id), IsLoading: false, IsComplete: true, Color: Program.Color().Color, ColorPersistence: PersistenceState.Failed), CardMode.Short),
                ("saved-dialog", new(id, ActionKind.Save, Program.Anchor(id), IsLoading: false, IsComplete: true, Saved: Program.Saved()), CardMode.Dialog)
            };
            foreach (var sample in samples)
            {
                var model = new ResultModel(sample.State) { Mode = sample.Mode };
                ResultWindow CreateCard() => new(theme, WheelSettings.Default, model, sample.State.Anchor, _ => throw new InvalidOperationException("离屏验证意外创建HWND"),
                    () => { }, () => { }, () => { }, () => { }, () => { }, (_, _) => { }, _ => { });
                var card = CreateCard();
                try
                {
                    var content = (FrameworkElement)card.Content;
                    VisualTreeHelper.SetRootDpi(content, new DpiScale(2, 2));
                    content.Measure(new Size(320, double.PositiveInfinity));
                    Render(content, 320, Math.Ceiling(content.DesiredSize.Height), $"{sample.Name}-{appearance}");
                    if (sample.Name is "answer-dialog" or "answer-short")
                        PolishChecks.Scales(CreateCard, 320, 0, $"{sample.Name}-{appearance}", sizeToContent: true);
                    Program.Check(new WindowInteropHelper(card).Handle == 0, "回答离屏渲染不创建HWND");
                }
                finally { card.Close(); }
            }
            PolishChecks.Gateway(theme, appearance);
            var gesture = new WheelView(theme); gesture.Configure(WheelSettings.Default); gesture.PointTo(1);
            Render(gesture, 180, 180, $"wheel-selected-{appearance}");
            gesture.Configure(new(FeatureNames.All.Select(action => (ActionKind?)action).ToArray(), [])); gesture.PointTo(5);
            Render(gesture, 180, 180, $"wheel-six-functions-{appearance}");
        }
        Program.Passed("生产WPF组件浅深色离屏渲染与完整正文滚动");
    }

    internal static void Render(FrameworkElement content, double width, double height, string name, double scale = 2, bool refreshTextDpi = true)
    {
        VisualTreeHelper.SetRootDpi(content, new DpiScale(scale, scale));
        content.Measure(new Size(width, height)); content.Arrange(new Rect(0, 0, width, height)); content.UpdateLayout();
        if (refreshTextDpi)
        {
            // Offscreen trees have no HwndTarget to propagate DPI into template/virtualized
            // children created during Measure. Reapply after they exist, and invalidate the
            // text line caches through their public formatting property. The final mode is
            // unchanged; this never runs in the product or its streaming update path.
            VisualTreeHelper.SetRootDpi(content, new DpiScale(scale, scale));
            foreach (var node in DpiDiagnostics.AllNodes(content).Where(x => x is TextBlock or TextBox or PasswordBox))
            {
                var mode = TextOptions.GetTextFormattingMode(node);
                TextOptions.SetTextFormattingMode(node, mode == TextFormattingMode.Ideal ? TextFormattingMode.Display : TextFormattingMode.Ideal);
                TextOptions.SetTextFormattingMode(node, mode);
            }
            content.Measure(new Size(width, height)); content.Arrange(new Rect(0, 0, width, height)); content.UpdateLayout();
        }
        var bitmap = new RenderTargetBitmap((int)Math.Ceiling(width * scale), (int)Math.Ceiling(height * scale), 96 * scale, 96 * scale, PixelFormats.Pbgra32);
        bitmap.Render(content);
        if (content is MatteSurface { WindowFrame: true })
        {
            var corner = new byte[4]; var top = new byte[4];
            bitmap.CopyPixels(new Int32Rect(0, 0, 1, 1), corner, 4, 0);
            bitmap.CopyPixels(new Int32Rect(bitmap.PixelWidth / 2, (int)Math.Ceiling(3 * scale), 1, 1), top, 4, 0);
            Program.Check(corner[3] == 0 && top[3] == 255, "窗口圆角外透明且面板边缘内侧完整不漏底");
        }
        var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(bitmap));
        string path = Path.Combine(Program.Output, name + ".png"); using var output = File.Create(path); encoder.Save(output);
        Program.Evidence.Add(new { Kind = "offscreen-production-component", Name = name, Width = width, Height = height, PixelScale = scale, Path = path });
    }
}
