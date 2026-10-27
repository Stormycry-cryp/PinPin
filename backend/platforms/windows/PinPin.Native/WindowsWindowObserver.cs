using System.ComponentModel;
using System.Runtime.InteropServices;
using PinPin.Core;

namespace PinPin.Native;

/// <summary>Event-driven state for explicitly watched source windows; no foreground-only hiding.</summary>
public sealed class WindowsWindowObserver : IDisposable
{
    private sealed class Watched
    {
        internal int Count=1;
        internal SourceWindowState? Last;
        internal bool Destroyed;
    }
    private const uint RefreshMessage=0x8001;
    private readonly object gate=new();
    private readonly Dictionary<nint,Watched> watched=new();
    private readonly HashSet<nint> pending=new();
    private readonly ManualResetEventSlim ready=new(false);
    private readonly Thread worker;
    private readonly NativeMethods.WinEventProc callback;
    private readonly List<nint> hooks=new();
    private uint threadId;
    private volatile bool disposed;
    private Exception? startupFailure, lastFault;
    private bool refreshPosted;
    private bool selfDisposing;
    public event Action<SourceWindowState>? Changed;
    public Exception? LastFault => Volatile.Read(ref lastFault);

    public WindowsWindowObserver()
    {
        callback=OnEvent;
        worker=new Thread(Run) { IsBackground=true,Name="PinPin.source-windows" };
        worker.Start(); ready.Wait();
        if (startupFailure!=null)
        { Dispose(); throw new InvalidOperationException("Unable to watch source windows.",startupFailure); }
    }

    public void Watch(nint window)
    {
        if (window==0) return;
        lock (gate)
        {
            ObjectDisposedException.ThrowIf(disposed,this);
            if (watched.TryGetValue(window,out var existing)) { checked { existing.Count++; } return; }
            watched.Add(window,new Watched());
            ScheduleLocked(window);
        }
    }

    public void Unwatch(nint window)
    {
        lock (gate)
        {
            if (!watched.TryGetValue(window,out var entry)) return;
            if (--entry.Count==0) { watched.Remove(window); pending.Remove(window); }
        }
    }

    public void Dispose()
    {
        lock (gate)
        {
            if (disposed) return;
            disposed=true; watched.Clear(); pending.Clear();
            selfDisposing=Thread.CurrentThread==worker;
            if (threadId!=0) NativeMethods.PostThreadMessage(threadId,0x12,0,0);
        }
        if (Thread.CurrentThread!=worker) worker.Join();
        // Self-disposal can only occur while publishing a state after startup.
        if (Thread.CurrentThread!=worker) ready.Dispose();
    }

    private void Run()
    {
        try
        {
            threadId=NativeMethods.GetCurrentThreadId();
            // Force creation of this thread's message queue before exposing Watch/Dispose.
            NativeMethods.PeekMessage(out _,0,0,0,0);
            AddHook(0x0003,0x0003); // EVENT_SYSTEM_FOREGROUND
            AddHook(0x0016,0x0017); // MINIMIZESTART / MINIMIZEEND
            AddHook(0x8001,0x8003); // OBJECT_DESTROY / SHOW / HIDE
            AddHook(0x800B,0x800B); // OBJECT_LOCATIONCHANGE
            AddHook(0x8017,0x8018); // OBJECT_CLOAKED / UNCLOAKED
            ready.Set();
            while (!disposed)
            {
                int result=NativeMethods.GetMessage(out var message,0,0,0);
                if (result==0) break;
                if (result<0) throw new Win32Exception(Marshal.GetLastWin32Error());
                if (message.Window==0 && message.Id==RefreshMessage) { Drain(); continue; }
                NativeMethods.TranslateMessage(in message);
                NativeMethods.DispatchMessage(in message);
            }
        }
        catch (Exception error)
        { if (!ready.IsSet) startupFailure=error; Volatile.Write(ref lastFault,error); }
        finally
        {
            foreach (nint hook in hooks) NativeMethods.UnhookWinEvent(hook);
            hooks.Clear(); ready.Set();
            if (selfDisposing) ready.Dispose();
        }
    }

    private void AddHook(uint first,uint last)
    {
        // WINEVENT_OUTOFCONTEXT: callbacks arrive on this dedicated message-pump thread.
        nint hook=NativeMethods.SetWinEventHook(first,last,0,callback,0,0,0);
        if (hook==0) throw new Win32Exception(Marshal.GetLastWin32Error());
        hooks.Add(hook);
    }

    private void OnEvent(nint hook,uint eventId,nint window,int objectId,int childId,uint eventThread,uint eventTime)
    {
        try
        {
            lock (gate)
            {
                if (disposed) return;
                if (eventId==0x0003)
                {
                    // Only explicitly watched HWNDs are refreshed; never enumerate applications.
                    foreach (nint source in watched.Keys) ScheduleLocked(source);
                }
                else if (window!=0 && (eventId<0x8000 || (objectId==0 && childId==0)) && watched.TryGetValue(window,out var entry))
                {
                    if (eventId==0x8001) entry.Destroyed=true;
                    ScheduleLocked(window);
                }
            }
        }
        catch (Exception error) { Volatile.Write(ref lastFault,error); }
    }

    private void ScheduleLocked(nint window)
    {
        pending.Add(window);
        if (refreshPosted) return;
        refreshPosted=true;
        if (!NativeMethods.PostThreadMessage(threadId,RefreshMessage,0,0))
        { refreshPosted=false; Volatile.Write(ref lastFault,new Win32Exception(Marshal.GetLastWin32Error())); }
    }

    private void Drain()
    {
        nint[] sources;
        lock (gate) { refreshPosted=false; sources=pending.ToArray(); pending.Clear(); }
        foreach (nint window in sources)
        {
            SourceWindowState? old;
            bool destroyed;
            lock (gate)
            { if (disposed || !watched.TryGetValue(window,out var entry)) continue; old=entry.Last; destroyed=entry.Destroyed; }
            SourceWindowState state=destroyed ? new(window,false,old?.Bounds ?? default) : ReadState(window,old?.Bounds ?? default);
            bool changed;
            lock (gate)
            {
                if (disposed || !watched.TryGetValue(window,out var entry)) continue;
                changed=entry.Last!=state; entry.Last=state;
            }
            if (changed && !disposed)
            {
                try { Changed?.Invoke(state); }
                catch (Exception error) { Volatile.Write(ref lastFault,error); }
            }
        }
    }

    private static SourceWindowState ReadState(nint window,ScreenRect previousBounds)
    {
        if (!NativeMethods.IsWindow(window)) return new(window,false,previousBounds);
        ScreenRect bounds=previousBounds;
        // TargetAnchor uses GetWindowRect. Mixing DWM's visible-frame inset here would move
        // every annotation on the first observation even when its source window did not move.
        if (NativeMethods.GetWindowRect(window,out var rectangle)) bounds=rectangle.ToScreenRect();
        bool visible=NativeMethods.IsWindowVisible(window) && !NativeMethods.IsIconic(window);
        if (NativeMethods.DwmGetWindowAttribute(window,14,out uint cloaked,sizeof(uint))==0) visible&=cloaked==0;
        else visible=false;
        return new(window,visible && CaptureGeometry.ValidRect(bounds),bounds);
    }
}
