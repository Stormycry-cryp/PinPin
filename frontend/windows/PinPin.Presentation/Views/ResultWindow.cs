using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using PinPin.Core;
using PinPin.Presentation.Controls;
using PinPin.Presentation.Models;

namespace PinPin.Presentation.Views;

internal sealed class ResultWindow : MatteWindow
{
    private readonly Theme theme;
    private WheelSettings settings;
    private readonly ResultModel model;
    private TargetAnchor anchor;
    private readonly Action collapse, expand, close, showAssets, clear;
    private readonly Action<Guid, string>? followup;
    private readonly Action<AssetEdit> edit;
    private readonly DispatcherTimer leaveTimer, noticeTimer;
    private StackPanel root = null!;
    private TextBlock title = null!, subtitle = null!, question = null!, error = null!, notice = null!, colorStatus = null!;
    private TextBox answer = null!, input = null!;
    private FrameworkElement skeleton = null!;
    private ContentControl special = null!;
    private FrameworkElement followupRow = null!;
    private MatteButton send = null!, copyButton = null!, collapseButton = null!, assetsButton = null!, removeSaved = null!;
    private Glyph feature = null!;
    private string? specialSignature;
    private bool syncingDraft;
    public Guid ResultId => model.Id;
    public int ActiveTimers => (leaveTimer.IsEnabled ? 1 : 0) + (noticeTimer.IsEnabled ? 1 : 0);

    public ResultWindow(Theme theme, WheelSettings settings, ResultModel model, TargetAnchor anchor,
        Action<nint> ownWindow, Action collapse, Action expand, Action close, Action showAssets,
        Action clear, Action<Guid, string>? followup, Action<AssetEdit> edit)
        : base("PinPin " + FeatureNames.Name(model.State.Action), true, ownWindow)
    {
        this.theme = theme; this.settings = settings; this.model = model; this.anchor = anchor;
        this.collapse = collapse; this.expand = expand; this.close = close; this.showAssets = showAssets;
        this.clear = clear; this.followup = followup; this.edit = edit;
        Width = 320; SizeToContent = SizeToContent.Height;
        leaveTimer = new DispatcherTimer(DispatcherPriority.Input, Dispatcher) { Interval = TimeSpan.FromMilliseconds(350) };
        leaveTimer.Tick += LeaveTick;
        noticeTimer = new DispatcherTimer(DispatcherPriority.Background, Dispatcher) { Interval = TimeSpan.FromMilliseconds(1600) };
        noticeTimer.Tick += NoticeTick;
        model.Changed += UpdateContent;
        SizeChanged += (_, _) => PlaceAtAnchor();
        MouseEnter += (_, _) => leaveTimer.Stop();
        MouseLeave += (_, _) => { if (model.Peek && model.Mode == CardMode.Short) leaveTimer.Start(); };
        Deactivated += (_, _) => { if (model.Mode == CardMode.Short && string.IsNullOrWhiteSpace(model.Draft)) collapse(); };
        EscapePressed = () => { if (model.IsFailure) close(); else collapse(); };
        PreviewMouseLeftButtonDown += (_, e) =>
        {
            if (model.Mode == CardMode.Dialog && IsEditableTarget(e.OriginalSource as DependencyObject))
            { AllowInputActivation = true; Activate(); }
        };
        MouseLeftButtonUp += (_, e) => { if (model.Mode == CardMode.Short && !model.IsFailure && !e.Handled) { expand(); e.Handled = true; } };
        Closed += (_, _) =>
        {
            model.Changed -= UpdateContent;
            leaveTimer.Stop(); noticeTimer.Stop(); leaveTimer.Tick -= LeaveTick; noticeTimer.Tick -= NoticeTick;
        };
        Build();
    }

    private static bool IsEditableTarget(DependencyObject? value)
    {
        while (value is not null)
        { if (value is TextBox) return true; value = value is Visual ? VisualTreeHelper.GetParent(value) : null; }
        return false;
    }
    private void LeaveTick(object? sender, EventArgs e) { leaveTimer.Stop(); if (model.Peek && model.Mode == CardMode.Short) collapse(); }
    private void NoticeTick(object? sender, EventArgs e) { noticeTimer.Stop(); notice.Text = ""; }

    public void Open()
    {
        UpdateContent();
        // One measurement at first open. Streaming relies on WPF's normal layout, never UpdateLayout per packet.
        root.Measure(new Size(296, double.PositiveInfinity));
        double height = Math.Max(54, root.DesiredSize.Height + 24);
        var rect = AnchoredRect(height);
        ShowPhysical(rect);
    }
    public void SetMode() { leaveTimer.Stop(); UpdateContent(); }
    public void SetAnchor(TargetAnchor value) { anchor = value; PlaceAtAnchor(); }
    public void Repaint(WheelSettings value) { settings = value; Build(); }
    public void Recolor(WheelSettings value)
    { settings = value; feature.Ink = theme.Palette.Feature(model.State.Action, settings); feature.InvalidateVisual(); }

    private ScreenRect AnchoredRect(double height)
    {
        var monitor = NativeWindow.Monitor(anchor.Point); var work = monitor.Work; double s = monitor.Scale;
        var point = MarkerLayers.Position(anchor);
        double width = 320 * s, physicalHeight = height * s;
        double x = point.X - 10 * s;
        if (x + width > work.Right - 8 * s) x = point.X + 10 * s - width;
        x = Math.Clamp(x, work.X + 8 * s, Math.Max(work.X + 8 * s, work.Right - width - 8 * s));
        double y = Math.Max(work.Y + 8 * s, point.Y + 10 * s - physicalHeight);
        return new(x, y, width, physicalHeight);
    }
    private void PlaceAtAnchor()
    {
        if (Handle == 0 || !IsVisible || ActualHeight <= 0) return;
        var rect = AnchoredRect(ActualHeight);
        if (PhysicalPlacement != rect) MovePhysical(rect);
    }

    private void Build()
    {
        var p = theme.Palette;
        root = new StackPanel();
        Ui.ApplyScrollTheme(root, p);
        Content = new MatteSurface(p) { WindowFrame = true, Radius = 14, Child = new Border { Padding = new Thickness(12), Child = root } };
        var header = new DockPanel { Height = 22, LastChildFill = true };
        var actions = new StackPanel { Orientation = Orientation.Horizontal };
        void AddAction(UIElement button) { if (button is FrameworkElement b) b.Margin = new Thickness(4, 0, 0, 0); actions.Children.Add(button); }
        copyButton = Ui.IconButton(p, "copy", "复制", () => Copy(model.State.Saved?.Text ?? model.DisplayText)); AddAction(copyButton);
        assetsButton = Ui.IconButton(p, "assets", "资产看板", showAssets); AddAction(assetsButton);
        removeSaved = Ui.IconButton(p, "trash", "取消收藏", () => { if (model.State.Saved is { } saved) edit(new AssetEdit.Delete(saved.Key)); }); AddAction(removeSaved);
        collapseButton = Ui.IconButton(p, "down", "收起卡片", () => { if (model.IsFailure) close(); else collapse(); }); AddAction(collapseButton);
        DockPanel.SetDock(actions, Dock.Right); header.Children.Add(actions);
        var featureContainer = new MatteSurface(p) { Width = 20, Height = 20, Radius = 10, Margin = new Thickness(0, 1, 6, 1) };
        feature = new(MatteDrawing.Icon(model.State.Action), p.Feature(model.State.Action, settings), 10.5)
            { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        featureContainer.Child = feature; DockPanel.SetDock(featureContainer, Dock.Left); header.Children.Add(featureContainer);
        var titles = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        title = Ui.Label(FeatureNames.Name(model.State.Action), p, 11.5, true); titles.Children.Add(title);
        subtitle = Ui.Label("", p, 10.5, ink: p.Tertiary); subtitle.Margin = new Thickness(5, 0, 0, 0);
        subtitle.MaxWidth = 85; subtitle.TextWrapping = TextWrapping.NoWrap; subtitle.TextTrimming = TextTrimming.CharacterEllipsis; titles.Children.Add(subtitle);
        header.Children.Add(titles); root.Children.Add(header);
        notice = Ui.Text("", p, 10.5, ink: p.Secondary); root.Children.Add(notice);
        question = Ui.Text("", p, 11.5, ink: p.Secondary); question.Margin = new Thickness(0, 8, 0, 0); root.Children.Add(question);
        error = Ui.Text("", p, 11, ink: p.Secondary); error.Margin = new Thickness(0, 6, 0, 0); root.Children.Add(error);
        skeleton = BuildSkeleton(p); skeleton.Margin = new Thickness(0, 10, 0, 2); root.Children.Add(skeleton);
        answer = Ui.Input(p, "回答正文", 13); answer.IsReadOnly = true; answer.TextWrapping = TextWrapping.Wrap;
        answer.AcceptsReturn = true; answer.Margin = new Thickness(0, 8, 0, 0); answer.Cursor = Cursors.IBeam;
        root.Children.Add(answer);
        special = new ContentControl { Margin = new Thickness(0, 8, 0, 0) }; root.Children.Add(special);
        colorStatus = Ui.Text("", p, 11, ink: p.Secondary); colorStatus.Margin = new Thickness(0, 6, 0, 0); root.Children.Add(colorStatus);
        var inputRow = new DockPanel();
        send = Ui.IconButton(p, "send", "发送追问", Submit, 20); send.Margin = new Thickness(6, 0, 0, 0); send.VerticalAlignment = VerticalAlignment.Center;
        DockPanel.SetDock(send, Dock.Right); inputRow.Children.Add(send);
        input = Ui.Input(p, FeatureNames.Prompt(model.State.Action)); input.ToolTip = FeatureNames.Prompt(model.State.Action);
        input.TextChanged += (_, _) => { if (!syncingDraft) model.Draft = input.Text; UpdateSend(); };
        input.KeyDown += (_, e) => { if (e.Key == Key.Enter) { Submit(); e.Handled = true; } };
        inputRow.Children.Add(Ui.WithPlaceholder(input, p, FeatureNames.Prompt(model.State.Action)));
        followupRow = Ui.InputWell(p, inputRow, 15); followupRow.Margin = new Thickness(0, 10, 0, 0); followupRow.MinHeight = 30;
        root.Children.Add(followupRow);
        var menu = new ContextMenu();
        var closeItem = new MenuItem { Header = "关闭此标注" }; closeItem.Click += (_, _) => close(); menu.Items.Add(closeItem);
        var clearItem = new MenuItem { Header = "清除全部标注" }; clearItem.Click += (_, _) => clear(); menu.Items.Add(clearItem);
        root.ContextMenu = menu;
        specialSignature = null; UpdateContent();
    }
    private static FrameworkElement BuildSkeleton(Palette p)
    {
        var stack = new StackPanel();
        stack.Children.Add(new MatteSurface(p) { Height = 8, Radius = 4, Pressed = true });
        stack.Children.Add(new MatteSurface(p) { Width = 178, Height = 8, Radius = 4, Pressed = true,
            HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 8, 0, 0) });
        return stack;
    }
    private void UpdateContent()
    {
        if (root is null) return;
        var state = model.State; bool expanded = model.Mode == CardMode.Dialog;
        title.Text = state.Saved is not null ? "已收藏" : FeatureNames.Name(state.Action);
        subtitle.Text = state.Color?.ColorSpace ?? "";
        subtitle.ToolTip = subtitle.Text;
        copyButton.Visibility = state.Color is null ? Visibility.Visible : Visibility.Collapsed;
        string text = state.Saved is null && state.Color is null ? Ui.Plain(model.DisplayText) : "";
        if (answer.Text != text) answer.Text = text;
        answer.Visibility = text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        answer.MaxHeight = expanded ? 260 : 54;
        answer.VerticalScrollBarVisibility = expanded ? ScrollBarVisibility.Auto : ScrollBarVisibility.Hidden;
        answer.IsHitTestVisible = expanded;
        skeleton.Visibility = model.Busy && text.Length == 0 && state.Saved is null && state.Color is null ? Visibility.Visible : Visibility.Collapsed;
        string? q = model.SubmittedQuestion ?? state.Question;
        question.Text = q ?? ""; question.Visibility = string.IsNullOrEmpty(q) ? Visibility.Collapsed : Visibility.Visible;
        error.Text = model.ErrorNotice ?? state.Error ?? "";
        error.Visibility = error.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        assetsButton.Visibility = state.Saved is not null || state.Color is not null ? Visibility.Visible : Visibility.Collapsed;
        removeSaved.Visibility = state.Saved is not null ? Visibility.Visible : Visibility.Collapsed;
        if (collapseButton.Content is Glyph collapseGlyph)
        { collapseGlyph.NameOfIcon = model.IsFailure ? "close" : "down"; collapseGlyph.InvalidateVisual(); }
        followupRow.Visibility = expanded && state.Action is not (ActionKind.Save or ActionKind.PickColor) && !model.IsFailure
            ? Visibility.Visible : Visibility.Collapsed;
        syncingDraft = true; if (input.Text != model.Draft) input.Text = model.Draft; syncingDraft = false;
        input.IsEnabled = !model.Busy;
        UpdateSend();
        colorStatus.Text = state.ColorPersistence switch
        { PersistenceState.Saving => "正在保存到资产", PersistenceState.Saved => "已存入资产", PersistenceState.Failed => "未能存入资产，仍可复制", _ => "" };
        colorStatus.Visibility = state.Color is not null && colorStatus.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        UpdateSpecial(expanded);
    }
    private void UpdateSend()
    { if (send is null) return; send.IsEnabled = model.CanFollowup && !string.IsNullOrWhiteSpace(model.Draft); }
    private void Submit() { model.Submit(followup); UpdateSend(); }
    private void Copy(string text)
    {
        notice.Text = Ui.Copy(Ui.Plain(text)) ? "已复制" : "没能复制";
        noticeTimer.Stop(); noticeTimer.Start();
    }
    private void UpdateSpecial(bool expanded)
    {
        var state = model.State; var p = theme.Palette;
        string signature = $"{expanded}|{state.Color}|{state.Saved?.Id}|{state.Saved?.Text}|{state.Saved?.ImagePath}|{string.Join('\0', state.Saved?.Tags ?? [])}";
        if (signature == specialSignature) return;
        specialSignature = signature;
        if (state.Color is { } color)
        {
            var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 2, 0, 2) };
            row.Children.Add(new ColorSwatch(color, p, 48));
            var values = new StackPanel { Margin = new Thickness(12, 0, 0, 0) };
            values.Children.Add(ColorLine("HEX", color.Hex));
            var rgb = ColorLine("RGB", color.Rgb); rgb.Margin = new Thickness(0, 6, 0, 0); values.Children.Add(rgb);
            row.Children.Add(values); special.Content = row; special.Visibility = Visibility.Visible; return;
        }
        if (state.Saved is { } saved)
        {
            var savedBody = new StackPanel();
            if (saved.ImagePath is { } path) savedBody.Children.Add(new AssetImage(p, path, saved.PointInImage, false) { MaxHeight = expanded ? 180 : 64 });
            if (!string.IsNullOrEmpty(saved.Text))
            {
                var text = Ui.Input(p, "收藏内容", 12.5); text.Text = saved.Text; text.IsReadOnly = true; text.TextWrapping = TextWrapping.Wrap;
                text.MaxHeight = expanded ? 108 : 36; text.IsHitTestVisible = expanded;
                text.VerticalScrollBarVisibility = expanded ? ScrollBarVisibility.Auto : ScrollBarVisibility.Hidden;
                text.Margin = new Thickness(0, 6, 0, 0); savedBody.Children.Add(text);
            }
            savedBody.Children.Add(TagEditor(p, saved));
            if (expanded)
            {
                var source = Ui.Text(string.Join(" · ", new[] { saved.AppName, saved.WindowTitle }.Where(x => x.Length > 0)), p, 10.5, ink: p.Tertiary);
                source.Margin = new Thickness(0, 8, 0, 0); savedBody.Children.Add(source);
            }
            special.Content = savedBody; special.Visibility = Visibility.Visible; return;
        }
        special.Content = null; special.Visibility = Visibility.Collapsed;
    }
    private FrameworkElement ColorLine(string title, string value)
    {
        var p = theme.Palette; var line = new StackPanel { Orientation = Orientation.Horizontal };
        var label = Ui.Label(title, p, 11, ink: p.Secondary); label.Width = 30; label.VerticalAlignment = VerticalAlignment.Center;
        line.Children.Add(label);
        var text = Ui.Label(value, p, 13); text.FontFamily = Theme.MonoFont; text.Width = 126; text.VerticalAlignment = VerticalAlignment.Center; line.Children.Add(text);
        line.Children.Add(Ui.IconButton(p, "copy", "复制 " + title, () => Copy(value))); return line;
    }
    private FrameworkElement TagEditor(Palette p, AssetRecord saved)
    {
        var tags = new WrapPanel { Margin = new Thickness(0, 8, 0, 0) };
        foreach (string tag in saved.Tags)
        {
            var chip = Ui.Pill(p, tag, () => edit(new AssetEdit.RemoveTag(saved.Id, tag)), true, 21);
            chip.Margin = new Thickness(0, 0, 5, 5); chip.ToolTip = "移除标签 " + tag; tags.Children.Add(chip);
        }
        var add = Ui.IconButton(p, "plus", "添加标签", () => { }, 21);
        add.Click += (_, _) =>
        {
            add.Visibility = Visibility.Collapsed;
            var field = Ui.Input(p, "新标签", 11); field.Width = 80;
            var well = Ui.InputWell(p, field, 11, new Thickness(8, 2, 8, 2)); well.Height = 21; tags.Children.Add(well);
            bool committed = false;
            void Commit()
            {
                if (committed) return; committed = true;
                string value = field.Text.Trim(); if (value.Length is > 0 and <= 16) edit(new AssetEdit.AddTag(saved.Id, value));
                tags.Children.Remove(well); add.Visibility = Visibility.Visible;
            }
            field.KeyDown += (_, e) => { if (e.Key == Key.Enter) { Commit(); e.Handled = true; } else if (e.Key == Key.Escape) { field.Text = ""; Commit(); e.Handled = true; } };
            field.LostKeyboardFocus += (_, _) => Commit();
            AllowInputActivation = true; Activate(); field.Focus();
        };
        tags.Children.Add(add); return tags;
    }
}
