using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using PinPin.Core;
using PinPin.Presentation.Models;
using PinPin.Presentation.Controls;
using PinPin.Presentation.Views;

namespace PinPin.Presentation.Checks;

internal static class PolishChecks
{
    private static IEnumerable<MatteButton> Buttons(FrameworkElement root)
        => AssetWindow.Descendants(root).OfType<MatteButton>().Where(x => x.IsVisible || x.Visibility == Visibility.Visible);

    internal static void Scales(Func<Window> create, double width, double height, string name, bool sizeToContent = false)
    {
        foreach (double scale in new[] { 1d, 1.25, 1.5, 2 })
        {
            var window = create();
            try
            {
                var root = (FrameworkElement)window.Content;
                VisualTreeHelper.SetRootDpi(root, new DpiScale(scale, scale));
                if (sizeToContent)
                { root.Measure(new Size(width, double.PositiveInfinity)); height = Math.Ceiling(root.DesiredSize.Height); }
                RenderChecks.Render(root, width, height, $"{name}-{(int)(scale * 100)}pct", scale);
                foreach (var button in Buttons(root).Where(x => x.ActualWidth > 0 && x.ActualHeight > 0))
                {
                    foreach (var child in AssetWindow.Descendants(button).OfType<FrameworkElement>()
                        .Where(x => x is TextBlock or Glyph))
                    {
                        if (child.Visibility != Visibility.Visible || child.ActualWidth <= 0 || child.ActualHeight <= 0) continue;
                        Rect rect = child.TransformToAncestor(button).TransformBounds(new Rect(child.RenderSize));
                        Program.Check(rect.Left >= -1 && rect.Top >= -1 && rect.Right <= button.ActualWidth + 1 && rect.Bottom <= button.ActualHeight + 1,
                            $"{name} {scale:P0} 按钮文字与图标位于点击区域内");
                    }
                }
                Program.Evidence.Add(new { Kind = "polish-layout-scale", Name = name, Scale = scale,
                    Width = root.ActualWidth, Height = root.ActualHeight, Boundary = "每种DPI创建新生产组件，先设DPI再首次排版；不代表真实混合DPI移动" });
                var runs = new[] { (Visual)root }.Concat(AssetWindow.Descendants(root).OfType<Visual>())
                    .SelectMany(visual => DpiDiagnostics.GlyphRuns(VisualTreeHelper.GetDrawing(visual))).ToArray();
                Program.Check(runs.Length > 0 && runs.All(run => Math.Abs(run.PixelsPerDip - scale) < .001),
                    $"{name} 目标DPI与实际字形DPI一致");
                Program.Evidence.Add(new { Kind = "polish-glyph-dpi", Name = name, Scale = scale,
                    PixelsPerDip = runs.Select(x => x.PixelsPerDip).Distinct().ToArray(),
                    Boundary = "字形DPI一致仍须人工查看文字清晰度" });
            }
            finally { window.Close(); }
        }
    }

    internal static void Settings(FrameworkElement root, Theme theme, WheelSettings settings, string appearance, string state)
    {
        Window Create()
        {
            var model = new SettingsModel(); model.Receive(settings);
            return new SettingsWindow(theme, model, () => { }, _ => throw new InvalidOperationException("多DPI设置意外创建HWND"));
        }
        Scales(Create, 514, 294, $"settings-trigger-{state}-{appearance}");
        var trigger = Buttons(root).Single(x => AutomationProperties.GetAutomationId(x) == "wheel-trigger");
        var label = AssetWindow.Descendants(trigger).OfType<TextBlock>().Single();
        var glyph = AssetWindow.Descendants(trigger).OfType<Glyph>().Single();
        var labelBounds = label.TransformToAncestor(trigger).TransformBounds(new Rect(label.RenderSize));
        var glyphBounds = glyph.TransformToAncestor(trigger).TransformBounds(new Rect(glyph.RenderSize));
        Program.Check(Math.Abs(labelBounds.Top + labelBounds.Height / 2 - trigger.ActualHeight / 2) <= 1,
            "触发开关单行文字垂直居中");
        Program.Check(Math.Abs(glyphBounds.Top + glyphBounds.Height / 2 - trigger.ActualHeight / 2) <= 1,
            "触发开关图标与文字同中心线");
        Program.Check(labelBounds.Width >= 33 && label.TextWrapping == TextWrapping.NoWrap, "不触发三个汉字具有完整单行宽度");
        var features = Buttons(root).Where(x => x.Width == 42 && x.Height == 42).ToArray();
        Program.Check(features.Length == 6, "精修保留六个真实功能块");
        foreach (var button in features)
        {
            var name = AssetWindow.Descendants(button).OfType<TextBlock>().Single();
            var icon = AssetWindow.Descendants(button).OfType<Glyph>().Single();
            double y = name.TransformToAncestor(button).Transform(new Point()).Y;
            double iconY = icon.TransformToAncestor(button).Transform(new Point()).Y;
            Program.Check(Math.Abs(y - 24) <= 1 && Math.Abs(iconY - 6) <= 1, "所有功能块使用相同图标与名称纵向位置");
        }
        Program.Evidence.Add(new { Kind = "polish-settings-alignment", Appearance = appearance, State = state,
            LabelBounds = labelBounds.ToString(), GlyphBounds = glyphBounds.ToString(), Font = label.FontFamily.Source,
            Language = label.Language.IetfLanguageTag });
    }

    internal static void Gateway(Theme theme, string appearance)
    {
        int calls = 0; bool accept = false;
        var window = new GatewaySetupWindow(theme, "https://example.invalid", value =>
        {
            calls++;
            Program.Check(value.GatewayBaseUrl == "https://example.invalid" && value.AccessToken.Length > 0,
                "连接小窗只在保存时向宿主交付填写值");
            return accept;
        });
        var root = (FrameworkElement)window.Content;
        var password = AssetWindow.Descendants(root).OfType<PasswordBox>().Single();
        Scales(() => new GatewaySetupWindow(theme, "https://example.invalid", _ => false),
            360, 0, $"gateway-setup-{appearance}", sizeToContent: true);
        VisualTreeHelper.SetRootDpi(root, new DpiScale(2, 2));
        root.Measure(new Size(360, double.PositiveInfinity));
        RenderChecks.Render(root, 360, Math.Ceiling(root.DesiredSize.Height), $"gateway-interaction-{appearance}");
        var save = Buttons(root).Single(x => AutomationProperties.GetAutomationId(x) == "gateway-save");
        save.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        Program.Check(calls == 0, "未填令牌不调用保存");
        password.Password = "synthetic-token-for-ui-check-only";
        save.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        Program.Check(calls == 1 && !window.Accepted, "宿主拒绝保存时仍可继续编辑");
        Program.Check(!AssetWindow.Descendants(root).OfType<TextBox>().Any(x => x.Text.Contains("synthetic-token")),
            "访问令牌不进入普通文本框");
        RenderChecks.Render(root, 360, Math.Ceiling(root.DesiredSize.Height), $"gateway-save-failed-{appearance}");
        accept = true; save.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        using (var secure = password.SecurePassword)
            Program.Check(calls == 2 && window.Accepted && secure.Length == 0, "成功保存关闭并清空密码框");
        Program.Check(new WindowInteropHelper(window).Handle == 0, "连接小窗离屏检查不创建HWND");
        var skipped = new GatewaySetupWindow(theme, "", _ => throw new InvalidOperationException("跳过不应保存"));
        var skippedRoot = (FrameworkElement)skipped.Content;
        skippedRoot.Measure(new Size(360, 320)); skippedRoot.Arrange(new Rect(0, 0, 360, 320)); skippedRoot.UpdateLayout();
        var skippedPassword = AssetWindow.Descendants(skippedRoot).OfType<PasswordBox>().Single();
        skippedPassword.Password = "synthetic-skipped-token";
        Buttons(skippedRoot).Single(x => AutomationProperties.GetAutomationId(x) == "gateway-later")
            .RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        using (var secure = skippedPassword.SecurePassword)
            Program.Check(!skipped.Accepted && secure.Length == 0, "稍后设置关闭且清空密码框");
        Program.Passed("Windows单行排版、多比例离屏与AI连接小窗");
    }
}
