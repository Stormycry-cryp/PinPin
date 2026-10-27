namespace PinPin.Core;

/// The Mac POWheelLayout algorithm, using Windows physical pixels and downward y.
public static class WheelGeometry
{
    public const double CancelRadius = 26;
    public const double OuterRadius = 80;
    public static IReadOnlyList<WheelSlot> Standard(int count)
    {
        int n = Math.Clamp(count, 1, 8); double width = 2 * Math.PI / n;
        return Enumerable.Range(0, n).Select(i => new WheelSlot(i, Math.PI / 2 - i * width, width / 2)).ToArray();
    }
    private static double Distance(double a, double b) => Math.Abs(Math.Atan2(Math.Sin(a - b), Math.Cos(a - b)));
    public static WheelSnapshot Create(TargetAnchor anchor, WheelSettings settings, IReadOnlyList<ScreenRect> screens)
    {
        if (!settings.IsValid) throw new ArgumentException("Invalid wheel settings.");
        var scale = double.IsFinite(anchor.Scale) && anchor.Scale > 0 ? anchor.Scale : 1;
        var slots = Slots(settings.Slots.Length, anchor.Point, screens, (OuterRadius + 3) * scale, 80 * Math.PI / 180);
        return new(anchor, settings.Copy(), slots, screens.ToArray(), CancelRadius * scale, OuterRadius * scale);
    }
    public static IReadOnlyList<WheelSlot> Slots(int count, ScreenPoint origin, IReadOnlyList<ScreenRect> screens,
        double ringRadius, double minSpan)
    {
        int n = Math.Clamp(count, 1, 8), samples = 180;
        var ok = new bool[samples];
        for (int i = 0; i < samples; i++)
        {
            double a = i * 2 * Math.PI / 180;
            var point = new ScreenPoint(origin.X + Math.Cos(a) * ringRadius, origin.Y - Math.Sin(a) * ringRadius);
            ok[i] = screens.Any(s => s.Contains(point));
        }
        int firstOff = Array.IndexOf(ok, false);
        if (firstOff < 0 || !ok.Any(x => x)) return Standard(n);
        int bestStart = 0, bestLength = 0, runStart = 0, runLength = 0;
        for (int k = 1; k <= samples; k++)
        {
            int index = (firstOff + k) % samples;
            if (!ok[index]) { runLength = 0; continue; }
            if (runLength == 0) runStart = index;
            runLength++;
            if (runLength > bestLength) { bestLength = runLength; bestStart = runStart; }
        }
        double start = bestStart * 2 * Math.PI / 180, span = Math.Max(bestLength - 1, 1) * 2 * Math.PI / 180;
        if (span < minSpan) { start -= (minSpan - span) / 2; span = minSpan; }
        double width = span / n;
        var mids = Enumerable.Range(0, n).Select(i => start + span - (i + .5) * width).ToArray();
        var standard = Standard(n); int rotation = 0; double best = double.PositiveInfinity;
        for (int r = 0; r < n; r++)
        {
            double cost = Enumerable.Range(0, n).Sum(i => Distance(mids[i], standard[(i + r) % n].Mid));
            if (cost < best) { best = cost; rotation = r; }
        }
        return Enumerable.Range(0, n).Select(i => new WheelSlot((i + rotation) % n, mids[i], width / 2)).ToArray();
    }
    public static int? HitTest(WheelSnapshot snapshot, ScreenPoint point)
    {
        double dx = point.X - snapshot.Anchor.Point.X, dy = snapshot.Anchor.Point.Y - point.Y;
        if (!double.IsFinite(dx) || !double.IsFinite(dy) || Math.Sqrt(dx * dx + dy * dy) < snapshot.CancelRadius || snapshot.Slots.Count == 0) return null;
        double angle = Math.Atan2(dy, dx), best = double.PositiveInfinity; int? chosen = null;
        foreach (var slot in snapshot.Slots)
        {
            double distance = Math.Max(Distance(angle, slot.Mid) - slot.Half, 0);
            if (distance < best) { best = distance; chosen = slot.Index; }
        }
        return chosen;
    }
    public static ActionKind? ActionAt(WheelSnapshot snapshot, ScreenPoint point) =>
        HitTest(snapshot, point) is { } i && i >= 0 && i < snapshot.Settings.Slots.Length ? snapshot.Settings.Slots[i] : null;
}
