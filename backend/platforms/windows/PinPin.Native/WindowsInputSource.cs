using System.ComponentModel;
using System.Runtime.InteropServices;
using PinPin.Core;

namespace PinPin.Native;

/// <summary>
/// A dedicated hook/message-pump thread only snapshots values and posts events. Gesture callbacks
/// run on one delivery thread; UI consumers must use asynchronous Dispatcher delivery.
/// </summary>
public sealed class WindowsInputSource : IInputSource
{
    private readonly object lifecycle=new(), eventsGate=new();
    private readonly Queue<GestureEvent> transitions=new();
    private readonly AutoResetEvent pending=new(false);
    private readonly ManualResetEventSlim ready=new(false);
    private readonly PointerGestureState pointer=new();
    private readonly SettingsPointerGestureState settingsPointer=new();
    private readonly WheelTriggerState wheelTrigger=new();
    private const uint WheelTriggerChanged=0x8001;
    private int appliedTriggerRevision;
    private readonly AltKeyState alt=new();
    private readonly ClearGesture clear=new(500);
    private readonly NativeMethods.HookProc mouseProc, keyboardProc;
    private readonly NativeMethods.WindowProc windowProc;
    private Thread? hookThread, deliveryThread;
    private uint hookThreadId;
    private nint mouseHook, keyboardHook, notificationWindow;
    private volatile bool stopping, disposed;
    private IReadOnlyList<ScreenRect> screens=Array.Empty<ScreenRect>();
    private GestureEvent? latestMove;
    private TargetAnchor? anchor;
    private Exception? startupFailure, lastFault;

    public event Action<GestureEvent>? Gesture;
    public IReadOnlyList<ScreenRect> Screens => Volatile.Read(ref screens);
    public Exception? LastFault => Volatile.Read(ref lastFault);

    public WindowsInputSource()
    { mouseProc=MouseHook; keyboardProc=KeyboardHook; windowProc=WindowMessage; }

    public void SetWheelTriggerEnabled(bool enabled)
    {
        if (disposed) return;
        wheelTrigger.Set(enabled);
        uint thread=Volatile.Read(ref hookThreadId);
        if (!enabled && thread!=0 && !NativeMethods.PostThreadMessage(thread,WheelTriggerChanged,0,0))
            Volatile.Write(ref lastFault,new Win32Exception(Marshal.GetLastWin32Error()));
    }

    public void Start()
    {
        Exception? failure;
        lock (lifecycle)
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            if (hookThread!=null) return;
            deliveryThread=new Thread(Deliver) { IsBackground=true, Name="PinPin.input.delivery" };
            hookThread=new Thread(Run) { IsBackground=true, Name="PinPin.input.hooks" };
            deliveryThread.Start(); hookThread.Start();
            ready.Wait(); // Only local hook/window creation; no target process calls or UIA.
            failure=startupFailure;
        }
        if (failure!=null)
        { Dispose(); throw new InvalidOperationException("Unable to start Windows input hooks.", failure); }
    }

    public void Dispose()
    {
        Thread? hooks, delivery;
        lock (lifecycle)
        {
            if (disposed) return;
            disposed=true; stopping=true;
            hooks=hookThread; delivery=deliveryThread;
            if (hookThreadId!=0) NativeMethods.PostThreadMessage(hookThreadId, 0x12, 0, 0);
            pending.Set();
        }
        // Never hold lifecycle while joining a consumer that may itself request shutdown.
        if (hooks!=null && Thread.CurrentThread!=hooks) hooks.Join();
        if (delivery!=null && Thread.CurrentThread!=delivery) delivery.Join();
        lock (eventsGate) { transitions.Clear(); latestMove=null; }
        // Self-disposal occurs inside the callback, so that loop exits without another wait.
        pending.Dispose();
        ready.Dispose();
    }

    private void Run()
    {
        string className="PinPin.Input."+Guid.NewGuid().ToString("N");
        nint module=NativeMethods.GetModuleHandle(null);
        ushort registered=0;
        try
        {
            hookThreadId=NativeMethods.GetCurrentThreadId();
            clear.IntervalMilliseconds=NativeMethods.GetDoubleClickTime();
            var windowClass=new NativeMethods.WindowClass { Procedure=windowProc, Instance=module, ClassName=className };
            registered=NativeMethods.RegisterClass(in windowClass);
            if (registered==0) throw new Win32Exception(Marshal.GetLastWin32Error());
            // A hidden top-level window receives WM_DISPLAYCHANGE. Message-only windows do not.
            notificationWindow=NativeMethods.CreateWindowEx(0, className, "", 0, 0, 0, 0, 0, 0, 0, module, 0);
            if (notificationWindow==0) throw new Win32Exception(Marshal.GetLastWin32Error());
            RefreshScreens();
            mouseHook=NativeMethods.SetWindowsHookEx(14, mouseProc, module, 0);
            if (mouseHook==0) throw new Win32Exception(Marshal.GetLastWin32Error());
            keyboardHook=NativeMethods.SetWindowsHookEx(13, keyboardProc, module, 0);
            if (keyboardHook==0) throw new Win32Exception(Marshal.GetLastWin32Error());
            ready.Set();
            while (!stopping)
            {
                int status=NativeMethods.GetMessage(out var message, 0, 0, 0);
                if (status==0) break;
                if (status<0) throw new Win32Exception(Marshal.GetLastWin32Error());
                if (message.Id==WheelTriggerChanged) { ApplyWheelTriggerChange(); continue; }
                NativeMethods.TranslateMessage(in message);
                NativeMethods.DispatchMessage(in message);
            }
        }
        catch (Exception error)
        {
            if (!ready.IsSet) startupFailure=error;
            Volatile.Write(ref lastFault, error);
            if (pointer.Cancel() is { } phase) Post(new GestureEvent(phase,anchor,anchor?.Point ?? default));
        }
        finally
        {
            clear.Reset();
            if (mouseHook!=0) { NativeMethods.UnhookWindowsHookEx(mouseHook); mouseHook=0; }
            if (keyboardHook!=0) { NativeMethods.UnhookWindowsHookEx(keyboardHook); keyboardHook=0; }
            if (notificationWindow!=0) { NativeMethods.DestroyWindow(notificationWindow); notificationWindow=0; }
            if (registered!=0) NativeMethods.UnregisterClass(className, module);
            ready.Set();
        }
    }

    private nint WindowMessage(nint window, uint message, nuint wParam, nint lParam)
    {
        if (message is 0x7E or 0x1A) // WM_DISPLAYCHANGE / WM_SETTINGCHANGE: event-driven geometry.
        {
            try { RefreshScreens(); clear.IntervalMilliseconds=NativeMethods.GetDoubleClickTime(); }
            catch (Exception error) { Volatile.Write(ref lastFault, error); }
        }
        return NativeMethods.DefWindowProc(window, message, wParam, lParam);
    }

    private void RefreshScreens()
    {
        var values=new List<ScreenRect>();
        NativeMethods.MonitorEnum callback=(nint monitor, nint dc, ref NativeMethods.Rect rect, nint data) =>
        { values.Add(rect.ToScreenRect()); return true; };
        if (!NativeMethods.EnumDisplayMonitors(0, 0, callback, 0)) throw new Win32Exception(Marshal.GetLastWin32Error());
        Volatile.Write(ref screens, Array.AsReadOnly(values.ToArray()));
    }

    private nint MouseHook(int code, nint wParam, nint lParam)
    {
        if (code<0) return NativeMethods.CallNextHookEx(mouseHook, code, wParam, lParam);
        uint message=unchecked((uint)wParam.ToInt64());
        if (settingsPointer.OwnsButton && (message is 0x204 or 0x205))
        {
            if (message==0x205) settingsPointer.Up();
            return 1; // An owned right pair stays owned even while modifiers or shutdown change eligibility.
        }
        if (stopping) return NativeMethods.CallNextHookEx(mouseHook, code, wParam, lParam);
        try
        {
            ApplyWheelTriggerChange();
            var data=Marshal.PtrToStructure<NativeMethods.MouseData>(lParam);
            // Remote control and accessibility input share ordinary gesture semantics.
            var point=new ScreenPoint(data.Point.X, data.Point.Y);
            bool wasOwned=pointer.OwnsButton,completedClear=false;
            (bool Swallow, GesturePhase? Phase) decision;
            switch (message)
            {
                case 0x201: // WM_LBUTTONDOWN
                    bool eligible=wheelTrigger.IsEnabled && AltHeld() && !OtherModifierHeld() && !settingsPointer.OwnsButton;
                    // Resolve before taking button ownership: a failed snapshot must pass both edges.
                    TargetAnchor? candidate=eligible && !pointer.OwnsButton && !pointer.IsActive ? SnapshotAnchor(data.Point) : null;
                    decision=pointer.Down(wasOwned || eligible);
                    if (decision.Phase==GesturePhase.Began) anchor=candidate;
                    if (decision.Swallow && !wasOwned)
                        clear.Down(point,Environment.TickCount64,decision.Phase==GesturePhase.Began,anchor?.Scale ?? 1);
                    else if (!decision.Swallow) clear.Reset();
                    break;
                case 0x200:
                    decision=pointer.Move();
                    if (decision.Phase==GesturePhase.Moved) clear.Dragged(point);
                    break;
                case 0x202:
                    decision=pointer.Up();
                    if (decision.Swallow && wasOwned && decision.Phase==GesturePhase.Released)
                        completedClear=clear.Up(point,Environment.TickCount64);
                    else clear.Reset();
                    break;
                case 0x204: // WM_RBUTTONDOWN
                    clear.Reset();
                    decision=settingsPointer.Down(AltHeld() && !OtherModifierHeld());
                    if (decision.Phase==GesturePhase.OpenSettings)
                    {
                        pointer.Cancel(); // Preserve an owned left-up, but never execute it.
                        anchor=null;
                    }
                    break;
                case 0x205: // WM_RBUTTONUP: keep the pair swallowed even when Alt was released first.
                    decision=settingsPointer.Up();
                    break;
                case 0x207: case 0x20B: case 0x20A: case 0x20E:
                    clear.Reset(); return NativeMethods.CallNextHookEx(mouseHook, code, wParam, lParam);
                default: return NativeMethods.CallNextHookEx(mouseHook, code, wParam, lParam);
            }
            if (decision.Phase is { } phase) Post(new GestureEvent(phase, anchor, point));
            if (completedClear) Post(new GestureEvent(GesturePhase.ClearAll,anchor,point));
            if (decision.Phase==GesturePhase.ModifierReleased || (message==0x202 && !pointer.IsActive)) anchor=null;
            return decision.Swallow ? 1 : NativeMethods.CallNextHookEx(mouseHook, code, wParam, lParam);
        }
        catch (Exception error)
        {
            Volatile.Write(ref lastFault, error);
            return NativeMethods.CallNextHookEx(mouseHook, code, wParam, lParam);
        }
    }

    private nint KeyboardHook(int code, nint wParam, nint lParam)
    {
        if (code<0 || stopping) return NativeMethods.CallNextHookEx(keyboardHook, code, wParam, lParam);
        try
        {
            ApplyWheelTriggerChange();
            var data=Marshal.PtrToStructure<NativeMethods.KeyboardData>(lParam);
            // No input is replayed by PinPin, so injected input cannot create a self-feedback loop.
            uint message=unchecked((uint)wParam.ToInt64());
            bool down=message is 0x100 or 0x104;
            bool up=message is 0x101 or 0x105;
            if (!down && !up) return NativeMethods.CallNextHookEx(keyboardHook, code, wParam, lParam);
            bool isAlt=data.Key is 0x12 or 0xA4 or 0xA5;
            if (isAlt)
            {
                bool right=data.Key==0xA5 || (data.Key==0x12 && (data.Flags&1)!=0);
                if (down) alt.Down(right);
                else
                {
                    alt.Up(right);
                    if (!alt.IsHeld && !KeyHeld(right ? 0xA4 : 0xA5)) CloseWheel();
                }
            }
            else if (down)
            {
                clear.Reset();
                if (data.Key is 0x1B or 0x11 or 0xA2 or 0xA3)
                    CloseWheel();
            }
            // Alt/AltGr/chords retain their ordinary OS behavior. Only owned pointer events are swallowed.
        }
        catch (Exception error) { Volatile.Write(ref lastFault, error); }
        return NativeMethods.CallNextHookEx(keyboardHook, code, wParam, lParam);
    }

    private void ApplyWheelTriggerChange()
    {
        if (wheelTrigger.NeedsCancellation(ref appliedTriggerRevision)) CloseWheel();
    }

    private void CloseWheel()
    {
        clear.Reset();
        if (pointer.Cancel() is not { } phase) return;
        Post(new GestureEvent(phase,anchor,anchor?.Point ?? default));
        anchor=null;
    }

    private static bool KeyHeld(int key) => (NativeMethods.GetAsyncKeyState(key)&0x8000)!=0;
    private static bool AltHeld() => KeyHeld(0xA4) || KeyHeld(0xA5);
    private static bool OtherModifierHeld() => KeyHeld(0x11) || KeyHeld(0x10) || KeyHeld(0x5B) || KeyHeld(0x5C);
    private static TargetAnchor SnapshotAnchor(NativeMethods.Point point)
    {
        var origin=new ScreenPoint(point.X, point.Y);
        nint window=NativeMethods.RootAt(point);
        uint pid=0, dpi=window!=0 ? NativeMethods.GetDpiForWindow(window) : 0;
        if (window!=0) NativeMethods.GetWindowThreadProcessId(window, out pid);
        var bounds=window!=0 && NativeMethods.GetWindowRect(window, out var rect) ? rect.ToScreenRect() : NativeMethods.MonitorBounds(origin);
        if (dpi==0)
        {
            nint monitor=NativeMethods.MonitorFromPoint(point, 0);
            if (monitor!=0 && NativeMethods.GetDpiForMonitor(monitor, 0, out uint x, out _)==0) dpi=x;
        }
        return new TargetAnchor(Guid.NewGuid(), origin, window, checked((int)pid), bounds, dpi>0 ? dpi/96d : 1);
    }

    private void Post(GestureEvent value)
    {
        lock (eventsGate)
        {
            if (stopping) return;
            if (value.Phase==GesturePhase.Moved) latestMove=value;
            else { latestMove=null; transitions.Enqueue(value); }
        }
        pending.Set();
    }

    private void Deliver()
    {
        while (!stopping)
        {
            pending.WaitOne();
            while (!stopping)
            {
                GestureEvent? value;
                lock (eventsGate)
                {
                    if (transitions.Count>0) value=transitions.Dequeue();
                    else { value=latestMove; latestMove=null; }
                }
                if (value==null) break;
                try { Gesture?.Invoke(value); }
                catch (Exception error) { Volatile.Write(ref lastFault, error); }
            }
        }
    }
}
