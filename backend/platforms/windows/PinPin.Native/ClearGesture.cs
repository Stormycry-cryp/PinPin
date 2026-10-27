using PinPin.Core;

namespace PinPin.Native;

// Direct value-rule port of Mac POClearGesture in UIGestureRules.swift. Windows times are ms,
// positions are physical pixels; slop and the shared neutral radius use the first anchor's scale.
internal sealed class ClearGesture
{
    internal double IntervalMilliseconds { get; set; }
    private double slop=6,neutralRadius=WheelGeometry.CancelRadius;
    private ScreenPoint? center;
    private (ScreenPoint Point,long Time)? press,firstTap;
    private bool moved,secondPress;

    internal ClearGesture(double intervalMilliseconds) { IntervalMilliseconds=intervalMilliseconds; }

    internal void Down(ScreenPoint point,long time,bool startsSession,double scale)
    {
        moved=false;
        press=(point,time);
        if (startsSession)
        {
            center=point;
            slop=6*scale; neutralRadius=WheelGeometry.CancelRadius*scale;
            firstTap=null; secondPress=false;
            return;
        }
        if (firstTap is { } tap && IsNeutral(point) && time-tap.Time<=IntervalMilliseconds && Distance(point,tap.Point)<=slop)
            secondPress=true;
        else { firstTap=null; secondPress=false; }
    }

    internal void Dragged(ScreenPoint point)
    { if (press is { } current && Distance(point,current.Point)>slop) moved=true; }

    internal bool Up(ScreenPoint point,long time)
    {
        try
        {
            if (press is not { } current || moved || !IsNeutral(current.Point) || !IsNeutral(point)
                || time-current.Time>IntervalMilliseconds)
            { firstTap=null; secondPress=false; return false; }
            if (secondPress) { firstTap=null; secondPress=false; return true; }
            firstTap=(current.Point,time);
            return false;
        }
        finally { press=null; moved=false; }
    }

    internal void Reset()
    { center=null; press=null; moved=false; firstTap=null; secondPress=false; }
    private bool IsNeutral(ScreenPoint point) => center is { } origin && Distance(point,origin)<neutralRadius;
    private static double Distance(ScreenPoint a,ScreenPoint b)
        => Math.Sqrt((a.X-b.X)*(a.X-b.X)+(a.Y-b.Y)*(a.Y-b.Y));
}
