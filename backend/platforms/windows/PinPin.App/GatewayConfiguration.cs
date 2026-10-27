using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using PinPin.Core;

namespace PinPin.App;

/// User-bound DPAPI protection. The only application-owned file stays in the chosen data directory.
internal static class GatewayConfiguration
{
    internal const string DefaultGatewayBaseUrl = "https://gateway.example.com/ping/v1";
    private const uint NoUi = 1;
    [StructLayout(LayoutKind.Sequential)] private struct Blob { public int Length; public nint Data; }
    [DllImport("crypt32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    private static extern bool CryptProtectData(ref Blob input, string? description, nint entropy,
        nint reserved, nint prompt, uint flags, out Blob output);
    [DllImport("crypt32.dll", SetLastError=true)]
    private static extern bool CryptUnprotectData(ref Blob input, nint description, nint entropy,
        nint reserved, nint prompt, uint flags, out Blob output);
    [DllImport("kernel32.dll")] private static extern nint LocalFree(nint memory);
    private sealed record Entry(string GatewayBaseURL, string AccessToken);

    internal static GatewayOptions? Load(string dataRoot)
    {
        string path=Path.Combine(dataRoot,"gateway.dpapi");
        if (!File.Exists(path)) return null;
        byte[] plaintext=Transform(File.ReadAllBytes(path),false);
        try { var entry=JsonSerializer.Deserialize<Entry>(plaintext) ?? throw new InvalidDataException();
            return Validate(entry); }
        finally { System.Security.Cryptography.CryptographicOperations.ZeroMemory(plaintext); }
    }
    internal static GatewayOptions? TryLoad(string dataRoot,Action<Exception> report)
    {
        try { return Load(dataRoot); }
        catch(Exception error) when(error is IOException or UnauthorizedAccessException or System.ComponentModel.Win32Exception or JsonException or ArgumentException)
        { report(error); return null; }
    }
    internal static void StoreFromStandardInput(string dataRoot)
    {
        string raw=Console.In.ReadToEnd();
        var entry=JsonSerializer.Deserialize<Entry>(raw,new JsonSerializerOptions { PropertyNameCaseInsensitive=true })
            ?? throw new InvalidDataException("Missing gateway configuration.");
        _=Store(dataRoot,new(entry.GatewayBaseURL,entry.AccessToken));
    }
    internal static GatewayOptions Store(string dataRoot,GatewaySetupInput input)
    {
        ArgumentNullException.ThrowIfNull(input);
        var options=Validate(new(input.GatewayBaseUrl,input.AccessToken));
        var entry=new Entry(options.GatewayBaseUri.AbsoluteUri,options.AccessToken);
        byte[] plaintext=Encoding.UTF8.GetBytes(JsonSerializer.Serialize(entry));
        byte[] protectedBytes;
        try { protectedBytes=Transform(plaintext,true); }
        finally { System.Security.Cryptography.CryptographicOperations.ZeroMemory(plaintext); }
        string path=Path.Combine(dataRoot,"gateway.dpapi"), temporary=path+"."+Guid.NewGuid().ToString("N")+".tmp";
        try
        {
            if(File.Exists(path) && (File.GetAttributes(path)&FileAttributes.ReparsePoint)!=0)
                throw new IOException("Refusing a linked gateway configuration file.");
            using(var stream=new FileStream(temporary,FileMode.CreateNew,FileAccess.Write,FileShare.None,
                4096,FileOptions.WriteThrough))
            { stream.Write(protectedBytes); stream.Flush(true); }
            File.Move(temporary,path,true);
            return options;
        }
        finally { if(File.Exists(temporary)) File.Delete(temporary); }
    }
    private static GatewayOptions Validate(Entry entry)
    {
        if(!Uri.TryCreate(entry.GatewayBaseURL,UriKind.Absolute,out var uri) || uri.Scheme!="https" || string.IsNullOrEmpty(uri.Host) ||
            uri.UserInfo.Length!=0 || uri.Query.Length!=0 || uri.Fragment.Length!=0 ||
            string.IsNullOrWhiteSpace(entry.AccessToken) || entry.AccessToken.Any(c=>c<33 || c>126))
            throw new InvalidDataException("Invalid gateway configuration.");
        return new GatewayOptions(uri,entry.AccessToken);
    }
    private static byte[] Transform(byte[] bytes,bool protect)
    {
        var handle=GCHandle.Alloc(bytes,GCHandleType.Pinned);
        var input=new Blob { Length=bytes.Length,Data=handle.AddrOfPinnedObject() };
        Blob output=default;
        try {
            bool ok=protect ? CryptProtectData(ref input,"PinPin gateway",0,0,0,NoUi,out output)
                : CryptUnprotectData(ref input,0,0,0,0,NoUi,out output);
            if(!ok) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            byte[] result=new byte[output.Length]; Marshal.Copy(output.Data,result,0,result.Length); return result;
        }
        finally { if(output.Data!=0) LocalFree(output.Data); handle.Free(); }
    }
}

internal sealed class UnconfiguredModels : IModelService
{
    private static Exception Missing() => new GatewayException("尚未配置 AI 连接。请通过托盘菜单的 AI 连接填写网关地址和访问令牌。取色、收藏原图、设置和本地资产仍可使用。");
    public Task PrewarmAsync(CancellationToken token)=>Task.CompletedTask;
    public Task<GenerationResult> GenerateAsync(ActionKind action,CapturedEvidence evidence,Action<string> onText,CancellationToken token)=>Task.FromException<GenerationResult>(Missing());
    public Task<GenerationResult> FollowupAsync(ActionKind action,PromptContext context,string previous,IReadOnlyList<FollowupExchange> earlier,string question,Action<string> onText,CancellationToken token)=>Task.FromException<GenerationResult>(Missing());
    public Task<PromptContext> PrepareSaveAsync(CapturedEvidence evidence,CancellationToken token)=>Task.FromResult(new PromptContext(evidence.SelectedText,evidence.SurroundingText,evidence.LocalImage,evidence.AppName,evidence.WindowTitle));
    public Task<SavedDescription> DescribeSavedAsync(PromptContext context,IReadOnlyList<string> existingTags,CancellationToken token)=>Task.FromException<SavedDescription>(Missing());
}
