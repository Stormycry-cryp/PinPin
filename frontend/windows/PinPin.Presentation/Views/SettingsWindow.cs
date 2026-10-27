using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;
using PinPin.Core;
using PinPin.Presentation.Controls;
using PinPin.Presentation.Models;

namespace PinPin.Presentation.Views;

internal sealed class SettingsWindow : MatteWindow
{
    private readonly Theme theme;
    private readonly SettingsModel model;
    private readonly Action showAssets;
    private Canvas canvas = null!;
    private WheelView wheel = null!;
    private ContentControl right = null!;
    private TextBlock countText = null!, failureText = null!;
    private MatteButton minus = null!, plus = null!, retry = null!;
    private MatteButton trigger = null!;
    private TextBlock triggerText = null!;
    private Glyph triggerGlyph = null!;
    private ActionKind? editing;
    private DragState? drag;
    private MatteSurface? ghost;
    private string? appearanceFailure;
    private sealed record DragState(ActionKind Action, int? Source, Point Start, bool Active = false);

    public SettingsWindow(Theme theme, SettingsModel model, Action showAssets, Action<nint> ownWindow)
        : base("PinPin 设置", false, ownWindow)
    {
        this.theme = theme; this.model = model; this.showAssets = showAssets;
        Width = 514; Height = 294;
        EscapePressed = () => { if (drag is not null) CancelDrag(); else Dismiss(); };
        model.Changed += ModelChanged;
        theme.SaveFailed += AppearanceFailed;
        PreviewMouseMove += MouseMoved;
        PreviewMouseLeftButtonUp += MouseReleased;
        LostMouseCapture += (_, _) => { if (drag is not null) CancelDrag(); };
        Build();
        Closed += (_, _) => { model.Changed -= ModelChanged; theme.SaveFailed -= AppearanceFailed; };
    }
    public void Open()
    {
        editing = null; CancelDrag(); BuildRight(); wheel.Edit(null);
        if (!IsVisible) { if (PhysicalPlacement is null) ShowCentered(514, 294); else { Show(); Activate(); } }
        else Activate();
    }
    public void Dismiss() { CancelDrag(); Hide(); }
    public void Repaint() { CancelDrag(); Build(); }
    private void AppearanceFailed(string message) { appearanceFailure = message; ModelChanged(); }

    private void Build()
    {
        var p = theme.Palette;
        canvas = new Canvas { Width = 514, Height = 294 };
        Ui.ApplyScrollTheme(canvas, p);
        Content = new MatteSurface(p) { WindowFrame = true, Radius = 18, Child = canvas };
        wheel = new WheelView(theme, true); wheel.Configure(model.Value); wheel.Edit(editing);
        Place(wheel, 24, 24); wheel.PreviewMouseLeftButtonDown += WheelDown;
        wheel.MouseRightButtonUp += WheelMenu;
        right = new ContentControl { Width = 226, Height = 170 };
        Place(right, 264, 62);
        var count = new StackPanel { Orientation = Orientation.Horizontal };
        minus = Ui.IconButton(p, "minus", "减少格数", () => model.Count(model.Value.Slots.Length - 1), 22);
        plus = Ui.IconButton(p, "plus", "增加格数", () => model.Count(model.Value.Slots.Length + 1), 22);
        minus.Bare = plus.Bare = true; minus.Width = plus.Width = 24;
        countText = Ui.Label(model.Value.Slots.Length + " 格", p, 11.5, ink: p.Secondary);
        System.Windows.Documents.Typography.SetNumeralAlignment(countText, FontNumeralAlignment.Tabular);
        countText.Width = 38; countText.TextAlignment = TextAlignment.Center; countText.VerticalAlignment = VerticalAlignment.Center;
        count.Children.Add(minus); count.Children.Add(countText); count.Children.Add(plus);
        var counter = Ui.InputWell(p, count, 11, new Thickness(2, 0, 2, 0)); counter.Height = 22;
        Place(counter, 44, 248);
        triggerText = Ui.Label("", p, 11); triggerText.Width = 36;
        triggerText.VerticalAlignment = VerticalAlignment.Center; triggerText.TextAlignment = TextAlignment.Center;
        triggerGlyph = new Glyph("check", p.Ink, 10) { Width = 10, Margin = new Thickness(0, 0, 4, 0), VerticalAlignment = VerticalAlignment.Center };
        var triggerContent = new StackPanel { Orientation = Orientation.Horizontal };
        triggerContent.Children.Add(triggerGlyph); triggerContent.Children.Add(triggerText);
        trigger = new MatteButton(p, "轮盘触发") { Width = 74, Height = 22, Radius = 11, Depth = 1.3, Content = triggerContent };
        AutomationProperties.SetAutomationId(trigger, "wheel-trigger");
        trigger.Click += (_, _) => model.Trigger(!model.Value.TriggerEnabled);
        Place(trigger, 142, 248);
        var dragArea = new Border { Width = 264, Height = 24, Background = Brushes.Transparent };
        dragArea.MouseLeftButtonDown += (_, e) => { if (e.LeftButton == MouseButtonState.Pressed) { DragMove(); e.Handled = true; } };
        Place(dragArea, 70, 0);
        Place(Ui.IconButton(p, theme.Dark ? "sun" : "moon", theme.Dark ? "切换为浅色" : "切换为深色", theme.Toggle), 10, 10);
        Place(Ui.IconButton(p, "assets", "资产看板", showAssets), 38, 10);
        Place(Ui.IconButton(p, "close", "关闭设置", Dismiss), 482, 10);
        failureText = Ui.Text("", p, 11, ink: p.Secondary); failureText.Width = 100;
        Place(failureText, 338, 14);
        retry = Ui.IconButton(p, "retry", "重试保存", model.Retry); Place(retry, 446, 10);
        BuildRight(); ModelChanged();
    }
    private void Place(UIElement element, double x, double y)
    { Canvas.SetLeft(element, x); Canvas.SetTop(element, y); canvas.Children.Add(element); }
    private void ModelChanged()
    {
        if (drag is null) wheel.Configure(model.Value);
        wheel.Edit(editing);
        countText.Text = model.Value.Slots.Length + " 格";
        minus.IsEnabled = model.Value.Slots.Length > 1; plus.IsEnabled = model.Value.Slots.Length < 8;
        bool enabled = model.Value.TriggerEnabled;
        trigger.Selected = enabled; triggerText.Text = enabled ? "触发" : "不触发";
        triggerText.Foreground = enabled ? theme.Palette.Ink : theme.Palette.Secondary;
        triggerText.FontWeight = FontWeights.Normal;
        triggerGlyph.NameOfIcon = enabled ? "check" : "minus";
        triggerGlyph.Ink = enabled ? theme.Palette.Ink : theme.Palette.Secondary; triggerGlyph.InvalidateVisual();
        trigger.ToolTip = $"{(enabled ? "关闭" : "开启")}轮盘触发；Alt + 右键仍可打开设置";
        AutomationProperties.SetName(trigger, $"轮盘触发：{triggerText.Text}");
        AutomationProperties.SetHelpText(trigger, "仅控制轮盘触发，设置快捷键始终可用");
        failureText.Text = drag is null ? (model.SaveFailed ? "没能保存" : appearanceFailure ?? "") : "";
        retry.Visibility = model.SaveFailed && drag is null ? Visibility.Visible : Visibility.Collapsed;
        if (drag is null) BuildRight();
    }
    private void BuildRight()
    {
        var p = theme.Palette;
        if (editing is not { } action)
        {
            var blocks = new Canvas { Width = 226, Height = Math.Max(170, Math.Ceiling(FeatureNames.All.Length / 4d) * 56 + 2) };
            for (int i = 0; i < FeatureNames.All.Length; i++)
            {
                var kind = FeatureNames.All[i];
                var stack = new Grid { Width = 42, Height = 42 };
                var glyph = new Glyph(MatteDrawing.Icon(kind), p.Feature(kind, model.Value), 15)
                    { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 6, 0, 0) };
                stack.Children.Add(glyph);
                var name = Ui.Label(FeatureNames.Name(kind), p, 8.5, ink: p.Secondary);
                name.Margin = new Thickness(2, 24, 2, 0); name.VerticalAlignment = VerticalAlignment.Top; name.TextAlignment = TextAlignment.Center;
                stack.Children.Add(name);
                var button = new MatteButton(p, $"{FeatureNames.Name(kind)}：拖入轮盘，点按调整颜色") { Width = 42, Height = 42, Radius = 10, Depth = 2.2, Content = stack };
                button.PreviewMouseLeftButtonDown += (_, e) => { BeginDrag(kind, null, e.GetPosition(canvas)); e.Handled = true; };
                button.Click += (_, _) => OpenColor(kind);
                button.ContextMenu = AssignmentMenu(kind);
                Canvas.SetLeft(button, 8 + (i % 4) * 56); Canvas.SetTop(button, 8 + (i / 4) * 56); blocks.Children.Add(button);
            }
            right.Content = new ScrollViewer { Content = blocks, VerticalScrollBarVisibility = ScrollBarVisibility.Hidden,
                HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, PanningMode = PanningMode.VerticalOnly };
            return;
        }
        var colorPanel = new StackPanel { Width = 114, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        var header = new StackPanel { Orientation = Orientation.Horizontal, Height = 22 };
        header.Children.Add(Ui.IconButton(p, "back", "返回功能库", () => { editing = null; wheel.Edit(null); BuildRight(); }));
        header.Children.Add(new Glyph(MatteDrawing.Icon(action), p.Feature(action, model.Value), 15) { Margin = new Thickness(7, 0, 5, 0), VerticalAlignment = VerticalAlignment.Center });
        header.Children.Add(Ui.Label(FeatureNames.Name(action), p, 12, true)); colorPanel.Children.Add(header);
        var swatches = new Canvas { Width = 114, Height = 54, Margin = new Thickness(0, 16, 0, 0) };
        var current = model.Value.Colors.GetValueOrDefault(action) ?? Palette.Default(action);
        for (int i = 0; i < Palette.Swatches.Length; i++)
        {
            var color = Palette.ColorValue(Palette.Swatches[i]); var sample = model.Value.Copy(); sample.Colors[action] = color;
            var dot = new Ellipse { Width = 13, Height = 13, Fill = p.Feature(action, sample) };
            var button = new MatteButton(p, $"颜色 #{color.Red:X2}{color.Green:X2}{color.Blue:X2}")
                { Width = 22, Height = 22, Radius = 11, Selected = current == color, Content = dot };
            if (current == color) { dot.Stroke = p.Ink; dot.StrokeThickness = 1.2; }
            button.Click += (_, _) => model.Color(action, color);
            Canvas.SetLeft(button, (i % 4) * (92d / 3)); Canvas.SetTop(button, (i / 4) * 32); swatches.Children.Add(button);
        }
        colorPanel.Children.Add(swatches);
        if (!Palette.Swatches.Select(Palette.ColorValue).Contains(current))
        {
            var custom = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 8, 0, 0) };
            custom.Children.Add(new Ellipse { Width = 13, Height = 13, Fill = p.Feature(action, model.Value), Stroke = p.Ink, StrokeThickness = 1 });
            var customName = Ui.Label("自定义颜色", p, 10.5, ink: p.Secondary); customName.Margin = new Thickness(5, 0, 0, 0);
            custom.Children.Add(customName); colorPanel.Children.Add(custom);
        }
        right.Content = colorPanel;
    }
    private ContextMenu AssignmentMenu(ActionKind kind)
    {
        var menu = new ContextMenu();
        for (int i = 0; i < model.Value.Slots.Length; i++)
        { int slot = i; var item = new MenuItem { Header = $"放入第{i + 1}格" }; item.Click += (_, _) => model.Assign(slot, kind); menu.Items.Add(item); }
        var color = new MenuItem { Header = "调整颜色" }; color.Click += (_, _) => OpenColor(kind); menu.Items.Add(color); return menu;
    }
    private void WheelMenu(object sender, MouseButtonEventArgs e)
    {
        int? slot = wheel.Hit(e.GetPosition(wheel), true); if (slot is null) return;
        var menu = new ContextMenu();
        foreach (var kind in FeatureNames.All)
        { var item = new MenuItem { Header = FeatureNames.Name(kind) }; item.Click += (_, _) => model.Assign(slot.Value, kind); menu.Items.Add(item); }
        var remove = new MenuItem { Header = "移出格子" }; remove.Click += (_, _) => model.Assign(slot.Value, null); menu.Items.Add(remove);
        wheel.ContextMenu = menu; menu.IsOpen = true; e.Handled = true;
    }
    private void OpenColor(ActionKind kind) { editing = kind; wheel.Edit(kind); BuildRight(); }
    private void WheelDown(object sender, MouseButtonEventArgs e)
    {
        int? slot = wheel.Hit(e.GetPosition(wheel), true);
        if (slot is { } index && model.Value.Slots[index] is { } action)
        { BeginDrag(action, index, e.GetPosition(canvas)); e.Handled = true; }
    }
    private void BeginDrag(ActionKind action, int? slot, Point at)
    { drag = new(action, slot, at); canvas.CaptureMouse(); }
    private void MouseMoved(object sender, MouseEventArgs e)
    {
        if (drag is not { } current || e.LeftButton != MouseButtonState.Pressed) return;
        Point at = e.GetPosition(canvas);
        if (!current.Active && (at - current.Start).Length < 3) return;
        if (!current.Active)
        {
            drag = current = current with { Active = true };
            ghost = new(theme.Palette) { Width = 34, Height = 34, Radius = 17, IsHitTestVisible = false,
                Child = new Glyph(MatteDrawing.Icon(current.Action), theme.Palette.Feature(current.Action, model.Value), 15)
                    { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center } };
            canvas.Children.Add(ghost); Panel.SetZIndex(ghost, 10);
        }
        Canvas.SetLeft(ghost!, at.X - 17); Canvas.SetTop(ghost!, at.Y - 17);
        var local = new Point(at.X - 24, at.Y - 24);
        int? target = wheel.Hit(local, true);
        var preview = SettingsModel.Drop(model.Value, current.Action, current.Source, target, !wheel.InTray(local));
        wheel.Configure(preview); wheel.PointTo(target); wheel.Edit(null);
        failureText.Text = ""; retry.Visibility = Visibility.Collapsed;
        e.Handled = true;
    }
    private void MouseReleased(object sender, MouseButtonEventArgs e)
    {
        if (drag is not { } current) return;
        Point at = e.GetPosition(canvas); var local = new Point(at.X - 24, at.Y - 24);
        var next = current.Active ? SettingsModel.Drop(model.Value, current.Action, current.Source, wheel.Hit(local, true), !wheel.InTray(local)) : null;
        CancelDrag();
        if (next is not null) model.Apply(next); else OpenColor(current.Action);
        e.Handled = true;
    }
    private void CancelDrag()
    {
        drag = null;
        if (ghost is not null) { canvas.Children.Remove(ghost); ghost = null; }
        if (canvas.IsMouseCaptured) canvas.ReleaseMouseCapture();
        wheel.Configure(model.Value); wheel.Edit(editing); ModelChanged();
    }
}
