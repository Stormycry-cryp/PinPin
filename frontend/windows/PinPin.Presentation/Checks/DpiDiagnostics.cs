using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using PinPin.Core;
using PinPin.Presentation.Controls;
using PinPin.Presentation.Models;
using PinPin.Presentation.Views;

namespace PinPin.Presentation.Checks;

/// Isolated comparisons for the offscreen harness; never used by the product.
internal static class DpiDiagnostics
{
    internal static void Run()
    {
        foreach (string appearance in new[] { "light", "dark" })
        {
            string path = Path.Combine(Program.Output, "dpi-theme-" + appearance + ".txt");
            File.WriteAllText(path, appearance);
            using var theme = new Theme(path);
            foreach (string variant in new[] { "fresh-display-gray", "reused-display-gray", "fresh-ideal-gray", "fresh-display-auto" })
            {
                var settings = new SettingsModel();
                settings.Receive(new(FeatureNames.All.Select(x => (ActionKind?)x).ToArray(), []));
                var window = new SettingsWindow(theme, settings, () => { }, _ => throw new InvalidOperationException("DPI对照意外创建HWND"));
                try { Sample((FrameworkElement)window.Content, 514, 294, false, $"settings-{appearance}-{variant}", variant); }
                finally { window.Close(); }
                Guid id = Guid.NewGuid();
                var state = new ResultState(id, ActionKind.Explain, Program.Anchor(id),
                    "机会成本是做出一个选择时，放弃的最好替代方案的价值。\n\n例如：你花一小时读书，就放弃了这一小时用于休息或工作的收益。它帮助你比较不同选择，而不只看花了多少钱。", false, true);
                var model = new ResultModel(state) { Mode = CardMode.Dialog };
                var card = new ResultWindow(theme, WheelSettings.Default, model, state.Anchor,
                    _ => throw new InvalidOperationException("DPI对照意外创建HWND"), () => { }, () => { }, () => { }, () => { }, () => { }, (_, _) => { }, _ => { });
                try { Sample((FrameworkElement)card.Content, 320, 0, true, $"answer-{appearance}-{variant}", variant); }
                finally { card.Close(); }
            }
        }
        Program.Passed("独立DPI字形缓存对照，不改变生产文字策略");
    }

    private static void Sample(FrameworkElement root, double width, double height, bool autoHeight, string name, string variant)
    {
        // Button.Content may be a logical child before its ContentPresenter is created.
        // Visit both trees so this diagnostic overrides local typography on every label.
        foreach (var node in AllNodes(root))
        {
            TextOptions.SetTextFormattingMode(node, variant.Contains("ideal") ? TextFormattingMode.Ideal : TextFormattingMode.Display);
            TextOptions.SetTextRenderingMode(node, variant.Contains("auto") ? TextRenderingMode.Auto : TextRenderingMode.Grayscale);
        }
        if (variant.StartsWith("reused")) Draw(1, "-100pct-first");
        Draw(2, "-200pct");
        void Draw(double scale, string suffix)
        {
            VisualTreeHelper.SetRootDpi(root, new DpiScale(scale, scale));
            if (autoHeight) { root.Measure(new Size(width, double.PositiveInfinity)); height = Math.Ceiling(root.DesiredSize.Height); }
            RenderChecks.Render(root, width, height, "dpi-" + name + suffix, scale, refreshTextDpi: false);
            var visuals = new[] { (Visual)root }.Concat(AssetWindow.Descendants(root).OfType<Visual>());
            var runs = visuals.SelectMany(visual => GlyphRuns(VisualTreeHelper.GetDrawing(visual)))
                .Select(run => new { run.PixelsPerDip, run.FontRenderingEmSize,
                    Family = string.Join("/", run.GlyphTypeface.FamilyNames.Values.Distinct()) })
                .Distinct().ToArray();
            Program.Evidence.Add(new { Kind = "dpi-glyph-diagnostic", Name = name + suffix, TargetScale = scale,
                RootScale = VisualTreeHelper.GetDpi(root).PixelsPerDip, Runs = runs,
                Boundary = "实际WPF GlyphRun元数据；只使用合成组件内容" });
        }
    }

    internal static IEnumerable<DependencyObject> AllNodes(DependencyObject root)
    {
        var seen = new HashSet<DependencyObject>();
        var pending = new Stack<DependencyObject>(); pending.Push(root);
        while (pending.TryPop(out var node))
        {
            if (!seen.Add(node)) continue;
            yield return node;
            foreach (object child in LogicalTreeHelper.GetChildren(node))
                if (child is DependencyObject dependency) pending.Push(dependency);
            if (node is Visual)
                for (int i = 0; i < VisualTreeHelper.GetChildrenCount(node); i++) pending.Push(VisualTreeHelper.GetChild(node, i));
        }
    }

    internal static IEnumerable<GlyphRun> GlyphRuns(Drawing? drawing)
    {
        if (drawing is GlyphRunDrawing glyph) yield return glyph.GlyphRun;
        if (drawing is DrawingGroup group)
            foreach (var child in group.Children)
                foreach (var run in GlyphRuns(child)) yield return run;
    }
}
