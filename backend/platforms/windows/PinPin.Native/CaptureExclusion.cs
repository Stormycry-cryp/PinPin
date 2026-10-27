using System.Runtime.InteropServices;

namespace PinPin.Native;

public readonly record struct CaptureExclusionResult(bool Success, int Win32Error);

public static class CaptureExclusion
{
    public static CaptureExclusionResult ExcludeWindow(nint hwnd)
    {
        if (hwnd==0) return new(false, 1400); // ERROR_INVALID_WINDOW_HANDLE
        const uint excludeFromCapture=0x11;
        if (!NativeMethods.SetWindowDisplayAffinity(hwnd, excludeFromCapture))
            return new(false, Marshal.GetLastWin32Error());
        if (!NativeMethods.GetWindowDisplayAffinity(hwnd, out uint affinity))
            return new(false, Marshal.GetLastWin32Error());
        return affinity==excludeFromCapture ? new(true, 0) : new(false, 50);
    }
}
