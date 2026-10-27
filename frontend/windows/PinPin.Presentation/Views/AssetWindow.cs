using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using PinPin.Core;
using PinPin.Presentation.Controls;
using PinPin.Presentation.Models;

namespace PinPin.Presentation.Views;

internal sealed class AssetWindow : MatteWindow
{
    private readonly Theme theme;
    private readonly AssetModel model;
    private readonly DispatcherTimer noticeTimer;
    private TextBlock total = null!, notice = null!, empty = null!;
    private TextBox query = null!;
    private ListBox list = null!;
    private StackPanel scopes = null!;
    private ScrollViewer tagScroll = null!;
    private RowDefinition tagRow = null!;
    private string? tagSignature;
    private readonly Dictionary<AssetScope, MatteButton> scopeButtons = [];
    public int ActiveTimers => noticeTimer.IsEnabled ? 1 : 0;
    public int RealizedRows => Descendants(list).OfType<AssetRow>().Count();

    public AssetWindow(Theme theme, AssetModel model, Action<nint> ownWindow) : base("PinPin 资产看板", false, ownWindow)
    {
        this.theme = theme; this.model = model; Width = 560; Height = 500;
        noticeTimer = new DispatcherTimer(DispatcherPriority.Background, Dispatcher) { Interval = TimeSpan.FromMilliseconds(1600) };
        noticeTimer.Tick += NoticeTick;
        EscapePressed = Dismiss; model.Changed += ModelChanged;
        Build();
        Closed += (_, _) => { model.Changed -= ModelChanged; noticeTimer.Stop(); noticeTimer.Tick -= NoticeTick; };
    }
    private void NoticeTick(object? sender, EventArgs e) { noticeTimer.Stop(); notice.Text = ""; }
    public void Open()
    {
        if (!IsVisible) { if (PhysicalPlacement is null) ShowCentered(560, 500); else { Show(); Activate(); } }
        else Activate();
    }
    public void Dismiss() { noticeTimer.Stop(); notice.Text = ""; Hide(); }
    public void Repaint() { Build(); }
    public void Copy(string text)
    { notice.Text = Ui.Copy(Ui.Plain(text)) ? "已复制" : "没能复制"; noticeTimer.Stop(); noticeTimer.Start(); }

    private void Build()
    {
        var p = theme.Palette;
        var grid = new Grid { Margin = new Thickness(16) };
        Ui.ApplyScrollTheme(grid, p);
        foreach (double height in new[] { 24d, 10, 32, 10, 25, 8, 27, 10 }) grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(height) });
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        tagRow = grid.RowDefinitions[6];
        Content = new MatteSurface(p) { WindowFrame = true, Radius = 14, Child = grid };
        var header = new DockPanel { LastChildFill = true };
        var close = Ui.IconButton(p, "close", "关闭资产看板", Dismiss); DockPanel.SetDock(close, Dock.Right); header.Children.Add(close);
        var title = Ui.Label("资产看板", p, 14, true); title.Margin = new Thickness(0, 0, 8, 0); DockPanel.SetDock(title, Dock.Left); header.Children.Add(title);
        total = Ui.Label("", p, 11, ink: p.Tertiary); total.VerticalAlignment = VerticalAlignment.Center; DockPanel.SetDock(total, Dock.Left); header.Children.Add(total);
        notice = Ui.Label("", p, 11, ink: p.Secondary); notice.Margin = new Thickness(8, 0, 0, 0); notice.VerticalAlignment = VerticalAlignment.Center;
        header.Children.Add(notice);
        header.MouseLeftButtonDown += (_, e) => { if (e.LeftButton == MouseButtonState.Pressed) { DragMove(); e.Handled = true; } };
        grid.Children.Add(header);
        var search = new DockPanel();
        var searchGlyph = new Glyph("search", p.Tertiary, 13) { Margin = new Thickness(0, 0, 8, 0), VerticalAlignment = VerticalAlignment.Center };
        DockPanel.SetDock(searchGlyph, Dock.Left); search.Children.Add(searchGlyph);
        query = Ui.Input(p, "搜索内容、标签或色值"); query.Text = model.Query; query.ToolTip = "搜索内容、标签或色值";
        query.TextChanged += (_, _) => model.Search(query.Text); search.Children.Add(Ui.WithPlaceholder(query, p, "搜索内容、标签或色值"));
        var searchWell = Ui.InputWell(p, search); Grid.SetRow(searchWell, 2); grid.Children.Add(searchWell);
        scopes = new StackPanel { Orientation = Orientation.Horizontal }; scopeButtons.Clear();
        foreach (var (scope, label) in new[] { (AssetScope.All, "全部"), (AssetScope.Saved, "收藏"), (AssetScope.Color, "取色") })
        {
            var button = Ui.Pill(p, label, () => model.SelectScope(scope), model.Scope == scope, 25); button.Margin = new Thickness(0, 0, 8, 0);
            scopeButtons[scope] = button; scopes.Children.Add(button);
        }
        Grid.SetRow(scopes, 4); grid.Children.Add(scopes);
        tagScroll = new ScrollViewer { HorizontalScrollBarVisibility = ScrollBarVisibility.Hidden, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled };
        Grid.SetRow(tagScroll, 6); grid.Children.Add(tagScroll);
        list = new ListBox { Background = Brushes.Transparent, BorderThickness = new Thickness(0), Padding = new Thickness(0),
            HorizontalContentAlignment = HorizontalAlignment.Stretch, SelectionMode = SelectionMode.Single };
        ScrollViewer.SetHorizontalScrollBarVisibility(list, ScrollBarVisibility.Disabled);
        ScrollViewer.SetVerticalScrollBarVisibility(list, ScrollBarVisibility.Auto);
        ScrollViewer.SetCanContentScroll(list, true);
        VirtualizingPanel.SetIsVirtualizing(list, true); VirtualizingPanel.SetVirtualizationMode(list, VirtualizationMode.Recycling);
        VirtualizingPanel.SetScrollUnit(list, ScrollUnit.Pixel); VirtualizingPanel.SetCacheLength(list, new VirtualizationCacheLength(1));
        var itemsPanel = new FrameworkElementFactory(typeof(VirtualizingStackPanel)); list.ItemsPanel = new ItemsPanelTemplate(itemsPanel);
        var itemStyle = new Style(typeof(ListBoxItem));
        itemStyle.Setters.Add(new Setter(Control.HorizontalContentAlignmentProperty, HorizontalAlignment.Stretch));
        itemStyle.Setters.Add(new Setter(Control.PaddingProperty, new Thickness(0)));
        itemStyle.Setters.Add(new Setter(Control.BorderThicknessProperty, new Thickness(0)));
        var cp = new FrameworkElementFactory(typeof(ContentPresenter));
        itemStyle.Setters.Add(new Setter(Control.TemplateProperty, new ControlTemplate(typeof(ListBoxItem)) { VisualTree = cp }));
        list.ItemContainerStyle = itemStyle;
        var factory = new FrameworkElementFactory(typeof(AssetRow));
        factory.SetValue(AssetRow.ContextProperty, new AssetRowContext(theme, model, Copy));
        list.ItemTemplate = new DataTemplate(typeof(AssetRecord)) { VisualTree = factory };
        var area = new Grid(); area.Children.Add(list);
        empty = Ui.Text("", p, 12, ink: p.Tertiary); empty.TextAlignment = TextAlignment.Center;
        empty.HorizontalAlignment = HorizontalAlignment.Center; empty.VerticalAlignment = VerticalAlignment.Center; area.Children.Add(empty);
        Grid.SetRow(area, 8); grid.Children.Add(area);
        tagSignature = null; ModelChanged();
    }
    private void ModelChanged()
    {
        total.Text = $"{model.Records.Count} 项";
        list.ItemsSource = model.Results;
        foreach (var (scope, button) in scopeButtons) button.Selected = model.Scope == scope;
        empty.Text = model.Records.Count == 0 ? "还没有资产" : "没有找到相关资产";
        empty.Visibility = model.Results.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        string signature = $"{model.Scope}|{model.Tag}|{string.Join('\0', model.Tags)}";
        if (signature == tagSignature) return;
        tagSignature = signature;
        bool visible = model.Scope != AssetScope.Color && model.Tags.Count > 0;
        tagRow.Height = new GridLength(visible ? 27 : 0); tagScroll.Visibility = visible ? Visibility.Visible : Visibility.Collapsed;
        var tags = new StackPanel { Orientation = Orientation.Horizontal };
        var all = Ui.Pill(theme.Palette, "所有标签", () => model.SelectTag(null), model.Tag is null, 23); all.Margin = new Thickness(0, 0, 6, 0); tags.Children.Add(all);
        foreach (string tag in model.Tags)
        {
            var button = Ui.Pill(theme.Palette, tag, () => model.SelectTag(tag), model.Tag == tag, 23);
            button.Margin = new Thickness(0, 0, 6, 0); tags.Children.Add(button);
        }
        tagScroll.Content = tags;
    }
    internal static IEnumerable<DependencyObject> Descendants(DependencyObject root)
    {
        for (int i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
        { var child = VisualTreeHelper.GetChild(root, i); yield return child; foreach (var nested in Descendants(child)) yield return nested; }
    }
}

internal sealed record AssetRowContext(Theme Theme, AssetModel Model, Action<string> Copy);

internal sealed class AssetRow : ContentControl
{
    public static readonly DependencyProperty ContextProperty = DependencyProperty.Register(nameof(Context), typeof(AssetRowContext), typeof(AssetRow), new PropertyMetadata(null, ContextChanged));
    public AssetRowContext? Context { get => (AssetRowContext?)GetValue(ContextProperty); set => SetValue(ContextProperty, value); }
    private AssetModel? subscribed;
    private AssetRecord? asset;
    private bool expanded;
    public AssetRow()
    {
        HorizontalContentAlignment = HorizontalAlignment.Stretch;
        DataContextChanged += (_, _) => { asset = DataContext as AssetRecord; Build(); };
        Loaded += (_, _) => { Subscribe(); Build(); };
        Unloaded += (_, _) => Unsubscribe();
    }
    private static void ContextChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    { var row = (AssetRow)d; row.Unsubscribe(); if (row.IsLoaded) row.Subscribe(); row.Build(); }
    private void Subscribe()
    { if (subscribed is not null || Context is null) return; subscribed = Context.Model; subscribed.ExpansionChanged += ExpansionChanged; }
    private void Unsubscribe() { if (subscribed is not null) subscribed.ExpansionChanged -= ExpansionChanged; subscribed = null; }
    private void ExpansionChanged()
    { if (asset is not null && expanded != (Context?.Model.OpenRow == asset.Key)) Build(); }
    private void Build()
    {
        if (asset is not { } item || Context is not { } context) return;
        var p = context.Theme.Palette; expanded = context.Model.OpenRow == item.Key;
        var stack = new StackPanel();
        var surface = new MatteSurface(p) { Radius = 10, Pressed = expanded, Depth = 1.2, DrawSurface = expanded,
            Margin = new Thickness(3, 3, 3, 6), Child = new Border { Padding = new Thickness(10), Child = stack } };
        Content = surface;
        var header = new DockPanel { LastChildFill = true, Background = Brushes.Transparent };
        var actions = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Top };
        actions.Children.Add(Ui.IconButton(p, "copy", item.Kind == AssetKind.Color ? "复制 HEX" : "复制收藏文字", () => context.Copy(item.Color?.Hex ?? item.Text)));
        var delete = Ui.IconButton(p, "trash", "删除此资产", () => context.Model.Delete(item.Key)); delete.Margin = new Thickness(4, 0, 0, 0); actions.Children.Add(delete);
        void Highlight(bool hover)
        {
            bool show = hover || expanded || surface.IsKeyboardFocusWithin;
            surface.DrawSurface = show; surface.InvalidateVisual();
            actions.Opacity = show ? 1 : 0; actions.IsHitTestVisible = show;
        }
        surface.MouseEnter += (_, _) => Highlight(true); surface.MouseLeave += (_, _) => Highlight(false);
        surface.IsKeyboardFocusWithinChanged += (_, _) => Highlight(surface.IsMouseOver);
        Highlight(false);
        DockPanel.SetDock(actions, Dock.Right); header.Children.Add(actions);
        FrameworkElement thumb;
        if (item.Color is { } color) thumb = new ColorSwatch(color, p, 38);
        else if (item.ImagePath is { } path) thumb = new AssetImage(p, path, item.PointInImage, true);
        else thumb = new MatteSurface(p) { Width = 38, Height = 38, Radius = 7, Pressed = true,
            Child = new Glyph("bookmark", p.Secondary, 17) { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center } };
        thumb.Margin = new Thickness(0, 0, 10, 0); DockPanel.SetDock(thumb, Dock.Left); header.Children.Add(thumb);
        var summary = new StackPanel { Margin = new Thickness(0, 0, 8, 0), VerticalAlignment = VerticalAlignment.Center };
        var text = Ui.Text(item.Color is { } value ? value.Hex + "   " + value.Rgb : (item.Text.Length == 0 ? "图片收藏" : item.Text), p, 12.5);
        if (item.Color is not null) text.FontFamily = Theme.MonoFont;
        text.MaxHeight = 36; text.TextTrimming = TextTrimming.CharacterEllipsis; summary.Children.Add(text);
        string date = item.CreatedAt.ToLocalTime().ToString("MM-dd HH:mm");
        var metadata = Ui.Label((item.Kind == AssetKind.Color ? "取色" : "收藏") + " · " + date + (item.Tags.Length > 0 ? " · " + string.Join(" · ", item.Tags) : ""), p, 10.5, ink: p.Tertiary);
        metadata.TextWrapping = TextWrapping.NoWrap; metadata.TextTrimming = TextTrimming.CharacterEllipsis; metadata.Margin = new Thickness(0, 4, 0, 0); summary.Children.Add(metadata);
        header.Children.Add(summary);
        header.MouseLeftButtonUp += (_, e) => { context.Model.Toggle(item.Key); e.Handled = true; };
        header.ToolTip = expanded ? "收起详情" : "展开详情";
        stack.Children.Add(header);
        var menu = new ContextMenu();
        void AddMenu(string label, Action action) { var entry = new MenuItem { Header = label }; entry.Click += (_, _) => action(); menu.Items.Add(entry); }
        AddMenu("复制", () => context.Copy(item.Color?.Hex ?? item.Text));
        if (item.Color is { } sampled) AddMenu("复制 RGB", () => context.Copy(sampled.Rgb));
        AddMenu("删除", () => context.Model.Delete(item.Key)); surface.ContextMenu = menu;
        if (!expanded) return;
        var detail = new StackPanel { Margin = new Thickness(0, 10, 0, 0) };
        if (item.Color is { } picked)
        {
            var row = new StackPanel { Orientation = Orientation.Horizontal };
            row.Children.Add(new ColorSwatch(picked, p, 60));
            var values = new StackPanel { Margin = new Thickness(12, 0, 0, 0) };
            values.Children.Add(ColorLine(p, "HEX", picked.Hex, context.Copy));
            var rgb = ColorLine(p, "RGB", picked.Rgb, context.Copy); rgb.Margin = new Thickness(0, 6, 0, 0); values.Children.Add(rgb);
            var colorSpace = Ui.Text(picked.ColorSpace, p, 10.5, ink: p.Tertiary); colorSpace.Margin = new Thickness(0, 4, 0, 0); values.Children.Add(colorSpace);
            row.Children.Add(values); detail.Children.Add(row);
        }
        else
        {
            if (item.ImagePath is { } path) detail.Children.Add(new AssetImage(p, path, item.PointInImage, false));
            if (item.Text.Length > 0)
            {
                var full = Ui.Input(p, "完整收藏正文", 12.5); full.Text = item.Text; full.IsReadOnly = true;
                full.TextWrapping = TextWrapping.Wrap; full.AcceptsReturn = true; full.Margin = new Thickness(0, 6, 0, 0);
                // Full content participates in the virtualized row height. The outer list owns scrolling.
                full.VerticalScrollBarVisibility = ScrollBarVisibility.Disabled; detail.Children.Add(full);
            }
            detail.Children.Add(Tags(p, item, context.Model));
        }
        var source = Ui.Text(string.Join(" · ", new[] { item.AppName, item.WindowTitle }.Where(x => x.Length > 0)), p, 10.5, ink: p.Tertiary);
        source.Margin = new Thickness(0, 8, 0, 0); detail.Children.Add(source); stack.Children.Add(detail);
    }
    private static FrameworkElement ColorLine(Palette p, string name, string value, Action<string> copy)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal };
        var label = Ui.Text(name, p, 10.5, ink: p.Secondary); label.Width = 28; label.VerticalAlignment = VerticalAlignment.Center; row.Children.Add(label);
        var text = Ui.Input(p, name, 12.5); text.IsReadOnly = true; text.Text = value; text.Width = 130; text.FontFamily = Theme.MonoFont; row.Children.Add(text);
        row.Children.Add(Ui.IconButton(p, "copy", "复制 " + name, () => copy(value))); return row;
    }
    private static FrameworkElement Tags(Palette p, AssetRecord item, AssetModel model)
    {
        var tags = new WrapPanel { Margin = new Thickness(0, 8, 0, 0) };
        foreach (string tag in item.Tags)
        {
            var chip = Ui.Pill(p, tag, () => model.RemoveTag(item.Id, tag), true, 21);
            chip.ToolTip = "移除标签 " + tag; chip.Margin = new Thickness(0, 0, 5, 5); tags.Children.Add(chip);
        }
        var add = Ui.IconButton(p, "plus", "添加收藏标签", () => { }, 21);
        add.Click += (_, _) =>
        {
            add.Visibility = Visibility.Collapsed; var field = Ui.Input(p, "新标签", 11); field.Width = 80;
            var well = Ui.InputWell(p, field, 11, new Thickness(8, 2, 8, 2)); well.Height = 21; tags.Children.Add(well);
            bool committed = false;
            void Commit()
            { if (committed) return; committed = true; model.AddTag(item.Id, field.Text); tags.Children.Remove(well); add.Visibility = Visibility.Visible; }
            field.KeyDown += (_, e) => { if (e.Key == Key.Enter) { Commit(); e.Handled = true; } else if (e.Key == Key.Escape) { field.Text = ""; Commit(); e.Handled = true; } };
            field.LostKeyboardFocus += (_, _) => Commit(); field.Focus();
        };
        tags.Children.Add(add); return tags;
    }
}
