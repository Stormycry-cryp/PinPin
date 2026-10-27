using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using PinPin.Core;

namespace PinPin.Presentation;

internal readonly record struct MonitorArea(nint Handle, ScreenRect Bounds, ScreenRect Work, double Scale);

internal static class NativeWindow
{
    internal const int GwlExStyle = -20;
    internal const long ToolWindow = 0x80, NoActivate = 0x08000000, Transparent = 0x20;
    private const uint NoActivatePosition = 0x10, NoZOrder = 0x4;
    [StructLayout(LayoutKind.Sequential)] internal struct PointI { public int X, Y; public PointI(int x, int y) { X = x; Y = y; } }
    [StructLayout(LayoutKind.Sequential)] private struct RectI { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] private struct MonitorInfo
    { public uint Size; public RectI Monitor, Work; public uint Flags; }
    [DllImport("user32.dll")] private static extern nint MonitorFromPoint(PointI point, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetMonitorInfo(nint monitor, ref MonitorInfo info);
    [DllImport("shcore.dll")] private static extern int GetDpiForMonitor(nint monitor, int type, out uint x, out uint y);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetCursorPos(out PointI point);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] internal static extern nint GetWindowLongPtr(nint hwnd, int index);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] internal static extern nint SetWindowLongPtr(nint hwnd, int index, nint value);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetWindowPos(nint hwnd, nint after, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll")] private static extern int SetWindowRgn(nint hwnd, nint region, bool redraw);
    [DllImport("gdi32.dll")] private static extern nint CreateRectRgn(int left, int top, int right, int bottom);
    [DllImport("gdi32.dll")] private static extern nint CreateEllipticRgn(int left, int top, int right, int bottom);
    [DllImport("gdi32.dll")] private static extern int CombineRgn(nint dest, nint a, nint b, int mode);
    [DllImport("gdi32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool DeleteObject(nint value);

    public static ScreenPoint Cursor()
    { GetCursorPos(out var point); return new(point.X, point.Y); }
    public static MonitorArea Monitor(ScreenPoint point)
    {
        nint handle = MonitorFromPoint(new((int)Math.Round(point.X), (int)Math.Round(point.Y)), 2);
        var info = new MonitorInfo { Size = (uint)Marshal.SizeOf<MonitorInfo>() };
        if (!GetMonitorInfo(handle, ref info))
            return new(handle, new(0, 0, SystemParameters.PrimaryScreenWidth, SystemParameters.PrimaryScreenHeight),
                new(0, 0, SystemParameters.PrimaryScreenWidth, SystemParameters.PrimaryScreenHeight), 1);
        double scale = 1;
        try { if (GetDpiForMonitor(handle, 0, out uint dpi, out _) == 0 && dpi > 0) scale = dpi / 96d; }
        catch (DllNotFoundException) { }
        catch (EntryPointNotFoundException) { }
        ScreenRect Rect(RectI r) => new(r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top);
        return new(handle, Rect(info.Monitor), Rect(info.Work), scale);
    }

    public static void Place(nint hwnd, ScreenRect rect)
        => SetWindowPos(hwnd, 0, (int)Math.Round(rect.X), (int)Math.Round(rect.Y),
            Math.Max(1, (int)Math.Round(rect.Width)), Math.Max(1, (int)Math.Round(rect.Height)), NoActivatePosition | NoZOrder);

    /// Windows owns the final region after SetWindowRgn. Every temporary GDI region is released.
    public static void SetMarkerRegion(nint hwnd, IEnumerable<Rect> physicalCircles)
    {
        nint combined = CreateRectRgn(0, 0, 0, 0);
        foreach (Rect r in physicalCircles)
        {
            nint part = CreateEllipticRgn((int)Math.Floor(r.Left), (int)Math.Floor(r.Top),
                (int)Math.Ceiling(r.Right), (int)Math.Ceiling(r.Bottom));
            CombineRgn(combined, combined, part, 2);
            DeleteObject(part);
        }
        if (SetWindowRgn(hwnd, combined, true) == 0) DeleteObject(combined);
    }
}

internal class MatteWindow : Window
{
    private readonly bool overlay, clickThrough, neverActivate;
    private readonly Action<nint> ownWindow;
    private HwndSource? source;
    public nint Handle { get; private set; }
    public bool AllowInputActivation { get; set; }
    public Action? EscapePressed { get; set; }
    public Action? DpiChangedBySystem { get; set; }
    public ScreenRect? PhysicalPlacement { get; private set; }

    public MatteWindow(string title, bool overlay, Action<nint> ownWindow, bool clickThrough = false, bool neverActivate = false)
    {
        this.overlay = overlay; this.ownWindow = ownWindow;
        this.clickThrough = clickThrough; this.neverActivate = neverActivate;
        Title = title;
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        ShowActivated = !overlay;
        Topmost = overlay;
        FontFamily = Theme.Font;
        Theme.Typography(this);
        UseLayoutRounding = true;
        SnapsToDevicePixels = true;
        PreviewKeyDown += (_, e) => { if (e.Key == Key.Escape) { EscapePressed?.Invoke(); e.Handled = true; } };
    }

    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);
        Handle = new WindowInteropHelper(this).Handle;
        long style = NativeWindow.GetWindowLongPtr(Handle, NativeWindow.GwlExStyle).ToInt64() | NativeWindow.ToolWindow;
        if (neverActivate || clickThrough) style |= NativeWindow.NoActivate;
        if (clickThrough) style |= NativeWindow.Transparent;
        NativeWindow.SetWindowLongPtr(Handle, NativeWindow.GwlExStyle, new nint(style));
        source = HwndSource.FromHwnd(Handle);
        source?.AddHook(Hook);
        ownWindow(Handle);
    }

    private nint Hook(nint hwnd, int message, nint wParam, nint lParam, ref bool handled)
    {
        if (message == 0x21 && overlay && !AllowInputActivation) // WM_MOUSEACTIVATE
        { handled = true; return 3; } // MA_NOACTIVATE, while still receiving the click.
        if (message == 0x84 && clickThrough) { handled = true; return -1; }
        return 0;
    }

    public void ShowPhysical(ScreenRect rect, bool activate = false)
    {
        var monitor = NativeWindow.Monitor(new(rect.X + rect.Width / 2, rect.Y + rect.Height / 2));
        Width = rect.Width / monitor.Scale; Height = rect.Height / monitor.Scale;
        new WindowInteropHelper(this).EnsureHandle();
        PhysicalPlacement = rect;
        NativeWindow.Place(Handle, rect);
        if (!IsVisible) Show();
        NativeWindow.Place(Handle, rect);
        if (activate && !neverActivate) { AllowInputActivation = true; Activate(); }
    }

    public void MovePhysical(ScreenRect rect)
    { PhysicalPlacement = rect; if (Handle != 0) NativeWindow.Place(Handle, rect); }

    public void ShowCentered(double contentWidth, double contentHeight)
    {
        var monitor = NativeWindow.Monitor(NativeWindow.Cursor());
        var work = monitor.Work; double s = monitor.Scale;
        ShowPhysical(new(work.X + (work.Width - contentWidth * s) / 2,
            work.Y + Math.Max(8 * s, (work.Height - contentHeight * s) * .35), contentWidth * s, contentHeight * s), true);
    }

    protected override void OnDpiChanged(DpiScale oldDpi, DpiScale newDpi)
    { base.OnDpiChanged(oldDpi, newDpi); DpiChangedBySystem?.Invoke(); }

    protected override void OnClosed(EventArgs e)
    {
        source?.RemoveHook(Hook); source = null;
        BeginAnimation(OpacityProperty, null);
        base.OnClosed(e);
    }
}
