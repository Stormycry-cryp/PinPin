using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using PinPin.Core;
using PinPin.Presentation.Controls;

namespace PinPin.Presentation.Views;

internal sealed record MarkerData(Guid Id, ActionKind Action, TargetAnchor Anchor, bool Busy);

/// One transparent HWND per occupied monitor, with one retained DrawingVisual per collapsed result.
/// No per-result Window, no rendering clock, no polling. Windows input is bounded by native regions.
internal sealed class MarkerLayers : IDisposable
{
    private readonly Theme theme;
    private readonly Action<nint> ownWindow;
    private readonly Action<Guid, bool> open;
    private readonly Action<Guid> close;
    private readonly Action clear;
    private readonly Dictionary<nint, MarkerWindow> layers = [];
    private readonly Dictionary<Guid, nint> membership = [];
    private WheelSettings settings;
    public int WindowCount => layers.Count;
    public int VisualCount => membership.Count;
    public int ActiveHoverTimers => layers.Values.Count(x => x.HoverTimerActive);

    public MarkerLayers(Theme theme, WheelSettings settings, Action<nint> ownWindow, Action<Guid, bool> open, Action<Guid> close, Action clear)
    { this.theme = theme; this.settings = settings; this.ownWindow = ownWindow; this.open = open; this.close = close; this.clear = clear; }

    public static ScreenPoint Position(TargetAnchor anchor)
    {
        var monitor = NativeWindow.Monitor(anchor.Point); double scale = monitor.Scale;
        var work = monitor.Work;
        double x = anchor.Point.X + 10 * scale, y = anchor.Point.Y - 19 * scale;
        if (x + 12 * scale > work.Right) x = anchor.Point.X - 10 * scale;
        if (y - 12 * scale < work.Y) y = anchor.Point.Y + 19 * scale;
        return new(Math.Clamp(x, work.X + 12 * scale, Math.Max(work.X + 12 * scale, work.Right - 12 * scale)),
            Math.Clamp(y, work.Y + 12 * scale, Math.Max(work.Y + 12 * scale, work.Bottom - 12 * scale)));
    }

    public void Put(MarkerData marker)
    {
        var monitor = NativeWindow.Monitor(marker.Anchor.Point);
        if (membership.TryGetValue(marker.Id, out var previous) && previous != monitor.Handle) Remove(marker.Id);
        if (!layers.TryGetValue(monitor.Handle, out var layer))
        {
            layer = new(theme, settings, monitor, ownWindow, open, close, clear);
            layers.Add(monitor.Handle, layer);
        }
        membership[marker.Id] = monitor.Handle; layer.Put(marker);
    }
    public void Remove(Guid id)
    {
        if (!membership.Remove(id, out nint key) || !layers.TryGetValue(key, out var layer)) return;
        layer.Remove(id);
        if (layer.Count == 0) { layer.Close(); layers.Remove(key); }
    }
    public void Repaint(WheelSettings value)
    { settings = value; foreach (var layer in layers.Values) layer.Repaint(value); }
    public void CancelHover() { foreach (var layer in layers.Values) layer.CancelHover(); }
    public void Dispose()
    { foreach (var layer in layers.Values) layer.Close(); layers.Clear(); membership.Clear(); }
}

internal sealed class MarkerWindow : MatteWindow
{
    private readonly Theme theme;
    private WheelSettings settings;
    private readonly MonitorArea monitor;
    private readonly MarkerVisualHost host;
    private readonly Dictionary<Guid, MarkerData> records = [];
    private readonly Dictionary<Guid, Point> positions = [];
    private readonly DispatcherTimer hover;
    private readonly Action<Guid, bool> open;
    private readonly Action<Guid> close;
    private readonly Action clear;
    private Guid? hovered;
    private ScreenRect frame;
    public int Count => records.Count;
    public bool HoverTimerActive => hover.IsEnabled;

    public MarkerWindow(Theme theme, WheelSettings settings, MonitorArea monitor, Action<nint> ownWindow,
        Action<Guid, bool> open, Action<Guid> close, Action clear) : base("PinPin 标注", true, ownWindow, neverActivate: true)
    {
        this.theme = theme; this.settings = settings; this.monitor = monitor; this.open = open; this.close = close; this.clear = clear;
        host = new(); Content = host;
        hover = new DispatcherTimer(DispatcherPriority.Input, Dispatcher) { Interval = TimeSpan.FromSeconds(1) };
        hover.Tick += HoverTick;
        host.MouseMove += MouseMoved;
        host.MouseLeave += (_, _) => CancelHover();
        host.MouseLeftButtonUp += Clicked;
        host.MouseRightButtonUp += (_, e) =>
        {
            Guid? id = Hit(e.GetPosition(host)); if (id is null) return;
            var menu = new System.Windows.Controls.ContextMenu();
            void Item(string title, Action action) { var item = new System.Windows.Controls.MenuItem { Header = title }; item.Click += (_, _) => action(); menu.Items.Add(item); }
            Item("打开", () => open(id.Value, false)); Item("关闭此标注", () => close(id.Value)); Item("清除全部标注", clear);
            host.ContextMenu = menu; menu.IsOpen = true; e.Handled = true;
        };
        Closed += (_, _) => { hover.Stop(); hover.Tick -= HoverTick; };
    }

    public void Put(MarkerData marker)
    {
        if (records.TryGetValue(marker.Id, out var previous) && previous == marker) return;
        bool geometryChanged = previous is null || previous.Anchor != marker.Anchor;
        records[marker.Id] = marker;
        if (geometryChanged) Relayout(); else Draw(marker.Id);
    }
    public void Remove(Guid id)
    {
        if (hovered == id) CancelHover();
        records.Remove(id); host.Remove(id); positions.Remove(id);
        if (records.Count > 0) Relayout();
    }
    public void Repaint(WheelSettings value)
    { settings = value; foreach (var id in records.Keys) Draw(id); }
    public void CancelHover()
    {
        hover.Stop(); Guid? old = hovered; hovered = null;
        if (old is { } id && records.ContainsKey(id)) { Draw(id); Region(); }
    }
    private void HoverTick(object? sender, EventArgs e)
    { hover.Stop(); if (hovered is { } id && records.ContainsKey(id)) open(id, true); }
    private Guid? Hit(Point at)
    {
        foreach (var (id, center) in positions.Reverse())
            if ((at - center).Length <= 13 || (hovered == id && (at - new Point(center.X + 10, center.Y - 10)).Length <= 7)) return id;
        return null;
    }
    private void MouseMoved(object sender, MouseEventArgs e)
    {
        var id = Hit(e.GetPosition(host)); if (hovered == id) return;
        CancelHover(); hovered = id;
        if (id is { } value) { Draw(value); Region(); hover.Start(); }
    }
    private void Clicked(object sender, MouseButtonEventArgs e)
    {
        Point at = e.GetPosition(host); Guid? id = Hit(at); if (id is null) return;
        hover.Stop();
        bool onClose = hovered == id && positions.TryGetValue(id.Value, out var center) && (at - new Point(center.X + 10, center.Y - 10)).Length <= 7;
        if (onClose) close(id.Value); else open(id.Value, false);
        e.Handled = true;
    }
    private void Relayout()
    {
        double scale = monitor.Scale, padding = 19 * scale;
        var points = records.ToDictionary(x => x.Key, x => MarkerLayers.Position(x.Value.Anchor));
        double left = points.Values.Min(x => x.X) - padding, top = points.Values.Min(x => x.Y) - padding;
        double right = points.Values.Max(x => x.X) + padding, bottom = points.Values.Max(x => x.Y) + padding;
        frame = new(left, top, right - left, bottom - top);
        positions.Clear();
        foreach (var (id, at) in points) positions[id] = new((at.X - left) / scale, (at.Y - top) / scale);
        host.Width = frame.Width / scale; host.Height = frame.Height / scale;
        ShowPhysical(frame);
        foreach (var id in records.Keys) Draw(id);
        Region();
    }
    private void Region()
    {
        if (Handle == 0) return;
        var circles = new List<Rect>(); double scale = monitor.Scale;
        foreach (var (id, at) in positions)
        {
            circles.Add(new((at.X - 13) * scale, (at.Y - 13) * scale, 26 * scale, 26 * scale));
            if (hovered == id) circles.Add(new((at.X + 3) * scale, (at.Y - 17) * scale, 14 * scale, 14 * scale));
        }
        NativeWindow.SetMarkerRegion(Handle, circles);
    }
    private void Draw(Guid id)
    {
        if (!records.TryGetValue(id, out var marker) || !positions.TryGetValue(id, out var at)) return;
        DrawingVisual visual = host.Get(id);
        var p = theme.Palette; var ink = p.Feature(marker.Action, settings);
        using DrawingContext dc = visual.RenderOpen();
        MatteDrawing.Surface(dc, new(at.X - 10, at.Y - 10, 20, 20), 10, p, depth: 1.2);
        dc.DrawEllipse(null, Palette.Pen(ink, .8), at, 9.7, 9.7);
        Icons.Draw(dc, MatteDrawing.Icon(marker.Action), new(at.X - 4, at.Y - 4, 8, 8), ink, 1.9);
        if (marker.Busy)
        {
            var arc = new StreamGeometry();
            using (var c = arc.Open())
            { c.BeginFigure(new(at.X + 7.3, at.Y), false, false); c.ArcTo(new(at.X - 1.4, at.Y - 7.2), new Size(7.3, 7.3), 0, false, SweepDirection.Counterclockwise, true, false); }
            arc.Freeze(); dc.DrawGeometry(null, Palette.Pen(ink, 1.3), arc);
        }
        if (hovered == id)
        {
            var closeAt = new Point(at.X + 10, at.Y - 10);
            MatteDrawing.Surface(dc, new(closeAt.X - 6, closeAt.Y - 6, 12, 12), 6, p, depth: .8);
            Icons.Draw(dc, "close", new(closeAt.X - 3.25, closeAt.Y - 3.25, 6.5, 6.5), p.Secondary, 1.7);
        }
    }
}

internal sealed class MarkerVisualHost : FrameworkElement
{
    private readonly VisualCollection visuals;
    private readonly Dictionary<Guid, DrawingVisual> items = [];
    public MarkerVisualHost() { visuals = new(this); }
    public DrawingVisual Get(Guid id)
    { if (items.TryGetValue(id, out var item)) return item; var visual = new DrawingVisual(); items.Add(id, visual); visuals.Add(visual); return visual; }
    public void Remove(Guid id) { if (items.Remove(id, out var visual)) visuals.Remove(visual); }
    protected override int VisualChildrenCount => visuals.Count;
    protected override Visual GetVisualChild(int index) => visuals[index];
}
