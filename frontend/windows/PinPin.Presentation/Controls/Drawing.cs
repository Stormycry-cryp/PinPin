using System.Globalization;
using System.Windows;
using System.Windows.Media;
using PinPin.Core;

namespace PinPin.Presentation.Controls;

internal static class MatteDrawing
{
    public static void Frame(DrawingContext dc, Rect bounds, double radius, Palette palette)
    {
        if (bounds.Width <= 1 || bounds.Height <= 1) return;
        // Window bounds are the visible panel. Keep the bevel inside them instead of
        // clipping a control's outward shadow against the transparent HWND edge.
        bounds.Inflate(-.5, -.5);
        dc.DrawRoundedRectangle(palette.Surface, null, bounds, radius, radius);
        dc.PushOpacity(palette.HighContrast ? 1 : .38);
        dc.DrawRoundedRectangle(null, Palette.Pen(palette.Bevel, 1), bounds, radius, radius);
        dc.Pop();
        if (palette.HighContrast) dc.DrawRoundedRectangle(null, palette.HairlinePen, bounds, radius, radius);
    }

    public static void Surface(DrawingContext dc, Rect bounds, double radius, Palette palette, bool pressed = false, double depth = 1.5)
    {
        if (bounds.Width <= 0 || bounds.Height <= 0) return;
        radius = Math.Min(radius, Math.Min(bounds.Width, bounds.Height) / 2);
        if (!pressed)
        {
            // Small retained vector layers approximate a soft falloff. No bitmap blur,
            // extra visual subtree or animation is allocated for individual controls.
            for (int i = 8; i >= 1; i--)
            {
                double t = i / 8d, spread = t * depth * 1.35;
                var shadow = new Rect(bounds.X + depth, bounds.Y + depth, bounds.Width, bounds.Height);
                shadow.Inflate(spread, spread);
                dc.PushOpacity(.045 * (1 - .6 * t));
                dc.DrawRoundedRectangle(palette.DarkEdge, null, shadow, radius + spread, radius + spread);
                shadow.Offset(-2 * depth, -2 * depth);
                dc.DrawRoundedRectangle(palette.LightEdge, null, shadow, radius + spread, radius + spread);
                dc.Pop();
            }
        }
        dc.DrawRoundedRectangle(pressed ? palette.Well : palette.Surface, null, bounds, radius, radius);
        if (pressed)
        {
            dc.PushClip(new RectangleGeometry(bounds, radius, radius));
            for (int i = 8; i >= 1; i--)
            {
                double width = Math.Max(.35, depth * 2.6 * i / 8);
                dc.PushOpacity(.055);
                dc.DrawRoundedRectangle(null, Palette.Pen(palette.DarkEdge, width),
                    new Rect(bounds.X + depth, bounds.Y + depth, bounds.Width, bounds.Height), radius, radius);
                dc.DrawRoundedRectangle(null, Palette.Pen(palette.LightEdge, width),
                    new Rect(bounds.X - depth, bounds.Y - depth, bounds.Width, bounds.Height), radius, radius);
                dc.Pop();
            }
            dc.Pop();
        }
        if (palette.HighContrast) dc.DrawRoundedRectangle(null, palette.HairlinePen, bounds, radius, radius);
    }

    public static StreamGeometry Sector(Point center, double inner, double outer, WheelSlot slot, double gap)
    {
        double span = slot.Half * 2;
        double trim = Math.Min(gap / Math.Max(inner, 1) / 2, span * .12);
        double start = slot.Mid + slot.Half - trim, end = slot.Mid - slot.Half + trim;
        var geometry = new StreamGeometry { FillRule = FillRule.EvenOdd };
        Point P(double r, double a) => new(center.X + Math.Cos(a) * r, center.Y - Math.Sin(a) * r);
        using (var c = geometry.Open())
        {
            c.BeginFigure(P(outer, start), true, true);
            // Split a full ring into two arcs so 1-slot geometry does not collapse to a line.
            double middle = (start + end) / 2;
            c.ArcTo(P(outer, middle), new Size(outer, outer), 0, start - middle > Math.PI, SweepDirection.Clockwise, true, false);
            c.ArcTo(P(outer, end), new Size(outer, outer), 0, middle - end > Math.PI, SweepDirection.Clockwise, true, false);
            c.LineTo(P(inner, end), true, false);
            c.ArcTo(P(inner, middle), new Size(inner, inner), 0, middle - end > Math.PI, SweepDirection.Counterclockwise, true, false);
            c.ArcTo(P(inner, start), new Size(inner, inner), 0, start - middle > Math.PI, SweepDirection.Counterclockwise, true, false);
        }
        geometry.Freeze(); return geometry;
    }

    public static string Icon(ActionKind kind) => kind switch
    { ActionKind.Explain => "question", ActionKind.Translate => "translate", ActionKind.Rewrite => "pencil", ActionKind.Save => "bookmark", ActionKind.ReplyCoach => "brain", _ => "eyedropper" };
}

/// Original geometric paths, drawn for this client. No Apple symbol fonts or external icon assets.
internal static class Icons
{
    private static readonly Dictionary<string, Geometry> paths = [];
    private static readonly Dictionary<string, string> definitions = new()
    {
        ["question"] = "M 5,4 C 5,0 12,0 12,4 C 12,7 8,6 8,10 M 8,13 L 8,14",
        ["translate"] = "M 3,2 L 13,2 Q 14,2 14,3 L 14,11 Q 14,12 13,12 L 8,12 L 4,15 L 4,12 L 3,12 Q 2,12 2,11 L 2,3 Q 2,2 3,2 Z M 5,10 L 8,4 L 11,10 M 6,8 L 10,8",
        ["pencil"] = "M 3,10 L 11,2 L 13,4 L 5,12 L 2,13 Z M 10,3 L 12,5 M 7,14 L 14,14",
        ["bookmark"] = "M 4,2 L 12,2 L 12,14 L 8,11 L 4,14 Z",
        ["eyedropper"] = "M 2,12 L 9,5 L 11,7 L 4,14 L 2,14 Z M 8,3 L 13,8 M 10,4 L 13,1 L 15,3 L 12,6",
        ["brain"] = "M 8,3 C 7,1 4.5,1 4,3 C 2,3 1.5,5 2.5,6.5 C 1,8 1.5,10.5 3.5,11 C 3,13 5.5,14.5 7,13 C 7.5,13.8 8,13.5 8,12 C 8,13.5 8.5,13.8 9,13 C 10.5,14.5 13,13 12.5,11 C 14.5,10.5 15,8 13.5,6.5 C 14.5,5 14,3 12,3 C 11.5,1 9,1 8,3 L 8,12 M 4,5 Q 6,5 6,7 M 12,9 Q 10,9 10,11",
        ["close"] = "M 4,4 L 12,12 M 12,4 L 4,12",
        ["plus"] = "M 8,3 L 8,13 M 3,8 L 13,8",
        ["minus"] = "M 3,8 L 13,8",
        ["down"] = "M 3,6 L 8,11 L 13,6",
        ["back"] = "M 10,3 L 5,8 L 10,13",
        ["send"] = "M 8,13 L 8,3 M 3,8 L 8,3 L 13,8",
        ["copy"] = "M 6,5 L 13,5 L 13,14 L 6,14 Z M 10,5 L 10,2 L 3,2 L 3,11 L 6,11",
        ["trash"] = "M 3,4 L 13,4 M 6,4 L 6,2 L 10,2 L 10,4 M 4,4 L 5,14 L 11,14 L 12,4 M 7,6 L 7,11 M 9,6 L 9,11",
        ["assets"] = "M 2,6 L 4,3 L 12,3 L 14,6 L 14,13 L 2,13 Z M 2,8 L 6,8 L 6,10 L 10,10 L 10,8 L 14,8 M 5,5 L 11,5",
        ["sun"] = "M 8,1 L 8,3 M 8,13 L 8,15 M 1,8 L 3,8 M 13,8 L 15,8 M 3,3 L 4,4 M 12,12 L 13,13 M 3,13 L 4,12 M 12,4 L 13,3 M 11,8 A 3,3 0 1 1 5,8 A 3,3 0 1 1 11,8",
        ["moon"] = "M 11,2 C 3,-1 -1,10 6,14 C 10,16 15,12 14,8 C 9,10 6,5 11,2 Z",
        ["search"] = "M 11,7 A 4,4 0 1 1 3,7 A 4,4 0 1 1 11,7 M 10,10 L 14,14",
        ["warning"] = "M 8,2 L 8,9 M 8,12 L 8,13",
        ["check"] = "M 3,8 L 6,11 L 13,4",
        ["retry"] = "M 12,4 A 5,5 0 1 0 13,10 M 12,1 L 12,5 L 8,5"
    };

    public static Geometry Path(string name)
    {
        if (paths.TryGetValue(name, out var cached)) return cached;
        var geometry = Geometry.Parse(definitions.GetValueOrDefault(name) ?? definitions["question"]);
        geometry.Freeze(); paths[name] = geometry; return geometry;
    }

    public static void Draw(DrawingContext dc, string name, Rect bounds, Brush brush, double line = 1.55)
    {
        var path = Path(name);
        Rect ink = path.Bounds;
        // Paths retain their common 16-unit scale; only empty sidebearings are balanced.
        double dx = 8 - (ink.Left + ink.Right) / 2, dy = 8 - (ink.Top + ink.Bottom) / 2;
        dc.PushTransform(new TranslateTransform(bounds.X, bounds.Y));
        dc.PushTransform(new ScaleTransform(bounds.Width / 16, bounds.Height / 16));
        dc.PushTransform(new TranslateTransform(dx, dy));
        var pen = new Pen(brush, name == "brain" ? 1.35 : line) { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round, LineJoin = PenLineJoin.Round };
        pen.Freeze(); dc.DrawGeometry(null, pen, path); dc.Pop(); dc.Pop(); dc.Pop();
    }
}

internal sealed class Glyph : FrameworkElement
{
    public string NameOfIcon { get; set; }
    public Brush Ink { get; set; }
    public Glyph(string name, Brush ink, double size = 11) { NameOfIcon = name; Ink = ink; Width = Height = size; IsHitTestVisible = false; }
    protected override void OnRender(DrawingContext dc) => Icons.Draw(dc, NameOfIcon, new Rect(0, 0, ActualWidth, ActualHeight), Ink);
}
