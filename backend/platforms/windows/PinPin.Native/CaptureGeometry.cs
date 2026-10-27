using PinPin.Core;

namespace PinPin.Native;

internal readonly record struct ImageLayout(int Width, int Height, double Scale, double OffsetX,
    double OffsetY, ScreenPoint Point);

internal static class CaptureGeometry
{
    internal static bool ValidPoint(ScreenPoint point) => double.IsFinite(point.X) && double.IsFinite(point.Y)
        && point.X>=int.MinValue && point.X<=int.MaxValue && point.Y>=int.MinValue && point.Y<=int.MaxValue;
    internal static bool ValidRect(ScreenRect rect) => double.IsFinite(rect.X) && double.IsFinite(rect.Y)
        && double.IsFinite(rect.Right) && double.IsFinite(rect.Bottom) && rect.Width>0 && rect.Height>0;
    internal static ScreenRect? Intersection(ScreenRect first, ScreenRect second)
    {
        double left=Math.Max(first.X,second.X), top=Math.Max(first.Y,second.Y);
        double right=Math.Min(first.Right,second.Right), bottom=Math.Min(first.Bottom,second.Bottom);
        return right>left && bottom>top ? new(left,top,right-left,bottom-top) : null;
    }
    internal static ScreenRect LocalCrop(ScreenRect source, ScreenPoint point, double scale)
    {
        if (!ValidRect(source) || !ValidPoint(point) || !source.Contains(point) || !double.IsFinite(scale) || scale<=0)
            throw new InvalidOperationException("invalid_geometry");
        double width=Math.Min(source.Width,960*scale), height=Math.Min(source.Height,640*scale);
        double left=Math.Clamp(point.X-width/2,source.X,source.Right-width);
        double top=Math.Clamp(point.Y-height/2,source.Y,source.Bottom-height);
        // Integral outward rounding is part of the pointer transform, including negative origins.
        left=Math.Max(source.X,Math.Floor(left)); top=Math.Max(source.Y,Math.Floor(top));
        double right=Math.Min(source.Right,Math.Ceiling(Math.Clamp(point.X-width/2,source.X,source.Right-width)+width));
        double bottom=Math.Min(source.Bottom,Math.Ceiling(Math.Clamp(point.Y-height/2,source.Y,source.Bottom-height)+height));
        return new(left,top,right-left,bottom-top);
    }
    internal static ImageLayout Layout(ScreenRect crop, ScreenPoint point)
    {
        if (!ValidRect(crop) || !ValidPoint(point) || !crop.Contains(point)) throw new InvalidOperationException("invalid_geometry");
        double scale=Math.Min(1,1568/Math.Max(crop.Width,crop.Height));
        int width=Math.Max(280,checked((int)Math.Ceiling(crop.Width*scale)));
        int height=Math.Max(280,checked((int)Math.Ceiling(crop.Height*scale)));
        double offsetX=(width-crop.Width*scale)/2, offsetY=(height-crop.Height*scale)/2;
        var normalized=new ScreenPoint((offsetX+(point.X-crop.X)*scale)/width,
            (offsetY+(point.Y-crop.Y)*scale)/height);
        return new(width,height,scale,offsetX,offsetY,normalized);
    }
}
