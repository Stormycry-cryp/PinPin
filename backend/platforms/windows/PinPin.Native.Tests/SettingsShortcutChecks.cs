using PinPin.Core;
using PinPin.Native;

internal static class SettingsShortcutChecks
{
    internal static void Run(Action<bool,string> check)
    {
        var right=new SettingsPointerGestureState();
        check(right.Down(false)==(false,null),"ordinary or ineligible right-down passes");
        check(right.Up()==(false,null),"ordinary right-up passes as a complete pair");
        check(right.Down(true)==(true,GesturePhase.OpenSettings),"eligible right-down opens settings and owns right button");
        check(right.Down(true)==(true,null),"repeated right-down cannot open settings twice");
        check(right.Down(false)==(true,null),"modifier loss during owned right hold cannot release ownership on a repeat");
        check(right.OwnsButton,"right ownership survives Alt release independently of wheel state");
        check(right.Up()==(true,null),"right-up after Alt release is swallowed without another command");
        check(right.Up()==(false,null),"right ownership ends at the matching up");
        check(right.Down(false)==(false,null),"ordinary right-down does not retroactively become an Alt chord");
        check(right.Up()==(false,null),"pressing Alt after ordinary down leaves its up unowned");
        check(right.Down(true)==(true,GesturePhase.OpenSettings),"later complete chord can open settings again");
        check(right.Up()==(true,null),"later chord has its own swallowed up");

        var left=new PointerGestureState();
        var clear=new ClearGesture(500);var center=new ScreenPoint(500,500);
        check(left.Down(true)==(true,GesturePhase.Began),"left wheel can be active before settings chord");
        clear.Down(center,1000,true,1);
        check(right.Down(true)==(true,GesturePhase.OpenSettings),"right settings interrupts an owned left hold");
        left.Cancel();clear.Reset();
        check(left.Down(left.OwnsButton || false)==(true,null),"duplicate owned left-down after right interruption keeps its paired up without a new session");
        check(left.Move()==(false,null),"interrupted physical pointer movement passes without wheel updates");
        check(left.OwnsButton && !left.IsActive,"settings cancellation keeps left-up ownership while moves pass");
        check(left.Up()==(true,null),"interrupted owned left-up cannot execute a wheel action");
        check(!clear.Up(center,1010),"interrupted left-up cannot become a clear tap");
        check(right.Up()==(true,null),"right ownership is independent of the interrupted left-up");

        clear.Down(center,2000,true,1);check(!clear.Up(center,2010),"first neutral tap exists before settings interruption");
        right.Down(true);left.Cancel();clear.Reset();right.Up();
        clear.Down(center,2100,false,1);
        check(!clear.Up(center,2110),"settings interruption discards the pending double-left clear pair");
        check(left.Down(true)==(true,GesturePhase.Began),"next left gesture starts a fresh wheel after settings");
        left.Cancel();left.Up();

        right.Down(true);
        check(left.Down(!right.OwnsButton)==(false,null),"left down during owned settings-right hold cannot start wheel capture");
        check(left.Up()==(false,null),"that ordinary left pair remains complete");
        check(right.Up()==(true,null),"ordinary left pair does not release right ownership");
        check(left.Down(true)==(true,GesturePhase.Began),"normal Alt-left resumes after right-up");
        left.Cancel();left.Up();
        var trigger=new WheelTriggerState();int observed=0;
        check(!trigger.IsEnabled,"wheel trigger remains unarmed until loaded preferences are applied");
        check(right.Down(true)==(true,GesturePhase.OpenSettings),"settings remains available before wheel preferences finish loading");right.Up();
        trigger.Set(true);
        check(trigger.IsEnabled && !trigger.NeedsCancellation(ref observed),"loaded enabled preferences arm the trigger");
        left.Down(true);clear.Down(center,3000,true,1);
        trigger.Set(false);
        check(!trigger.IsEnabled && trigger.NeedsCancellation(ref observed),"disabling publishes a hook-thread cancellation");
        check(!trigger.NeedsCancellation(ref observed),"unchanged disabled preference does not repeatedly cancel on every native event");
        left.Cancel();clear.Reset();
        check(left.Down(left.OwnsButton || trigger.IsEnabled)==(true,null),"duplicate owned left-down while disabled does not lose button ownership");
        check(left.Up()==(true,null),"disabled held left still swallows its physical up without execution");
        check(!clear.Up(center,3010),"disabled held left cannot complete a neutral clear tap");
        check(right.Down(true)==(true,GesturePhase.OpenSettings),"settings right chord remains available while wheel trigger is disabled");
        right.Up();
        trigger.Set(true);
        check(trigger.IsEnabled && !trigger.NeedsCancellation(ref observed),"reenabling allows fresh gestures after cancellation was consumed");
        trigger.Set(false);trigger.Set(true);
        check(trigger.IsEnabled && trigger.NeedsCancellation(ref observed),"rapid disable then enable still cancels the old wheel");
        check(!trigger.NeedsCancellation(ref observed),"rapid toggle cancellation is consumed once after reenable");
        check(left.Down(trigger.IsEnabled)==(true,GesturePhase.Began),"fresh Alt-left resumes after enable");

    }
}
