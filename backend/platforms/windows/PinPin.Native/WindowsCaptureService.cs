using System.ComponentModel;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using PinPin.Core;

namespace PinPin.Native;

public sealed class WindowsCaptureService : ICaptureService, IDisposable
{
    private readonly SelectionProbe selection=new();
    private int disposed;
    public Exception? LastSelectionFault => selection.LastFault;
    public Exception? LastCaptureFault { get; private set; }

    public async Task<CapturedEvidence> CaptureAsync(TargetAnchor anchor, CancellationToken cancellationToken)
    {
        ObjectDisposedException.ThrowIf(Volatile.Read(ref disposed)!=0,this);
        cancellationToken.ThrowIfCancellationRequested();
        var frameTask=Task.Run(() => Freeze(anchor,cancellationToken),cancellationToken);
        FrozenFrame? frame=null;
        try
        {
            var text=await selection.TryProbeAsync(anchor,cancellationToken).ConfigureAwait(false);
            try { frame=await frameTask.ConfigureAwait(false); }
            catch (Exception error) when (error is not OperationCanceledException && text.Text.Length>0)
            {
                // An explicit selection remains usable when desktop capture is unavailable.
                // There is no visual fallback, stale frame or implied capture permission in this result.
                LastCaptureFault=error;
                cancellationToken.ThrowIfCancellationRequested();
                ObjectDisposedException.ThrowIf(Volatile.Read(ref disposed)!=0,this);
                var metadata=ReadMetadata(anchor);
                cancellationToken.ThrowIfCancellationRequested();
                return new CapturedEvidence(anchor,text.Text,text.Text,metadata.AppName,metadata.WindowTitle,null);
            }
            cancellationToken.ThrowIfCancellationRequested();
            ObjectDisposedException.ThrowIf(Volatile.Read(ref disposed)!=0,this);
            var localCrop=CaptureGeometry.LocalCrop(frame.Bounds,anchor.Point,anchor.Scale);
            bool hasSelection=text.Text.Length>0;
            ImageEvidence? image=hasSelection ? null : frame.Encode(localCrop,cancellationToken);
            cancellationToken.ThrowIfCancellationRequested();
            var retained=frame;
            // Core requests this local supplement only for explicit-selection Explain, without Jev.
            // Other text actions keep their selection; visual-only requests may expand the full frame.
            Func<CancellationToken,Task<ImageEvidence?>>? supplement=hasSelection
                ? token => retained.EncodeOnceAsync(localCrop,token)
                : localCrop!=frame.Bounds ? retained.ExpandAsync : null;
            var result=new CapturedEvidence(anchor,text.Text,text.Text,frame.AppName,frame.WindowTitle,image,
                supplement,retained.Dispose,retained.ExpandAsync);
            frame=null; // Ownership transfers exactly once to CapturedEvidence.
            return result;
        }
        catch
        {
            if (frame!=null) frame.Dispose();
            else _=ReleaseWhenReadyAsync(frameTask);
            throw;
        }
    }

    public void Dispose()
    { if (Interlocked.Exchange(ref disposed,1)==0) selection.Dispose(); }

    private static async Task ReleaseWhenReadyAsync(Task<FrozenFrame> task)
    { try { (await task.ConfigureAwait(false)).Dispose(); } catch { /* Observe a failed/cancelled capture during cleanup. */ } }

    private static FrozenFrame Freeze(TargetAnchor anchor, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (!CaptureGeometry.ValidPoint(anchor.Point)) throw new InvalidOperationException("invalid_geometry");
        var monitor=NativeMethods.MonitorBounds(anchor.Point);
        var bounds=monitor;
        string title="", app="";
        if (anchor.Window!=0)
        {
            if (!NativeMethods.IsWindow(anchor.Window) || !NativeMethods.IsWindowVisible(anchor.Window))
                throw new InvalidOperationException("source_unavailable");
            NativeMethods.GetWindowThreadProcessId(anchor.Window,out uint pid);
            if (pid!=(uint)anchor.ProcessId || !NativeMethods.GetWindowRect(anchor.Window,out var rect))
                throw new InvalidOperationException("source_changed");
            var current=rect.ToScreenRect();
            if (!current.Contains(anchor.Point)) throw new InvalidOperationException("source_changed");
            if (NativeMethods.DwmGetWindowAttribute(anchor.Window,9,out NativeMethods.Rect visible,Marshal.SizeOf<NativeMethods.Rect>())==0
                && visible.ToScreenRect().Contains(anchor.Point)) current=visible.ToScreenRect();
            // Clip to the virtual desktop's bounding box; do not capture off-screen window memory.
            ScreenRect desktop=VirtualDesktopBounds();
            bounds=CaptureGeometry.Intersection(current,desktop) ?? throw new InvalidOperationException("invalid_geometry");
            (app,title)=ReadMetadata(anchor);
        }
        if (!CaptureGeometry.ValidRect(bounds) || !bounds.Contains(anchor.Point)) throw new InvalidOperationException("invalid_geometry");
        cancellationToken.ThrowIfCancellationRequested();
        var bitmap=new Bitmap(checked((int)bounds.Width),checked((int)bounds.Height),PixelFormat.Format32bppArgb);
        try
        {
            using (var graphics=Graphics.FromImage(bitmap))
                graphics.CopyFromScreen(checked((int)bounds.X),checked((int)bounds.Y),0,0,bitmap.Size,CopyPixelOperation.SourceCopy);
            cancellationToken.ThrowIfCancellationRequested();
            return new FrozenFrame(bitmap,bounds,anchor.Point,app,title);
        }
        catch { bitmap.Dispose(); throw; }
    }

    private static (string AppName,string WindowTitle) ReadMetadata(TargetAnchor anchor)
    {
        var title=new StringBuilder(1024);
        if (anchor.Window!=0) NativeMethods.GetWindowText(anchor.Window,title,title.Capacity);
        string app="";
        try { using var process=Process.GetProcessById(anchor.ProcessId); app=process.ProcessName; }
        catch (ArgumentException) { }
        catch (Win32Exception) { }
        catch (InvalidOperationException) { }
        return (app,title.ToString());
    }

    private static ScreenRect VirtualDesktopBounds()
    {
        var rectangles=new List<ScreenRect>();
        NativeMethods.MonitorEnum collect=(nint monitor,nint dc,ref NativeMethods.Rect rect,nint data) =>
        { rectangles.Add(rect.ToScreenRect()); return true; };
        if (!NativeMethods.EnumDisplayMonitors(0,0,collect,0) || rectangles.Count==0)
            throw new Win32Exception(Marshal.GetLastWin32Error());
        double left=rectangles.Min(r=>r.X),top=rectangles.Min(r=>r.Y);
        return new(left,top,rectangles.Max(r=>r.Right)-left,rectangles.Max(r=>r.Bottom)-top);
    }

    private sealed class FrozenFrame : IDisposable
    {
        private readonly object gate=new();
        private Bitmap? bitmap;
        private readonly ScreenPoint point;
        private int expanded;
        internal ScreenRect Bounds { get; }
        internal string AppName { get; }
        internal string WindowTitle { get; }
        internal FrozenFrame(Bitmap bitmap,ScreenRect bounds,ScreenPoint point,string appName,string windowTitle)
        { this.bitmap=bitmap; Bounds=bounds; this.point=point; AppName=appName; WindowTitle=windowTitle; }

        internal Task<ImageEvidence?> ExpandAsync(CancellationToken cancellationToken) => EncodeOnceAsync(Bounds,cancellationToken);

        internal Task<ImageEvidence?> EncodeOnceAsync(ScreenRect crop,CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (Interlocked.Exchange(ref expanded,1)!=0) return Task.FromResult<ImageEvidence?>(null);
            return Task.Run<ImageEvidence?>(() => Encode(crop,cancellationToken),cancellationToken);
        }

        internal ImageEvidence Encode(ScreenRect crop,CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            lock (gate)
            {
                ObjectDisposedException.ThrowIf(bitmap==null,this);
                cancellationToken.ThrowIfCancellationRequested();
                var layout=CaptureGeometry.Layout(crop,point);
                using var image=new Bitmap(layout.Width,layout.Height,PixelFormat.Format24bppRgb);
                using (var graphics=Graphics.FromImage(image))
                {
                    graphics.Clear(Color.White);
                    graphics.InterpolationMode=InterpolationMode.HighQualityBicubic;
                    graphics.PixelOffsetMode=PixelOffsetMode.HighQuality;
                    graphics.DrawImage(bitmap!,new RectangleF((float)layout.OffsetX,(float)layout.OffsetY,
                        (float)(crop.Width*layout.Scale),(float)(crop.Height*layout.Scale)),
                        new RectangleF((float)(crop.X-Bounds.X),(float)(crop.Y-Bounds.Y),(float)crop.Width,(float)crop.Height),GraphicsUnit.Pixel);
                }
                byte[] original;
                using (var png=new MemoryStream()) { image.Save(png,ImageFormat.Png); original=png.ToArray(); }
                cancellationToken.ThrowIfCancellationRequested();
                using (var graphics=Graphics.FromImage(image)) DrawReferenceArrow(graphics,layout);
                byte[] marked;
                using (var jpeg=new MemoryStream())
                using (var parameters=new EncoderParameters(1))
                {
                    parameters.Param[0]=new EncoderParameter(System.Drawing.Imaging.Encoder.Quality,84L);
                    var encoder=ImageCodecInfo.GetImageEncoders().First(codec=>codec.MimeType=="image/jpeg");
                    image.Save(jpeg,encoder,parameters); marked=jpeg.ToArray();
                }
                cancellationToken.ThrowIfCancellationRequested();
                return new(original,marked,layout.Width,layout.Height,layout.Point,layout.Point,crop);
            }
        }

        private static void DrawReferenceArrow(Graphics graphics,ImageLayout layout)
        {
            float x=(float)(layout.Point.X*layout.Width),y=(float)(layout.Point.Y*layout.Height);
            float dx=x+26<layout.Width-4 ? 22 : -22,dy=y>50 ? -44 : 44;
            float length=MathF.Sqrt(dx*dx+dy*dy),ux=dx/length,uy=dy/length;
            var red=Color.FromArgb(242,31,31);
            using var pen=new Pen(red,2);
            using var brush=new SolidBrush(red);
            graphics.SmoothingMode=SmoothingMode.AntiAlias;
            graphics.DrawLine(pen,x+dx,y+dy,x,y);
            graphics.FillPolygon(brush,[new PointF(x,y),new PointF(x+ux*12-uy*4,y+uy*12+ux*4),
                new PointF(x+ux*12+uy*4,y+uy*12-ux*4)]);
        }

        public void Dispose()
        { lock (gate) { bitmap?.Dispose(); bitmap=null; } }
    }
}
