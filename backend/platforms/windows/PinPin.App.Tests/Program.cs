using System.IO;
using System.Text;
using System.Text.Json;
using System.Windows.Threading;
using PinPin.App;
using PinPin.Core;
using PinPin.App.Tests;

internal static class Tests
{
    private static int checks;
    private static void Check(bool condition,string label) { if(!condition) throw new Exception(label); checks++; }
    [STAThread]
    private static int Main(string[] args)
    {
        string parent=args.Length>0?args[0]:throw new ArgumentException("Explicit test root required");
        if(!Path.IsPathFullyQualified(parent) || parent.StartsWith(@"\\",StringComparison.Ordinal) || !Directory.Exists(parent))
            throw new InvalidOperationException("Host tests require an explicit existing local test directory.");
        string root=Path.GetFullPath(Path.Combine(parent,"host-tests-"+Guid.NewGuid().ToString("N")));
        Program.EnsureDataDirectory(Program.ResolveDataRoot(["--data-root",root]));
        try {
            Check(Program.ResolveDataRoot(["--data-root",root])==root,"explicit data path");
            Check(Program.ResolveDataRoot(["--data-root",@"C:\PinPin-Path-Validation-Only"])==@"C:\PinPin-Path-Validation-Only","fixed C path accepted by resolver without writing C");
            try { Program.ResolveDataRoot(["--data-root",@"\\example.invalid\share\PinPin"]); throw new Exception("network path accepted"); }
            catch(InvalidOperationException) { checks++; }
            try { Program.ResolveDataRoot(["--data-root"]); throw new Exception("missing root accepted"); }
            catch(ArgumentException) { checks++; }
            Check(GatewayConfiguration.Load(root)==null,"unconfigured local state");
            string token="synthetic-local-only-"+Guid.NewGuid().ToString("N");
            var savedInput=Console.In;
            try {
                Console.SetIn(new StringReader(JsonSerializer.Serialize(new { GatewayBaseURL="https://example.invalid/ping/v1",AccessToken=token })));
                GatewayConfiguration.StoreFromStandardInput(root);
            } finally { Console.SetIn(savedInput); }
            var options=GatewayConfiguration.Load(root)!;
            Check(options.AccessToken==token && options.GatewayBaseUri.AbsoluteUri=="https://example.invalid/ping/v1","DPAPI roundtrip");
            byte[] protectedBytes=File.ReadAllBytes(Path.Combine(root,"gateway.dpapi"));
            Check(!Encoding.UTF8.GetString(protectedBytes).Contains(token,StringComparison.Ordinal),"no plaintext file");
            Check(Directory.GetFiles(root).Length==1,"no temporary secret file");
            File.WriteAllBytes(Path.Combine(root,"gateway.dpapi"),[1,2,3,4]);
            try { GatewayConfiguration.Load(root); throw new Exception("corrupt DPAPI accepted"); }
            catch(System.ComponentModel.Win32Exception) { checks++; }
            Exception? reported=null;
            Check(GatewayConfiguration.TryLoad(root,error=>reported=error)==null && reported is System.ComponentModel.Win32Exception,"corrupt gateway preserves local startup");
            Check(File.ReadAllBytes(Path.Combine(root,"gateway.dpapi")).SequenceEqual(new byte[] {1,2,3,4}),"corrupt encrypted bytes preserved");
            try { new UnconfiguredModels().GenerateAsync(ActionKind.Explain,null!,_=>{},default).GetAwaiter().GetResult(); throw new Exception("offline model fabricated result"); }
            catch(GatewayException error) { Check(error.Message.Contains("尚未配置"),"offline error is actionable"); }

            GatewaySetupChecks.Run(root,Check);
            ConfigurableModelsChecks.RunAsync(Check).GetAwaiter().GetResult();
            var dispatcher=Dispatcher.CurrentDispatcher;
            var observed=new List<GestureEvent>();
            var input=new InputDelivery(dispatcher,observed.Add);
            input.Receive(new(GesturePhase.Began,null,new(1,1)));
            for(int i=0;i<50000;i++) input.Receive(new(GesturePhase.Moved,null,new(i,i)));
            input.Receive(new(GesturePhase.Released,null,new(60000,60000)));
            input.Receive(new(GesturePhase.Began,null,new(2,2)));
            input.Receive(new(GesturePhase.Moved,null,new(3,3)));
            input.Receive(new(GesturePhase.ModifierReleased,null,new(4,4)));
            var frame=new DispatcherFrame(); dispatcher.InvokeAsync(()=>frame.Continue=false,DispatcherPriority.ApplicationIdle);
            Dispatcher.PushFrame(frame);
            Check(observed.Count==6,"mouse moves coalesced without dropping edges");
            Check(observed.Select(x=>x.Phase).SequenceEqual(new[] { GesturePhase.Began,GesturePhase.Moved,GesturePhase.Released,GesturePhase.Began,GesturePhase.Moved,GesturePhase.ModifierReleased }),"input ordering");
            Check(observed[1].Point.X==49999,"latest move preserved");
            input.Receive(new(GesturePhase.Moved,null,new(5,5)));
            input.Receive(new(GesturePhase.OpenSettings,null,new(6,6)));
            input.Receive(new(GesturePhase.Released,null,new(7,7)));
            frame=new DispatcherFrame();dispatcher.InvokeAsync(()=>frame.Continue=false,DispatcherPriority.ApplicationIdle);Dispatcher.PushFrame(frame);
            Check(observed.Skip(6).Select(x=>x.Phase).SequenceEqual(new[] {GesturePhase.Moved,GesturePhase.OpenSettings,GesturePhase.Released}),"settings transition keeps its place between pointer edges");
            Check(observed[7].Anchor is null,"settings transition needs no captured anchor");
            input.Receive(new(GesturePhase.Began,null,default));input.Stop();
            frame=new DispatcherFrame();dispatcher.InvokeAsync(()=>frame.Continue=false,DispatcherPriority.ApplicationIdle);Dispatcher.PushFrame(frame);
            Check(observed.Count==9,"stopped delivery ignores pending callbacks");
            Console.WriteLine($"PASS {checks} host checks; local DPAPI and dispatcher only; no credentials transferred or models requested."); return 0;
        }
        finally { Directory.Delete(root,true); }
    }
}
