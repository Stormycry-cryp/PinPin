using PinPin.Core;

namespace PinPin.Native;

// Pure value rules: hook callbacks own these states; no UI or platform calls occur here.
internal sealed class PointerGestureState
{
    internal bool OwnsButton { get; private set; }
    internal bool IsActive { get; private set; }
    internal (bool Swallow, GesturePhase? Phase) Down(bool eligible)
    {
        if (!eligible)
        {
            // A fresh ordinary down proves that any formerly owned physical up was missed.
            bool wasActive=IsActive; OwnsButton=false; IsActive=false;
            return (false,wasActive ? GesturePhase.ModifierReleased : null);
        }
        if (OwnsButton) return (true, null);
        OwnsButton=true;
        if (IsActive) return (true,GesturePhase.Moved); // Same Alt hold keeps the original wheel/anchor.
        IsActive=true;
        return (true, GesturePhase.Began);
    }
    // 移动交给系统更新光标；按钮边沿继续由当前手势拥有。
    internal (bool Swallow, GesturePhase? Phase) Move() => (false, OwnsButton && IsActive ? GesturePhase.Moved : null);
    internal (bool Swallow, GesturePhase? Phase) Up()
    {
        if (!OwnsButton) return (false, null);
        var phase=IsActive ? GesturePhase.Released : (GesturePhase?)null;
        OwnsButton=false; // Execute on left-up; keep the wheel open until Alt-up.
        return (true, phase);
    }
    internal GesturePhase? Cancel()
    { bool active=IsActive; IsActive=false; return active ? GesturePhase.ModifierReleased : null; }
}

// Right-button ownership survives modifier release until the matching physical up.
internal sealed class SettingsPointerGestureState
{
    internal bool OwnsButton { get; private set; }
    internal (bool Swallow, GesturePhase? Phase) Down(bool eligible)
    {
        if (OwnsButton) return (true, null);
        if (!eligible) return (false, null);
        OwnsButton=true;
        return (true, GesturePhase.OpenSettings);
    }
    internal (bool Swallow, GesturePhase? Phase) Up()
    {
        bool owned=OwnsButton; OwnsButton=false;
        return (owned, null);
    }
}

internal sealed class WheelTriggerState
{
    // Publish activation and its cancellation revision together; initially unarmed.
    private int state;
    internal bool IsEnabled => (Volatile.Read(ref state)&1)!=0;
    internal void Set(bool value)
    {
        int before, after;
        do {
            before=Volatile.Read(ref state);
            after=value ? before|1 : unchecked((before&~1)+2);
        } while (Interlocked.CompareExchange(ref state,after,before)!=before);
    }
    internal bool NeedsCancellation(ref int observedRevision)
    {
        int current=Volatile.Read(ref state)&~1;
        if (current==observedRevision) return false;
        observedRevision=current;
        return true;
    }
}

internal sealed class AltKeyState
{
    private int held;
    internal bool IsHeld => held!=0;
    internal void Down(bool right) => held|=right ? 2 : 1;
    internal void Up(bool right) => held&=~(right ? 2 : 1);
}
