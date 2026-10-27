using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Media;
using PinPin.Core;

namespace PinPin.Presentation.Controls;

internal sealed class WheelView : FrameworkElement
{
    private readonly Theme theme;
    private WheelSettings settings = WheelSettings.Default;
    private IReadOnlyList<WheelSlot> slots = WheelGeometry.Standard(4);
    private readonly Dictionary<int, Geometry> geometries = [];
    private int? selected;
    private ActionKind? editing;
    private double inner = 26, outer = 80, iconSize = 17, gap = 4;
    public Point Center => new(Width / 2, Height / 2);
    public int? Selected => selected;
    public WheelSettings Settings => settings;
    public IReadOnlyList<WheelSlot> Slots => slots;

    public WheelView(Theme theme, bool forSettings = false)
    {
        this.theme = theme;
        Width = Height = forSettings ? 212 : 180;
        if (forSettings) { inner = 31; outer = 96; iconSize = 20; gap = 4.5; }
        Focusable = forSettings;
        AutomationProperties.SetName(this, "PinPin 功能轮盘");
        RebuildGeometry();
    }

    public void Configure(WheelSettings value, IReadOnlyList<WheelSlot>? positions = null)
    {
        settings = value.Copy(); slots = positions?.ToArray() ?? WheelGeometry.Standard(value.Slots.Length);
        selected = null; RebuildGeometry(); InvalidateVisual();
        AutomationProperties.SetHelpText(this, string.Join("；", settings.Slots.Select((x, i) => $"第{i + 1}格：{(x is { } a ? FeatureNames.Name(a) : "空")}")));
    }

    public void PointTo(int? slot)
    {
        if (selected == slot) return;
        selected = slot; InvalidateVisual();
        AutomationProperties.SetItemStatus(this, slot is { } index && index < settings.Slots.Length && settings.Slots[index] is { } action
            ? $"已指向{FeatureNames.Name(action)}" : "中心取消或空格");
    }
    public void Edit(ActionKind? action) { editing = action; InvalidateVisual(); }
    private void RebuildGeometry()
    {
        geometries.Clear();
        foreach (var slot in slots) geometries[slot.Index] = MatteDrawing.Sector(Center, inner, outer, slot, slots.Count == 1 ? 0 : gap);
    }
    public int? Hit(Point point, bool restrictToTray = false)
    {
        double dx = point.X - Center.X, dy = point.Y - Center.Y;
        if (restrictToTray && Math.Sqrt(dx * dx + dy * dy) > outer + 10) return null;
        var anchor = new TargetAnchor(Guid.Empty, new(Center.X, Center.Y), 0, 0, new(0, 0, Width, Height));
        var snapshot = new WheelSnapshot(anchor, settings, slots, [], inner, outer);
        return WheelGeometry.HitTest(snapshot, new(point.X, point.Y));
    }
    public bool InCancel(Point point) => (point - Center).Length < inner;
    public bool InTray(Point point) => (point - Center).Length <= outer + 10;

    protected override void OnRender(DrawingContext dc)
    {
        var p = theme.Palette;
        var center = Center;
        MatteDrawing.Surface(dc, new Rect(center.X - outer - 9, center.Y - outer - 9, (outer + 9) * 2, (outer + 9) * 2), outer + 9, p, depth: 2.4);
        foreach (var slot in slots)
        {
            if (!geometries.TryGetValue(slot.Index, out var geometry) || slot.Index >= settings.Slots.Length) continue;
            var action = settings.Slots[slot.Index]; bool pressed = selected == slot.Index && action is not null;
            bool empty = action is null;
            if (!pressed && !empty)
            {
                for (int i = 8; i >= 1; i--)
                {
                    double offset = 1.8 * i / 8;
                    dc.PushOpacity(.055 * (1 - .4 * i / 8d)); dc.PushTransform(new TranslateTransform(-offset, -offset));
                    dc.DrawGeometry(p.LightEdge, null, geometry); dc.Pop();
                    dc.PushTransform(new TranslateTransform(offset, offset)); dc.DrawGeometry(p.DarkEdge, null, geometry); dc.Pop(); dc.Pop();
                }
            }
            dc.DrawGeometry(pressed || empty ? p.Well : p.Surface, p.HighContrast ? p.HairlinePen : null, geometry);
            if (pressed || empty)
            {
                double depth = pressed ? 1.8 : .8;
                dc.PushClip(geometry);
                for (int i = 8; i >= 1; i--)
                {
                    double width = Math.Max(.35, depth * 2.6 * i / 8);
                    dc.PushOpacity(.055); dc.PushTransform(new TranslateTransform(depth, depth));
                    dc.DrawGeometry(null, Palette.Pen(p.DarkEdge, width), geometry); dc.Pop();
                    dc.PushTransform(new TranslateTransform(-depth, -depth));
                    dc.DrawGeometry(null, Palette.Pen(p.LightEdge, width), geometry); dc.Pop(); dc.Pop();
                }
                dc.Pop();
            }
            if (action is not { } kind) continue;
            double angularWidth = slot.Half * 2;
            double radius = angularWidth < 15 * Math.PI / 180 ? outer - 10 : (inner + outer) / 2 + (angularWidth < 40 * Math.PI / 180 ? 6 : 0);
            double size = angularWidth < 40 * Math.PI / 180 ? iconSize * Math.Clamp(angularWidth / (40 * Math.PI / 180), .5, .82) : iconSize;
            var at = new Point(center.X + Math.Cos(slot.Mid) * radius, center.Y - Math.Sin(slot.Mid) * radius);
            var ink = p.Feature(kind, settings);
            if (editing is not null && editing != kind) dc.PushOpacity(.28);
            if (pressed)
            {
                dc.PushOpacity(.10); dc.DrawEllipse(ink, null, at, size * .7, size * .7); dc.Pop();
            }
            Icons.Draw(dc, MatteDrawing.Icon(kind), new Rect(at.X - size / 2, at.Y - size / 2, size, size), ink);
            if (editing is not null && editing != kind) dc.Pop();
        }
        double well = outer > 80 ? 24 : 20;
        MatteDrawing.Surface(dc, new Rect(center.X - well, center.Y - well, well * 2, well * 2), well, p, true, 1.2);
        dc.PushOpacity(.4); dc.DrawEllipse(p.Tertiary, null, center, 2, 2); dc.Pop();
    }
    protected override AutomationPeer OnCreateAutomationPeer() => new WheelPeer(this);
    private sealed class WheelPeer(WheelView owner) : FrameworkElementAutomationPeer(owner)
    {
        protected override string GetClassNameCore() => "PinPinWheel";
        protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Group;
    }
}

internal sealed class GestureWheelWindow : MatteWindow
{
    private readonly WheelView wheel;
    private WheelSnapshot? snapshot;
    public bool Showing => snapshot is not null;
    public GestureWheelWindow(Theme theme, Action<nint> ownWindow) : base("PinPin 功能轮盘", true, ownWindow, true, true)
    { wheel = new(theme); Content = wheel; Width = Height = 180; }
    public void ShowSnapshot(WheelSnapshot value)
    {
        snapshot = value with { Settings = value.Settings.Copy(), Slots = value.Slots.ToArray(), Screens = value.Screens.ToArray() };
        wheel.Configure(snapshot.Settings, snapshot.Slots);
        double scale = snapshot.Anchor.Scale > 0 ? snapshot.Anchor.Scale : 1;
        ShowPhysical(new(snapshot.Anchor.Point.X - 90 * scale, snapshot.Anchor.Point.Y - 90 * scale, 180 * scale, 180 * scale));
    }
    public void MovePointer(ScreenPoint point)
    { if (snapshot is { } value) wheel.PointTo(WheelGeometry.HitTest(value, point)); }
    public void Dismiss() { snapshot = null; Hide(); }
    public void Repaint() => wheel.InvalidateVisual();
}
