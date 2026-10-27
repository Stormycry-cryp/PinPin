// Derived from PowerToys MouseInfoProvider.cs, 115665ec3240a0c94dea3f0bfaaa6c52dcf4d019.
// Copyright (c) Microsoft Corporation. All rights reserved.
// MIT license: ../../ThirdPartyNotices/PowerToys-MIT.txt.
using System;
using System.ComponentModel;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

namespace PinPin.ColorSampling
{
    public struct PixelSample
    {
        public byte Red, Green, Blue;
        // GDI has no ICC conversion here. Do not serialize this as sRGB.
        public string ColorSpace;
    }

    public static class PowerToysPixelSampler
    {
        [StructLayout(LayoutKind.Sequential)]
        private struct PhysicalPoint { public int X, Y; }

        [DllImport("user32.dll", ExactSpelling = true)]
        private static extern IntPtr MonitorFromPoint(PhysicalPoint point, uint flags);

        // Host must be PerMonitorV2 aware; x/y are signed GLOBAL PHYSICAL pixel coordinates.
        // Validate the point against an actual monitor before calling; do not rescale here.
        // Success describes a GDI SDR desktop sample. WCG/HDR are outside this contract.
        public static bool TrySampleAt(int x, int y, out PixelSample? sample, out string error)
        {
            sample = null;
            error = null;
            // MONITOR_DEFAULTTONULL=0 rejects monitor gaps/outside coordinates without clamping.
            if (MonitorFromPoint(new PhysicalPoint { X = x, Y = y }, 0) == IntPtr.Zero)
            {
                error = "invalid_geometry";
                return false;
            }
            try
            {
                // Adapted from PowerToys: same 1x1 Bitmap + Graphics + CopyFromScreen + GetPixel.
                // Per-call ownership suits one-shot sampling and releases both GDI+ resources.
                using (var bitmap = new Bitmap(1, 1, PixelFormat.Format32bppArgb))
                using (var graphics = Graphics.FromImage(bitmap))
                {
                    graphics.CopyFromScreen(x, y, 0, 0, bitmap.Size, CopyPixelOperation.SourceCopy);
                    var color = bitmap.GetPixel(0, 0);
                    sample = new PixelSample {
                        Red = color.R, Green = color.G, Blue = color.B,
                        ColorSpace = "GDI_SDR_UNMANAGED"
                    };
                    return true;
                }
            }
            catch (Win32Exception) { error = "capture_unavailable"; return false; }
            catch (ExternalException) { error = "capture_unavailable"; return false; }
            // Unexpected exceptions propagate; there is no previous-frame or neighbouring-pixel state.
        }
    }
}
