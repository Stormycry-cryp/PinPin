using System.IO;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text.Json;
using System.Windows.Threading;
using PinPin.Core;
using PinPin.Native;
using PinPin.Presentation;
using Forms=System.Windows.Forms;

namespace PinPin.App;

internal static class Program
{
    [STAThread]
    public static int Main(string[] args)
    {
        string? dataRoot=null;
        try
        {
            dataRoot=ResolveDataRoot(args); EnsureDataDirectory(dataRoot);
            if(args.Contains("--configure-gateway-stdin")) {
                GatewayConfiguration.StoreFromStandardInput(dataRoot);
                WriteStatus(dataRoot,"gateway-configuration.json",new { configured=true, protection="Windows user DPAPI", plaintextFile=false }); return 0;
            }
            if(args.Contains("--credentials-status")) {
                WriteStatus(dataRoot,"gateway-status.json",new { configured=GatewayConfiguration.Load(dataRoot)!=null }); return 0;
            }
            string sid=WindowsIdentity.GetCurrent().User?.Value ?? Environment.UserName;
            using var instance=new Mutex(true,@"Local\PinPin-"+sid,out bool first);
            using var reopen=new EventWaitHandle(false,EventResetMode.AutoReset,@"Local\PinPin-reopen-"+sid);
            using var quit=new EventWaitHandle(false,EventResetMode.AutoReset,@"Local\PinPin-quit-"+sid);
            if(!first) { if(args.Contains("--quit")) quit.Set(); else reopen.Set(); return 0; }
            try { return args.Contains("--quit") ? 0 : Run(args,dataRoot,reopen,quit); }
            finally { instance.ReleaseMutex(); }
        }
        catch(Exception error) {
            if(dataRoot!=null) Log(dataRoot,"startup",error);
            if(!args.Contains("--configure-gateway-stdin") && !args.Contains("--credentials-status"))
                System.Windows.MessageBox.Show(StartupFailureMessage(error),"PinPin");
            return 1;
        }
    }

    private static int Run(string[] args,string dataRoot,EventWaitHandle reopen,EventWaitHandle quit)
    {
        var app=new System.Windows.Application { ShutdownMode=System.Windows.ShutdownMode.OnExplicitShutdown };
        var dispatcher=Dispatcher.CurrentDispatcher;
        using var presentation=new WindowsPresentation(dispatcher,Path.Combine(dataRoot,"appearance.json"));
        using var input=new WindowsInputSource();
        using var capture=new WindowsCaptureService();
        using var observer=new WindowsWindowObserver();
        using var http=GatewayModelService.CreateHttpClient();
        var gateway=GatewayConfiguration.TryLoad(dataRoot,error=>Log(dataRoot,"gateway-unavailable",error));
        var models=new ConfigurableModels(gateway is null ? new UnconfiguredModels() : new GatewayModelService(http,gateway));
        bool initialized=false,gatewayDialogOpen=false;
        var startedAt=DateTimeOffset.UtcNow;
        int exiting=0;
        ActionCoordinator? closingCoordinator=null;
        void Exit() {
            if(Interlocked.Exchange(ref exiting,1)!=0) return;
            dispatcher.InvokeAsync(async ()=> {
                try {
                    input.Dispose(); closingCoordinator?.Dispose(); presentation.Dispose();
                    if(closingCoordinator!=null) await closingCoordinator.DrainAsync();
                }
                catch(Exception error) { Log(dataRoot,"shutdown",error); }
                finally { app.Shutdown(); }
            });
        }
        void Exclude(nint window) {
            var result=CaptureExclusion.ExcludeWindow(window);
            if(!result.Success) WriteEvent(dataRoot,new { phase="capture-exclusion",success=false,error=result.Win32Error });
        }
        var callbacks=new PresentationCallbacks {
            QuitRequested=Exit,OwnWindowCreated=Exclude,
            SourceWindowWatched=observer.Watch,SourceWindowUnwatched=observer.Unwatch
        };
        using var coordinator=new ActionCoordinator(presentation,capture,new WindowsPixelSampler(),models,
            new JsonAssetStore(Path.Combine(dataRoot,"assets")),
            new JsonWheelSettingsStore(Path.Combine(dataRoot,"wheel-settings.json")),()=>input.Screens,callbacks,SourceName,input);
        closingCoordinator=coordinator;
        coordinator.BackgroundError+=error=>Log(dataRoot,"background",error);
        void PublishReady() {
            if(!initialized) return;
            WriteStatus(dataRoot,"host-ready.json",new { pid=Environment.ProcessId,session=Process.GetCurrentProcess().SessionId,
                startedAt,modelsConfigured=models.IsConfigured,dataRoot,framework=RuntimeInformation.FrameworkDescription,
                hooksStarted=true,sourceVisibility="WinEvent",browserRuntime=false });
        }
        bool SaveGateway(GatewaySetupInput value) {
            try {
                var saved=GatewayConfiguration.Store(dataRoot,value);
                models.Replace(new GatewayModelService(http,saved)); gateway=saved;
            }
            catch(Exception error) when(error is IOException or UnauthorizedAccessException or System.ComponentModel.Win32Exception or ArgumentException) {
                Log(dataRoot,"gateway-setup",error);
                return false;
            }
            try { PublishReady(); }
            catch(Exception error) when(error is IOException or UnauthorizedAccessException) {
                Log(dataRoot,"gateway-status-write",error);
            }
            return true;
        }
        void ShowGatewaySetup() {
            if(gatewayDialogOpen || Volatile.Read(ref exiting)!=0) return;
            gatewayDialogOpen=true;
            try { GatewaySetupDialog.Show(gateway?.GatewayBaseUri.AbsoluteUri ?? GatewayConfiguration.DefaultGatewayBaseUrl,
                SaveGateway,Exclude,Path.Combine(dataRoot,"appearance.json")); }
            finally { gatewayDialogOpen=false; }
        }
        var delivery=new InputDelivery(dispatcher,coordinator.Receive);
        input.Gesture+=delivery.Receive;
        observer.Changed+=state=>dispatcher.InvokeAsync(()=> { if(Volatile.Read(ref exiting)==0) presentation.UpdateSourceWindow(state); });
        using var trayIcon=System.Drawing.Icon.ExtractAssociatedIcon(Environment.ProcessPath!) ?? (System.Drawing.Icon)System.Drawing.SystemIcons.Application.Clone();
        using var tray=new Forms.NotifyIcon {
            Text="PinPin",Icon=trayIcon,
            Visible=true
        };
        using var menu=new Forms.ContextMenuStrip();
        menu.Items.Add("设置",null,(_,_)=>presentation.ShowSettings());
        menu.Items.Add("AI 连接",null,(_,_)=>ShowGatewaySetup());
        menu.Items.Add("资产看板",null,(_,_)=>presentation.ShowAssets());
        menu.Items.Add("清除标注",null,(_,_)=>coordinator.Receive(new(GesturePhase.ClearAll,null,default)));
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add("退出",null,(_,_)=>Exit()); tray.ContextMenuStrip=menu;
        tray.DoubleClick+=(_,_)=>presentation.ShowSettings();
        var registration=ThreadPool.RegisterWaitForSingleObject(reopen,(_,_)=>dispatcher.InvokeAsync(()=>presentation.ShowSettings()),null,Timeout.Infinite,false);
        var quitRegistration=ThreadPool.RegisterWaitForSingleObject(quit,(_,_)=>Exit(),null,Timeout.Infinite,false);
        app.DispatcherUnhandledException+=(_,eventArgs)=> { Log(dataRoot,"ui",eventArgs.Exception); eventArgs.Handled=true; Exit(); };
        app.Startup+=async (_,_)=> {
            try {
                input.Start(); // Wheel remains unarmed until preferences load; settings shortcut is already available.
                await coordinator.InitializeAsync();
                initialized=true; PublishReady();
                if(!args.Contains("--quiet")) {
                    presentation.ShowSettings();
                    if(!models.IsConfigured) ShowGatewaySetup();
                }
            }
            catch(Exception error) { Log(dataRoot,"initialization",error); System.Windows.MessageBox.Show(StartupFailureMessage(error),"PinPin"); Exit(); }
        };
        try { return app.Run(); }
        finally {
            Volatile.Write(ref exiting,1); registration.Unregister(null); quitRegistration.Unregister(null); delivery.Stop();
            input.Gesture-=delivery.Receive; input.Dispose(); coordinator.Dispose(); presentation.Dispose();
            // Also cover an OS-initiated shutdown that did not pass through the tray command.
            coordinator.DrainAsync().GetAwaiter().GetResult();
            observer.Dispose(); tray.Visible=false;
            WriteStatus(dataRoot,"host-stopped.json",new { pid=Environment.ProcessId,stoppedAt=DateTimeOffset.UtcNow });
        }
    }
    internal static string ResolveDataRoot(string[] args)
    {
        int index=Array.IndexOf(args,"--data-root");
        if(index>=0 && index==args.Length-1) throw new ArgumentException("Missing data root.");
        string root=Path.GetFullPath(index>=0?args[index+1]:Path.Combine(AppContext.BaseDirectory,"Data"));
        string? volume=Path.GetPathRoot(root);
        if(!OperatingSystem.IsWindows() || string.IsNullOrEmpty(volume) || volume.StartsWith(@"\\",StringComparison.Ordinal))
            throw new InvalidOperationException("Choose a local fixed drive for PinPin data.");
        var drive=new DriveInfo(volume);
        if(!drive.IsReady || drive.DriveType!=DriveType.Fixed) throw new InvalidOperationException("PinPin data drive is unavailable.");
        for(var cursor=new DirectoryInfo(root);cursor!=null;cursor=cursor.Parent)
            if(cursor.Exists && (cursor.Attributes&FileAttributes.ReparsePoint)!=0) throw new IOException("Reparse data path rejected.");
        return root;
    }
    internal static void EnsureDataDirectory(string root)
    {
        Directory.CreateDirectory(root);
        using var probe=new FileStream(Path.Combine(root,".pinpin-write-"+Guid.NewGuid().ToString("N")+".tmp"),
            FileMode.CreateNew,FileAccess.Write,FileShare.None,1,FileOptions.DeleteOnClose);
        probe.WriteByte(0); probe.Flush(true);
    }
    internal static string StartupFailureMessage(Exception error) => error is IOException or UnauthorizedAccessException
        ? "PinPin 无法写入本地数据目录。请把应用解压到自己有写入权限的位置，或用 --data-root 指定可写目录后重试。"
        : "PinPin 启动失败，请查看数据目录中的 host-errors.jsonl。";
    private static (string,string) SourceName(TargetAnchor anchor)
    {
        string name="",title="";
        try { using var process=Process.GetProcessById(anchor.ProcessId); name=process.ProcessName; }
        catch(Exception error) when(error is ArgumentException or InvalidOperationException or System.ComponentModel.Win32Exception) { }
        var text=new System.Text.StringBuilder(1024); GetWindowText(anchor.Window,text,text.Capacity); title=text.ToString();
        return(name,title);
    }
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] private static extern int GetWindowText(nint window,System.Text.StringBuilder text,int capacity);
    private static readonly object logGate=new();
    internal static void Log(string root,string phase,Exception error)=>WriteEvent(root,new { at=DateTimeOffset.UtcNow,phase,error=error.GetType().Name });
    private static void WriteEvent(string root,object value) {
        try { lock(logGate) File.AppendAllText(Path.Combine(root,"host-errors.jsonl"),JsonSerializer.Serialize(value)+Environment.NewLine); }
        catch(IOException) { } catch(UnauthorizedAccessException) { }
    }
    private static void WriteStatus(string root,string name,object value)
    {
        string path=Path.Combine(root,name),temporary=path+"."+Guid.NewGuid().ToString("N")+".tmp";
        try { File.WriteAllText(temporary,JsonSerializer.Serialize(value)); File.Move(temporary,path,true); }
        finally { if(File.Exists(temporary)) File.Delete(temporary); }
    }
}

/// One pending dispatcher operation. Move events replace only an adjacent move, preserving button edges.
internal sealed class InputDelivery(Dispatcher dispatcher,Action<GestureEvent> consume)
{
    private readonly object gate=new();
    private readonly LinkedList<GestureEvent> events=new();
    private bool scheduled,stopped;
    internal void Receive(GestureEvent value) {
        lock(gate) {
            if(stopped) return;
            if(value.Phase==GesturePhase.Moved && events.Last?.Value.Phase==GesturePhase.Moved) events.Last.Value=value;
            else events.AddLast(value);
            if(scheduled) return; scheduled=true;
            dispatcher.InvokeAsync(Drain,DispatcherPriority.Input);
        }
    }
    private void Drain() {
        GestureEvent[] batch;
        lock(gate) { if(stopped) { scheduled=false; return; } batch=events.ToArray(); events.Clear(); scheduled=false; }
        foreach(var value in batch) consume(value);
    }
    internal void Stop() { lock(gate) { stopped=true; events.Clear(); } }
}
