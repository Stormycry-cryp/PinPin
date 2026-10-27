using System.IO;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using PinPin.Core;

namespace PinPin.Presentation.Controls;

internal sealed class AssetImage : FrameworkElement
{
    private readonly Palette palette;
    private readonly string path;
    private readonly ScreenPoint? originalPoint;
    private readonly bool thumbnail;
    private BitmapSource? bitmap;
    private bool loading, failed;
    private int generation;
    public AssetImage(Palette palette, string path, ScreenPoint? point, bool thumbnail)
    {
        this.palette = palette; this.path = path; originalPoint = point; this.thumbnail = thumbnail;
        if (thumbnail) Width = Height = 38;
        else MaxHeight = 180;
        Loaded += (_, _) => Load();
        Unloaded += (_, _) => { generation++; loading = false; bitmap = null; };
    }
    private async void Load()
    {
        if (loading || bitmap is not null) return;
        loading = true; int current = ++generation;
        try
        {
            BitmapSource image = await Task.Run(() =>
            {
                using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
                var decoded = new BitmapImage();
                decoded.BeginInit(); decoded.CacheOption = BitmapCacheOption.OnLoad;
                decoded.DecodePixelWidth = thumbnail ? 96 : 900;
                decoded.StreamSource = stream; decoded.EndInit(); decoded.Freeze(); return decoded;
            });
            if (current != generation) return;
            bitmap = image; failed = false;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or NotSupportedException or System.FormatException)
        { if (current == generation) failed = true; }
        finally { if (current == generation) { loading = false; InvalidateMeasure(); InvalidateVisual(); } }
    }
    protected override Size MeasureOverride(Size available)
    {
        if (thumbnail) return new(38, 38);
        double width = double.IsFinite(available.Width) ? available.Width : 296;
        return new(width, bitmap is null ? 64 : Math.Min(180, width * bitmap.PixelHeight / Math.Max(1d, bitmap.PixelWidth)));
    }
    protected override void OnRender(DrawingContext dc)
    {
        var rect = new Rect(0, 0, ActualWidth, ActualHeight);
        MatteDrawing.Surface(dc, rect, thumbnail ? 7 : 8, palette, true, 1);
        dc.PushClip(new RectangleGeometry(rect, thumbnail ? 7 : 8, thumbnail ? 7 : 8));
        if (bitmap is not null)
        {
            double factor = Math.Min(ActualWidth / bitmap.PixelWidth, ActualHeight / bitmap.PixelHeight);
            var imageRect = new Rect((ActualWidth - bitmap.PixelWidth * factor) / 2, (ActualHeight - bitmap.PixelHeight * factor) / 2,
                bitmap.PixelWidth * factor, bitmap.PixelHeight * factor);
            dc.DrawImage(bitmap, imageRect);
            if (!thumbnail && originalPoint is { } point)
            {
                // Contract: image points are top-left normalized, unrelated to desktop physical pixels.
                var at = new Point(imageRect.Left + Math.Clamp(point.X, 0, 1) * imageRect.Width,
                    imageRect.Top + Math.Clamp(point.Y, 0, 1) * imageRect.Height);
                dc.DrawEllipse(palette.Accent, Palette.Pen(palette.OnAccent, 1), at, 3, 3);
            }
        }
        else
        {
            Icons.Draw(dc, failed ? "warning" : "bookmark", new Rect((ActualWidth - 16) / 2, (ActualHeight - 16) / 2, 16, 16), palette.Tertiary);
        }
        dc.Pop();
    }
}

internal sealed class ColorSwatch : FrameworkElement
{
    private readonly PixelColor color;
    private readonly Palette palette;
    private readonly SolidColorBrush brush;
    public ColorSwatch(PixelColor color, Palette palette, double side)
    { this.color = color; this.palette = palette; Width = Height = side; brush = new(Color.FromRgb(color.Red, color.Green, color.Blue)); brush.Freeze();
      System.Windows.Automation.AutomationProperties.SetName(this, $"颜色 {color.Hex}，{color.ColorSpace}"); }
    protected override void OnRender(DrawingContext dc)
        => dc.DrawRoundedRectangle(brush, palette.HairlinePen, new Rect(.5, .5, Math.Max(0, ActualWidth - 1), Math.Max(0, ActualHeight - 1)), 7, 7);
}
