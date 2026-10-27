using PinPin.Core;
using PinPin.ColorSampling;

namespace PinPin.Native;

public sealed class WindowsPixelSampler : IPixelSampler
{
    public Task<PixelColor> SampleAsync(TargetAnchor anchor, CancellationToken cancellationToken) => Task.Run(() =>
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (!CaptureGeometry.ValidPoint(anchor.Point)) throw new InvalidOperationException("invalid_geometry");
        // Anchor is frozen at mouse-down; release coordinates never enter the sampler.
        if (!PowerToysPixelSampler.TrySampleAt(checked((int)anchor.Point.X), checked((int)anchor.Point.Y), out var value, out var error)
            || value is not { } sample) throw new InvalidOperationException(error ?? "capture_unavailable");
        cancellationToken.ThrowIfCancellationRequested();
        return new PixelColor(sample.Red, sample.Green, sample.Blue, sample.ColorSpace);
    }, cancellationToken);
}
