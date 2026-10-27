using System.Runtime.InteropServices;
using System.Text;
using PinPin.Core;

namespace PinPin.Native;

internal static class NativeMethods
{
    [StructLayout(LayoutKind.Sequential)]
    internal struct Point { public int X, Y; public Point(int x, int y) { X=x; Y=y; } }
    [StructLayout(LayoutKind.Sequential)]
    internal struct Rect
    {
        public int Left, Top, Right, Bottom;
        public readonly ScreenRect ToScreenRect() => new(Left, Top, Right-Left, Bottom-Top);
    }
    [StructLayout(LayoutKind.Sequential)]
    internal struct MonitorInfo { public uint Size; public Rect Monitor, Work; public uint Flags; }
    [StructLayout(LayoutKind.Sequential)]
    internal struct MouseData { public Point Point; public uint MouseDataValue, Flags, Time; public nuint ExtraInfo; }
    [StructLayout(LayoutKind.Sequential)]
    internal struct KeyboardData { public uint Key, ScanCode, Flags, Time; public nuint ExtraInfo; }
    [StructLayout(LayoutKind.Sequential)]
    internal struct Message
    { public nint Window; public uint Id; public nuint WParam; public nint LParam; public uint Time; public Point Point; public uint Private; }
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    internal struct WindowClass
    {
        public uint Style; public WindowProc Procedure; public int ClassExtra, WindowExtra;
        public nint Instance, Icon, Cursor, Background;
        public string? MenuName; public string ClassName;
    }
    internal delegate nint HookProc(int code, nint wParam, nint lParam);
    internal delegate nint WindowProc(nint window, uint message, nuint wParam, nint lParam);
    internal delegate bool MonitorEnum(nint monitor, nint dc, ref Rect rect, nint data);
    internal delegate void WinEventProc(nint hook, uint eventId, nint window, int objectId, int childId,
        uint eventThread, uint eventTime);
    [DllImport("user32.dll", EntryPoint="SetWindowsHookExW", SetLastError=true)]
    internal static extern nint SetWindowsHookEx(int type, HookProc callback, nint module, uint threadId);
    [DllImport("user32.dll", SetLastError=true)] [return:MarshalAs(UnmanagedType.Bool)]
    internal static extern bool UnhookWindowsHookEx(nint hook);
    [DllImport("user32.dll")] internal static extern nint CallNextHookEx(nint hook, int code, nint wParam, nint lParam);
    [DllImport("user32.dll", EntryPoint="GetMessageW", SetLastError=true)]
    internal static extern int GetMessage(out Message message, nint window, uint min, uint max);
    [DllImport("user32.dll", EntryPoint="PeekMessageW")] [return:MarshalAs(UnmanagedType.Bool)]
    internal static extern bool PeekMessage(out Message message,nint window,uint min,uint max,uint remove);
    [DllImport("user32.dll")] [return:MarshalAs(UnmanagedType.Bool)] internal static extern bool TranslateMessage(in Message message);
    [DllImport("user32.dll", EntryPoint="DispatchMessageW")] internal static extern nint DispatchMessage(in Message message);
    [DllImport("user32.dll", EntryPoint="PostThreadMessageW", SetLastError=true)] [return:MarshalAs(UnmanagedType.Bool)]
    internal static extern bool PostThreadMessage(uint threadId, uint message, nuint wParam, nint lParam);
    [DllImport("kernel32.dll")] internal static extern uint GetCurrentThreadId();
    [DllImport("kernel32.dll", EntryPoint="GetModuleHandleW", CharSet=CharSet.Unicode)] internal static extern nint GetModuleHandle(string? name);
    [DllImport("user32.dll", EntryPoint="RegisterClassW", SetLastError=true, CharSet=CharSet.Unicode)]
    internal static extern ushort RegisterClass(in WindowClass windowClass);
    [DllImport("user32.dll", EntryPoint="UnregisterClassW", SetLastError=true, CharSet=CharSet.Unicode)] [return:MarshalAs(UnmanagedType.Bool)]
    internal static extern bool UnregisterClass(string name, nint instance);
    [DllImport("user32.dll", EntryPoint="CreateWindowExW", SetLastError=true, CharSet=CharSet.Unicode)]
    internal static extern nint CreateWindowEx(uint style, string className, string title, uint windowStyle, int x, int y,
        int width, int height, nint parent, nint menu, nint instance, nint parameter);
    [DllImport("user32.dll")] [return:MarshalAs(UnmanagedType.Bool)] internal static extern bool DestroyWindow(nint window);
    [DllImport("user32.dll", EntryPoint="DefWindowProcW")] internal static extern nint DefWindowProc(nint window, uint message, nuint wParam, nint lParam);
    [DllImport("user32.dll")] [return:MarshalAs(UnmanagedType.Bool)] internal static extern bool EnumDisplayMonitors(nint dc, nint clip, MonitorEnum callback, nint data);
    [DllImport("user32.dll", EntryPoint="GetMonitorInfoW", SetLastError=true)] [return:MarshalAs(UnmanagedType.Bool)]
    internal static extern bool GetMonitorInfo(nint monitor, ref MonitorInfo info);
    [DllImport("user32.dll")] internal static extern nint MonitorFromPoint(Point point, uint flags);
    [DllImport("user32.dll")] internal static extern nint WindowFromPoint(Point point);
    [DllImport("user32.dll")] internal static extern nint GetAncestor(nint window, uint flags);
    [DllImport("user32.dll", SetLastError=true)] [return:MarshalAs(UnmanagedType.Bool)] internal static extern bool GetWindowRect(nint window, out Rect bounds);
    [DllImport("user32.dll")] internal static extern uint GetWindowThreadProcessId(nint window, out uint processId);
    [DllImport("user32.dll")] internal static extern uint GetDpiForWindow(nint window);
    [DllImport("shcore.dll")] internal static extern int GetDpiForMonitor(nint monitor, int type, out uint x, out uint y);
    [DllImport("user32.dll")] internal static extern short GetAsyncKeyState(int key);
    [DllImport("user32.dll")] internal static extern uint GetDoubleClickTime();
    [DllImport("user32.dll")] [return:MarshalAs(UnmanagedType.Bool)] internal static extern bool IsWindow(nint window);
    [DllImport("user32.dll")] [return:MarshalAs(UnmanagedType.Bool)] internal static extern bool IsWindowVisible(nint window);
    [DllImport("user32.dll")] [return:MarshalAs(UnmanagedType.Bool)] internal static extern bool IsIconic(nint window);
    [DllImport("user32.dll", EntryPoint="GetWindowTextW", CharSet=CharSet.Unicode)]
    internal static extern int GetWindowText(nint window, StringBuilder text, int count);
    [DllImport("dwmapi.dll")] internal static extern int DwmGetWindowAttribute(nint window, uint attribute, out Rect value, int size);
    [DllImport("dwmapi.dll")] internal static extern int DwmGetWindowAttribute(nint window, uint attribute, out uint value, int size);
    [DllImport("user32.dll", SetLastError=true)]
    internal static extern nint SetWinEventHook(uint eventMin, uint eventMax, nint module, WinEventProc callback,
        uint processId, uint threadId, uint flags);
    [DllImport("user32.dll", SetLastError=true)] [return:MarshalAs(UnmanagedType.Bool)]
    internal static extern bool UnhookWinEvent(nint hook);
    [DllImport("user32.dll", SetLastError=true)] [return:MarshalAs(UnmanagedType.Bool)]
    internal static extern bool SetWindowDisplayAffinity(nint window, uint affinity);
    [DllImport("user32.dll", SetLastError=true)] [return:MarshalAs(UnmanagedType.Bool)]
    internal static extern bool GetWindowDisplayAffinity(nint window, out uint affinity);

    internal static ScreenRect MonitorBounds(ScreenPoint point)
    {
        nint monitor = MonitorFromPoint(new Point(checked((int)point.X), checked((int)point.Y)), 0);
        var info = new MonitorInfo { Size=(uint)Marshal.SizeOf<MonitorInfo>() };
        if (monitor==0 || !GetMonitorInfo(monitor, ref info)) throw new InvalidOperationException("invalid_geometry");
        return info.Monitor.ToScreenRect();
    }
    internal static nint RootAt(Point point)
    { nint hit=WindowFromPoint(point); return hit==0 ? 0 : GetAncestor(hit, 2); }
}
