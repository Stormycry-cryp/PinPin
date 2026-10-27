using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Markup;
using System.Windows.Media;

namespace PinPin.Presentation.Controls;

internal sealed class MatteSurface : Decorator
{
    public Palette Palette { get; set; }
    public double Radius { get; set; } = 14;
    public bool Pressed { get; set; }
    public double Depth { get; set; } = 1.5;
    public bool DrawSurface { get; set; } = true;
    public bool WindowFrame { get; set; }
    public MatteSurface(Palette palette) { Palette = palette; }
    protected override void OnRender(DrawingContext dc)
    {
        if (WindowFrame) MatteDrawing.Frame(dc, new Rect(RenderSize), Radius, Palette);
        else if (DrawSurface) MatteDrawing.Surface(dc, new Rect(.75, .75, Math.Max(0, ActualWidth - 1.5), Math.Max(0, ActualHeight - 1.5)), Radius, Palette, Pressed, Depth);
        else dc.DrawRectangle(Brushes.Transparent, null, new Rect(RenderSize));
    }
}

internal sealed class MatteButton : Button
{
    private bool selected;
    public Palette Palette { get; set; }
    public double Radius { get; set; } = 11;
    public double Depth { get; set; } = 1.3;
    public bool Selected { get => selected; set { if (selected != value) { selected = value; RefreshLabel(); InvalidateVisual(); } } }
    public bool StylesLabel { get; set; }
    private void RefreshLabel()
    {
        if (StylesLabel && Content is TextBlock label)
        { label.Foreground = Selected ? Palette.Ink : Palette.Secondary; label.FontWeight = Selected ? FontWeights.SemiBold : FontWeights.Normal; }
    }
    public bool Graphite { get; set; }
    public bool Bare { get; set; }
    public MatteButton(Palette palette, string label)
    {
        Palette = palette; Foreground = palette.Secondary; Background = Brushes.Transparent;
        BorderThickness = new Thickness(0); Padding = new Thickness(0); FontFamily = Theme.Font;
        Theme.Typography(this);
        FontSize = 11; Cursor = Cursors.Hand; FocusVisualStyle = null;
        var presenter = new FrameworkElementFactory(typeof(ContentPresenter));
        presenter.SetValue(HorizontalAlignmentProperty, HorizontalAlignment.Center);
        presenter.SetValue(VerticalAlignmentProperty, VerticalAlignment.Center);
        Template = new ControlTemplate(typeof(Button)) { VisualTree = presenter };
        ToolTip = label; AutomationProperties.SetName(this, label);
        IsEnabledChanged += (_, _) => { Opacity = IsEnabled ? 1 : .45; InvalidateVisual(); };
    }
    protected override void OnIsPressedChanged(DependencyPropertyChangedEventArgs e)
    { base.OnIsPressedChanged(e); InvalidateVisual(); }
    protected override void OnRender(DrawingContext dc)
    {
        var rect = new Rect(1, 1, Math.Max(0, ActualWidth - 2), Math.Max(0, ActualHeight - 2));
        if (!Bare) MatteDrawing.Surface(dc, rect, Radius, Palette, Selected || IsPressed, Depth);
        else dc.DrawRectangle(Brushes.Transparent, null, rect);
        if (Graphite) dc.DrawRoundedRectangle(Palette.Accent, null, rect, Radius, Radius);
        if (IsKeyboardFocused) dc.DrawRoundedRectangle(null, global::PinPin.Presentation.Palette.Pen(Palette.Ink, 1), rect, Radius, Radius);
    }
    protected override void OnGotKeyboardFocus(KeyboardFocusChangedEventArgs e) { base.OnGotKeyboardFocus(e); InvalidateVisual(); }
    protected override void OnLostKeyboardFocus(KeyboardFocusChangedEventArgs e) { base.OnLostKeyboardFocus(e); InvalidateVisual(); }
}

internal static class Ui
{
    public static void ApplyScrollTheme(FrameworkElement root, Palette p)
    {
        // Keep WPF's ScrollViewer, Track and Thumb behavior, with the Mac's quiet narrow indicator.
        // The template is scoped to this component; it does not alter system scrollbars.
        string thumb = p.Tertiary.Color.ToString();
        var style = new Style(typeof(ScrollBar));
        style.Setters.Add(new Setter(Control.BackgroundProperty, Brushes.Transparent));
        style.Setters.Add(new Setter(FrameworkElement.WidthProperty, 10d));
        style.Setters.Add(new Setter(Control.TemplateProperty, (ControlTemplate)XamlReader.Parse($$"""
            <ControlTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
                             xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" TargetType="ScrollBar">
              <Grid Background="Transparent">
                <Track x:Name="PART_Track" IsDirectionReversed="True" Orientation="Vertical"
                       Minimum="{TemplateBinding Minimum}" Maximum="{TemplateBinding Maximum}"
                       Value="{TemplateBinding Value}" ViewportSize="{TemplateBinding ViewportSize}">
                  <Track.DecreaseRepeatButton>
                    <RepeatButton Command="{x:Static ScrollBar.PageUpCommand}" Focusable="False" Opacity="0" />
                  </Track.DecreaseRepeatButton>
                  <Track.Thumb>
                    <Thumb MinHeight="20">
                      <Thumb.Template>
                        <ControlTemplate TargetType="Thumb">
                          <Border x:Name="Indicator" Background="{{thumb}}" CornerRadius="3" Margin="2,1" Opacity="0.42" />
                          <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Indicator" Property="Opacity" Value="0.75" /></Trigger>
                            <Trigger Property="IsDragging" Value="True"><Setter TargetName="Indicator" Property="Opacity" Value="1" /></Trigger>
                          </ControlTemplate.Triggers>
                        </ControlTemplate>
                      </Thumb.Template>
                    </Thumb>
                  </Track.Thumb>
                  <Track.IncreaseRepeatButton>
                    <RepeatButton Command="{x:Static ScrollBar.PageDownCommand}" Focusable="False" Opacity="0" />
                  </Track.IncreaseRepeatButton>
                </Track>
              </Grid>
            </ControlTemplate>
            """)));
        root.Resources[typeof(ScrollBar)] = style;
    }

    public static TextBlock Text(string text, Palette p, double size = 13, bool bold = false, Brush? ink = null)
    {
        var label = new TextBlock { Text = text, Foreground = ink ?? p.Ink, FontSize = size, FontFamily = Theme.Font,
            FontWeight = bold ? FontWeights.SemiBold : FontWeights.Normal, TextWrapping = TextWrapping.Wrap };
        Theme.Typography(label); return label;
    }

    public static TextBlock Label(string text, Palette p, double size = 11, bool bold = false, Brush? ink = null)
    {
        var label = Text(text, p, size, bold, ink);
        label.TextWrapping = TextWrapping.NoWrap; label.TextTrimming = TextTrimming.CharacterEllipsis;
        label.VerticalAlignment = VerticalAlignment.Center;
        // A shared line box keeps Chinese, Latin and mixed labels centered in compact controls.
        label.LineHeight = Math.Ceiling(size * 1.45); label.LineStackingStrategy = LineStackingStrategy.BlockLineHeight;
        return label;
    }

    public static MatteButton IconButton(Palette p, string icon, string label, Action action, double size = 22)
    {
        var button = new MatteButton(p, label) { Width = size, Height = size, Radius = size / 2, Content = new Glyph(icon, p.Secondary, 10.5) };
        button.Click += (_, _) => action(); return button;
    }

    public static MatteButton Pill(Palette p, string title, Action action, bool selected = false, double height = 24)
    {
        var button = new MatteButton(p, title) { Height = height, MinWidth = 32, Radius = height / 2,
            Padding = new Thickness(10, 0, 10, 0), StylesLabel = true, Selected = selected,
            Content = Label(title, p, 11, selected, selected ? p.Ink : p.Secondary) };
        // ContentPresenter in the lightweight template does not add Button.Padding.
        ((TextBlock)button.Content).Margin = new Thickness(10, 0, 10, 0);
        button.Click += (_, _) => action(); return button;
    }

    public static TextBox Input(Palette p, string name, double size = 12.5)
    {
        var input = new TextBox { FontFamily = Theme.Font, FontSize = size, Foreground = p.Ink,
            Background = Brushes.Transparent, BorderThickness = new Thickness(0), Padding = new Thickness(0),
            VerticalContentAlignment = VerticalAlignment.Center, FocusVisualStyle = null,
            SelectionBrush = p.Accent, CaretBrush = p.Ink };
        Theme.Typography(input);
        AutomationProperties.SetName(input, name); return input;
    }

    public static MatteSurface InputWell(Palette p, UIElement input, double radius = 7, Thickness? padding = null)
        => new(p) { Pressed = true, Radius = radius, Child = new Border { Padding = padding ?? new Thickness(9, 4, 9, 4), Child = input } };

    public static FrameworkElement WithPlaceholder(TextBox input, Palette p, string text)
    {
        var grid = new Grid(); grid.Children.Add(input);
        var label = Label(text, p, input.FontSize, ink: p.Tertiary);
        // TextBox reserves a small content inset even with a zero border. Match it here.
        label.Margin = new Thickness(2, 0, 2, 0);
        label.IsHitTestVisible = false; label.VerticalAlignment = VerticalAlignment.Center;
        label.TextWrapping = TextWrapping.NoWrap; label.TextTrimming = TextTrimming.CharacterEllipsis;
        grid.Children.Add(label);
        void Update() => label.Visibility = input.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        input.TextChanged += (_, _) => Update(); Update(); return grid;
    }

    public static ScrollViewer Scroll(UIElement content, double maxHeight = double.PositiveInfinity)
        => new() { Content = content, VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, MaxHeight = maxHeight,
            PanningMode = PanningMode.VerticalOnly, CanContentScroll = false, Focusable = false };

    public static string Plain(string text)
    {
        // Copy/display removes only inline markup. It never limits length or deletes paragraph text.
        return text.Replace("**", "").Replace("__", "").Replace("`", "");
    }

    public static bool Copy(string text)
    {
        if (string.IsNullOrEmpty(text)) return false;
        try { Clipboard.SetText(text); return true; }
        catch (System.Runtime.InteropServices.COMException) { return false; }
    }
}
