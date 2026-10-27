using PinPin.Core;
using PinPin.Native;

int checks=0;
void Check(bool condition,string name)
{ if (!condition) throw new InvalidOperationException(name); checks++; }
void Equal(double actual,double expected,string name)
{ Check(Math.Abs(actual-expected)<1e-9,name); }

var ordinary=new PointerGestureState();
Check(ordinary.Down(false)==(false,null),"ordinary left-down passes");
Check(ordinary.Up()==(false,null),"ordinary left-up passes");
Check(ordinary.Move()==(false,null),"ordinary move passes");
var gesture=new PointerGestureState();
Check(gesture.Down(true)==(true,GesturePhase.Began),"Alt left-down begins and owns button");
Check(gesture.Down(true)==(true,null),"duplicate down cannot begin again");
Check(gesture.Move()==(false,GesturePhase.Moved),"owned move routes while physical pointer movement passes");
Check(gesture.OwnsButton && gesture.IsActive,"passing moves retain left-button ownership");
Check(gesture.Cancel()==GesturePhase.ModifierReleased,"Alt release cancels");
Check(gesture.Move()==(false,null),"cancelled physical pointer movement passes without wheel updates");
Check(gesture.OwnsButton && !gesture.IsActive,"cancelled moves retain ownership until physical up");
Check(gesture.Up()==(true,null),"cancelled up is paired and swallowed");
Check(gesture.Up()==(false,null),"later ordinary up passes");
Check(gesture.Down(true)==(true,GesturePhase.Began),"next gesture begins independently");
Check(gesture.Up()==(true,GesturePhase.Released),"active release executes");
Check(gesture.IsActive && !gesture.OwnsButton,"left-up keeps wheel open while releasing button ownership");
Check(gesture.Move()==(false,null),"unheld pointer cannot move the executed wheel");
Check(gesture.Cancel()==GesturePhase.ModifierReleased,"Alt-up closes wheel after left-up execution");
Check(gesture.Cancel()==null,"Alt-up closes exactly once");
Check(gesture.Down(true)==(true,GesturePhase.Began),"gesture before a missed physical up");
Check(gesture.Down(false)==(false,GesturePhase.ModifierReleased),"fresh ordinary click resets stale ownership");
Check(gesture.Up()==(false,null),"ordinary pair remains unowned after reset");
Check(gesture.Down(true)==(true,GesturePhase.Began),"new Alt hold begins");
Check(gesture.Up()==(true,GesturePhase.Released),"first release in hold");
Check(gesture.Down(true)==(true,GesturePhase.Moved),"same Alt hold cannot replace original anchor with a new Began");
Check(gesture.Move()==(false,GesturePhase.Moved),"repeated press in same wheel passes pointer movement and still routes updates");
Check(gesture.OwnsButton && gesture.IsActive,"repeated press preserves the active wheel and owns its matching up");
Check(gesture.Up()==(true,GesturePhase.Released),"second release is routed for Core consumed guard");
Check(gesture.Cancel()==GesturePhase.ModifierReleased,"same Alt hold ends with one close");

var modifier=new AltKeyState();
modifier.Down(false); modifier.Down(false);
Check(modifier.IsHeld,"Alt auto-repeat only preserves held state");
modifier.Down(true); modifier.Up(false);
Check(modifier.IsHeld,"one of two Alt keys remains held");
modifier.Up(true);
Check(!modifier.IsHeld,"Alt-up only clears modifier state; it cannot clear markers");

var clear=new ClearGesture(500);
var center=new ScreenPoint(-500,-200);
clear.Down(center,1000,true,1);
Check(!clear.Up(center,1010),"first neutral left release never clears");
clear.Down(center,1100,false,1);
Check(clear.Up(center,1110),"same Alt session clears only on second neutral left release");
Check(!clear.Up(center,1111),"unmatched release cannot clear again");
clear.Reset();
clear.Down(center,2000,true,1); Check(!clear.Up(center,2010),"first tap before drag");
clear.Down(center,2100,false,1); clear.Dragged(new(center.X+7,center.Y)); clear.Dragged(center);
Check(!clear.Up(center,2110),"dragging beyond slop then returning to center cannot clear");
var dragPointer=new PointerGestureState();var dragClear=new ClearGesture(500);
Check(dragPointer.Down(true)==(true,GesturePhase.Began),"drag-clear first down owns its button");
dragClear.Down(center,10000,true,1);
Check(dragPointer.Up()==(true,GesturePhase.Released) && !dragClear.Up(center,10010),"first neutral release records one tap without clearing");
Check(dragPointer.Down(true)==(true,GesturePhase.Moved),"drag-clear second down preserves the same wheel");
dragClear.Down(center,10100,false,1);
foreach(var dragPoint in new[]{new ScreenPoint(center.X+7,center.Y),center})
{
    var dragDecision=dragPointer.Move();
    Check(!dragDecision.Swallow && dragDecision.Phase==GesturePhase.Moved,"physical drag passes while active movement remains available to clear tracking");
    if(dragDecision.Phase==GesturePhase.Moved) dragClear.Dragged(dragPoint);
}
Check(dragPointer.OwnsButton,"dragging out and back cannot release button ownership");
Check(dragPointer.Up()==(true,GesturePhase.Released),"drag-clear matching physical up remains swallowed and routed");
Check(!dragClear.Up(center,10110),"passed movement beyond slop and back cannot become double-click clear");
Check(dragPointer.Move()==(false,null),"released movement passes without updating the consumed wheel");
Check(dragPointer.Cancel()==GesturePhase.ModifierReleased,"drag-clear wheel still closes exactly on Alt release");
clear.Reset();
clear.Down(center,3000,true,1); Check(!clear.Up(center,3010),"first tap before functional release");
clear.Down(center,3100,false,1);
Check(!clear.Up(new(center.X+WheelGeometry.CancelRadius,center.Y),3110),"neutral radius boundary belongs to function area and cannot clear");
clear.Reset();
clear.Down(center,4000,true,1); Check(!clear.Up(center,4010),"first tap before timeout");
clear.Down(center,4511,false,1); Check(!clear.Up(center,4520),"second press outside system interval cannot clear");
clear.Reset();
clear.Down(center,5000,true,1); Check(!clear.Up(center,5010),"first tap before held second click");
clear.Down(center,5100,false,1); Check(!clear.Up(center,5601),"second hold outside system interval cannot clear");
clear.Reset();
clear.Down(center,6000,true,1); Check(!clear.Up(center,6010),"first tap before session interruption");
clear.Reset(); clear.Down(center,6100,false,1);
Check(!clear.Up(center,6110),"Alt release, ordinary click or another interrupt resets the pair");
clear.Down(center,6200,true,1); Check(!clear.Up(center,6210),"new Alt session cannot reuse previous neutral tap");
clear.Reset();
clear.Down(center,7000,true,1.25); Check(!clear.Up(center,7010),"first tap at 120 DPI");
var scaledSlopEdge=new ScreenPoint(center.X+7.5,center.Y);
clear.Down(scaledSlopEdge,7100,false,1.25); clear.Dragged(scaledSlopEdge);
Check(clear.Up(scaledSlopEdge,7110),"six logical pixel slop maps to 7.5 physical pixels at 120 DPI");
clear.Reset();
clear.Down(center,8000,true,1.25); Check(!clear.Up(center,8010),"first tap before excessive scaled offset");
var tooFar=new ScreenPoint(center.X+7.51,center.Y);
clear.Down(tooFar,8100,false,1.25);
Check(!clear.Up(tooFar,8110),"second click outside DPI-scaled slop cannot clear");
clear.Reset();
clear.Down(center,9000,true,1.25);
Check(!clear.Up(new(center.X+WheelGeometry.CancelRadius*1.25,center.Y),9010),"neutral radius scales from Core geometry and excludes its boundary");

var screen=new ScreenRect(-1920,-200,1920,1080);
var origin=new ScreenPoint(-1918,-198);
var local=CaptureGeometry.LocalCrop(screen,origin,1.25);
Equal(local.X,-1920,"negative monitor crop x"); Equal(local.Y,-200,"negative monitor crop y");
Equal(local.Width,1200,"960 logical pixels at 120 DPI"); Equal(local.Height,800,"640 logical pixels at 120 DPI");
Check(local.Contains(origin),"crop contains original anchor");
var edge=CaptureGeometry.LocalCrop(screen,new(-1,879),1.25);
Equal(edge.Right,0,"right edge clamp"); Equal(edge.Bottom,880,"bottom edge clamp");
var tiny=CaptureGeometry.LocalCrop(new(-25,4,60,90),new(-20,5),2);
Check(tiny==new ScreenRect(-25,4,60,90),"small source uses full frame");
var padded=CaptureGeometry.Layout(tiny,new(-20,5));
Check(padded.Width==280 && padded.Height==280,"Mac minimum canvas dimensions");
Equal(padded.Point.X,(110+5d)/280,"point includes horizontal padding");
Equal(padded.Point.Y,(95+1d)/280,"point includes vertical padding");
var large=new ScreenRect(-2000,-400,4000,2400);
var reduced=CaptureGeometry.Layout(large,new(-1600,200));
Check(reduced.Width==1568 && reduced.Height==941,"expanded image is bounded by maximum side");
Equal(reduced.Point.X,.1,"expanded point scale");
Equal(reduced.Point.Y,((200-(-400))*reduced.Scale+reduced.OffsetY)/reduced.Height,"expanded y includes rounding padding");
Check(CaptureGeometry.Intersection(new(-20,-20,40,40),new(0,0,10,10))==new ScreenRect(0,0,10,10),"signed rectangle intersection");
Check(CaptureGeometry.Intersection(new(-20,-20,10,10),new(0,0,10,10))==null,"disjoint sources rejected");
Check(!CaptureGeometry.ValidPoint(new(double.NaN,0)),"NaN point rejected");
Check(!CaptureGeometry.ValidPoint(new((double)int.MaxValue+1,0)),"out of physical range rejected");
bool outsideRejected=false;
try { CaptureGeometry.LocalCrop(screen,new(0,100),1); } catch (InvalidOperationException) { outsideRejected=true; }
Check(outsideRejected,"monitor gap or outside point is not clamped");
SettingsShortcutChecks.Run(Check);
Console.WriteLine($"PASS {checks} deterministic native-rule checks; no Windows capture or hook acceptance implied.");
