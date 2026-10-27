using System.IO;
using System.Text;
using System.Text.Json;
using PinPin.App;
using PinPin.Core;

namespace PinPin.App.Tests;

internal static class GatewaySetupChecks
{
    internal static void Run(string testRoot,Action<bool,string> check)
    {
        string root=Path.Combine(testRoot,"gateway-setup");Program.EnsureDataDirectory(root);
        const string url="https://example.invalid/ping/v1";
        const string token="synthetic-public-local-test-token-setup-20261024";
        var stored=GatewayConfiguration.Store(root,new(url,token));
        check(stored.GatewayBaseUri.AbsoluteUri==url && stored.AccessToken==token,"typed gateway configuration returns validated options");
        var reopened=GatewayConfiguration.Load(root)!;
        check(reopened.GatewayBaseUri==stored.GatewayBaseUri && reopened.AccessToken==token,"typed gateway current-user DPAPI reopen");
        string file=Path.Combine(root,"gateway.dpapi");byte[] original=File.ReadAllBytes(file);
        check(!Encoding.UTF8.GetString(original).Contains(token,StringComparison.Ordinal),"typed gateway file contains no plaintext synthetic token");
        foreach(var bad in new[] {
            new GatewaySetupInput("http://example.invalid/ping/v1",token),
            new GatewaySetupInput("https://user:password@example.invalid/ping/v1",token),
            new GatewaySetupInput(url+"?extra=1",token),new GatewaySetupInput(url+"#fragment",token),
            new GatewaySetupInput("relative",token),new GatewaySetupInput(url,""),
            new GatewaySetupInput(url,"space in token"),new GatewaySetupInput(url,"非ASCII") })
        {
            bool rejected=false;
            try { GatewayConfiguration.Store(root,bad); }
            catch(InvalidDataException) { rejected=true; }
            check(rejected,"invalid typed configuration rejected before write");
            check(File.ReadAllBytes(file).SequenceEqual(original),"invalid input preserves prior encrypted file bytes");
        }
        bool writeFailed=false;
        using(var held=new FileStream(file,FileMode.Open,FileAccess.Read,FileShare.Read))
        {
            try { GatewayConfiguration.Store(root,new(url,"second-public-synthetic-token-local-test-only")); }
            catch(Exception error) when(error is IOException or UnauthorizedAccessException) { writeFailed=true; }
        }
        check(writeFailed && File.ReadAllBytes(file).SequenceEqual(original),"failed replacement preserves prior encrypted file");
        check(GatewayConfiguration.Load(root)!.AccessToken==token,"old connection still loads after replacement failure");
        check(!Directory.EnumerateFiles(root,"*.tmp").Any(),"failed replacement leaves no temporary encrypted file");

        int result=Program.Main(["--credentials-status","--data-root",root]);
        using(var status=JsonDocument.Parse(File.ReadAllBytes(Path.Combine(root,"gateway-status.json"))))
            check(result==0 && status.RootElement.EnumerateObject().Count()==1 && status.RootElement.GetProperty("configured").GetBoolean(),"CLI status reports configured bool only");
        Program.Log(root,"synthetic-log-safety",new InvalidOperationException(token));
        string log=File.ReadAllText(Path.Combine(root,"host-errors.jsonl"));
        check(!log.Contains(token,StringComparison.Ordinal) && log.Contains(nameof(InvalidOperationException),StringComparison.Ordinal),"host error log records error type without synthetic token value");

        string path=Path.Combine(testRoot,"not-a-data-directory");File.WriteAllText(path,"untouched");
        bool localFailure=false;
        try { Program.EnsureDataDirectory(path); } catch(IOException error)
        { localFailure=Program.StartupFailureMessage(error).Contains("写入",StringComparison.Ordinal); }
        check(localFailure && File.ReadAllText(path)=="untouched","unusable data directory gives local write guidance without overwriting existing file");
        check(!Program.StartupFailureMessage(new UnauthorizedAccessException(token)).Contains(token,StringComparison.Ordinal),"startup message does not echo exception contents");
    }
}
