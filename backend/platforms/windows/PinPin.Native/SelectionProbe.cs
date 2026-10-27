using System.Diagnostics;
using System.Windows.Automation;
using PinPin.Core;

namespace PinPin.Native;

internal sealed record ExplicitSelection(string Text)
{
    internal static readonly ExplicitSelection Empty=new("");
}

/// <summary>
/// One reusable MTA thread, with one admitted request and no waiting queue. A stalled provider may
/// occupy that one thread; callers time out and subsequent requests immediately use visual evidence.
/// </summary>
internal sealed class SelectionProbe : IDisposable
{
    private sealed record Request(TargetAnchor Anchor, CancellationToken Token,
        TaskCompletionSource<ExplicitSelection> Completion, long Started);
    private readonly object gate=new();
    private readonly AutoResetEvent wake=new(false);
    private readonly Thread worker;
    private Request? request;
    private bool busy, stopping;
    internal Exception? LastFault { get; private set; }

    internal SelectionProbe()
    {
        worker=new Thread(Run) { IsBackground=true, Name="PinPin.selection.MTA" };
        worker.SetApartmentState(ApartmentState.MTA);
        worker.Start();
    }

    internal async Task<ExplicitSelection> TryProbeAsync(TargetAnchor anchor, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        Request current;
        lock (gate)
        {
            if (busy || stopping || anchor.ProcessId<=0 || anchor.ProcessId==Environment.ProcessId)
                return ExplicitSelection.Empty;
            busy=true;
            current=new(anchor,cancellationToken,new(TaskCreationOptions.RunContinuationsAsynchronously),Stopwatch.GetTimestamp());
            request=current;
            wake.Set();
        }
        try { return await current.Completion.Task.WaitAsync(TimeSpan.FromMilliseconds(200),cancellationToken).ConfigureAwait(false); }
        catch (TimeoutException) { current.Completion.TrySetResult(ExplicitSelection.Empty); return ExplicitSelection.Empty; }
        catch (OperationCanceledException) { current.Completion.TrySetCanceled(cancellationToken); throw; }
    }

    public void Dispose()
    {
        lock (gate)
        {
            if (stopping) return;
            stopping=true;
            request?.Completion.TrySetResult(ExplicitSelection.Empty);
            wake.Set();
        }
        // UIA provider RPCs cannot safely be forcibly aborted. Never block the UI on a stuck provider;
        // the sole background worker releases its wait handle when the provider eventually returns.
    }

    private bool CanContinue(Request current) => !current.Token.IsCancellationRequested && !current.Completion.Task.IsCompleted
        && Stopwatch.GetElapsedTime(current.Started)<TimeSpan.FromMilliseconds(190);

    private void Run()
    {
        try
        {
            while (true)
            {
                wake.WaitOne();
                Request? current;
                lock (gate) { if (stopping) return; current=request; }
                if (current==null) continue;
                ExplicitSelection result=ExplicitSelection.Empty;
                try { if (CanContinue(current)) result=Read(current); }
                catch (Exception error) { LastFault=error; result=ExplicitSelection.Empty; }
                finally
                {
                    current.Completion.TrySetResult(result);
                    lock (gate) { request=null; busy=false; }
                }
            }
        }
        finally { wake.Dispose(); }
    }

    private ExplicitSelection Read(Request current)
    {
        var source=current.Anchor;
        if (!CaptureGeometry.ValidPoint(source.Point)) return ExplicitSelection.Empty;
        var point=new NativeMethods.Point((int)source.Point.X,(int)source.Point.Y);
        // Never read another foreground app's selection after the original source has changed.
        if (source.Window!=0 && NativeMethods.RootAt(point)!=source.Window) return ExplicitSelection.Empty;
        var hit=AutomationElement.FromPoint(new System.Windows.Point(source.Point.X,source.Point.Y));
        if (!CanContinue(current) || hit==null) return ExplicitSelection.Empty;
        if (hit.Current.ProcessId!=source.ProcessId || !CanContinue(current)) return ExplicitSelection.Empty;
        if (hit.Current.IsPassword || !CanContinue(current)) return ExplicitSelection.Empty;
        if (!hit.TryGetCurrentPattern(TextPattern.Pattern,out var value) || value is not TextPattern text || !CanContinue(current))
            return ExplicitSelection.Empty;
        var ranges=text.GetSelection();
        if (!CanContinue(current)) return ExplicitSelection.Empty;
        foreach (var range in ranges)
        {
            var rectangles=range.GetBoundingRectangles();
            if (!CanContinue(current)) return ExplicitSelection.Empty;
            bool covers=rectangles.Any(rect => !rect.IsEmpty && double.IsFinite(rect.X) && double.IsFinite(rect.Y)
                && rect.Width>0 && rect.Height>0 && source.Point.X>=rect.Left && source.Point.X<rect.Right
                && source.Point.Y>=rect.Top && source.Point.Y<rect.Bottom);
            if (!covers) continue;
            string selected=range.GetText(-1);
            if (!CanContinue(current) || string.IsNullOrWhiteSpace(selected)) return ExplicitSelection.Empty;
            // No OCR, clipboard, document value, focused element or unrelated selection is read.
            return new(selected);
        }
        return ExplicitSelection.Empty;
    }
}
