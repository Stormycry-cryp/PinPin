using System.Globalization;
using System.Text;
using PinPin.Core;

namespace PinPin.Presentation.Models;

internal enum AssetScope { All, Saved, Color }

internal sealed class AssetModel
{
    private sealed record Indexed(AssetRecord Asset, string Signature, string[] Fields);
    private Dictionary<AssetId, Indexed> index = [];
    private IReadOnlyList<AssetRecord> records = [];
    public IReadOnlyList<AssetRecord> Records => records;
    public IReadOnlyList<AssetRecord> Results { get; private set; } = [];
    public IReadOnlyList<string> Tags { get; private set; } = [];
    public string Query { get; private set; } = "";
    public string? Tag { get; private set; }
    public AssetScope Scope { get; private set; }
    public AssetId? OpenRow { get; private set; }
    public Action<AssetEdit>? Edit { get; set; }
    public event Action? Changed;
    public event Action? ExpansionChanged;
    public long IndexBuilds { get; private set; }

    public static string Fold(string value)
    {
        var output = new StringBuilder(value.Length);
        foreach (char c in value.Normalize(NormalizationForm.FormKD))
            if (CharUnicodeInfo.GetUnicodeCategory(c) != UnicodeCategory.NonSpacingMark) output.Append(char.ToUpperInvariant(c));
        return output.ToString();
    }
    private static string[] Fields(AssetRecord item) => item.Kind == AssetKind.Color
        ? [item.Color?.Hex ?? "", item.Color?.Rgb ?? "", item.AppName, item.WindowTitle]
        : [item.Text, item.AppName, item.WindowTitle, .. item.Tags];

    public void Receive(IReadOnlyList<AssetRecord> assets)
    {
        var next = new Dictionary<AssetId, Indexed>(assets.Count);
        foreach (var asset in assets)
        {
            var fields = Fields(asset); string signature = string.Join('\0', fields);
            if (index.TryGetValue(asset.Key, out var previous) && previous.Signature == signature)
                next[asset.Key] = previous with { Asset = asset };
            else { next[asset.Key] = new(asset, signature, fields.Select(Fold).ToArray()); IndexBuilds++; }
        }
        index = next;
        records = next.Values.Select(x => x.Asset).OrderByDescending(x => x.CreatedAt).ThenBy(x => x.Kind).ThenBy(x => x.Id).ToArray();
        Tags = records.Where(x => x.Kind == AssetKind.Saved).SelectMany(x => x.Tags)
            .GroupBy(x => x).OrderByDescending(x => x.Count()).ThenBy(x => x.Key).Select(x => x.Key).ToArray();
        if (Tag is not null && !Tags.Contains(Tag)) Tag = null;
        if (OpenRow is { } key && !index.ContainsKey(key)) OpenRow = null;
        Refresh();
    }
    public void Search(string query) { if (Query == query) return; Query = query; Refresh(); }
    public void SelectScope(AssetScope scope) { Scope = scope; if (scope == AssetScope.Color) Tag = null; Refresh(); }
    public void SelectTag(string? tag) { Tag = tag; Refresh(); }
    public void Toggle(AssetId id) { OpenRow = OpenRow == id ? null : id; ExpansionChanged?.Invoke(); }
    private void Refresh()
    {
        string query = Fold(Query.Trim());
        Results = records.Where(x => (Scope == AssetScope.All || (Scope == AssetScope.Saved) == (x.Kind == AssetKind.Saved))
            && (Tag is null || (x.Kind == AssetKind.Saved && x.Tags.Contains(Tag)))
            && (query.Length == 0 || index[x.Key].Fields.Any(f => f.Contains(query, StringComparison.Ordinal)))).ToArray();
        Changed?.Invoke();
    }
    public void Delete(AssetId id) { if (index.ContainsKey(id)) Edit?.Invoke(new AssetEdit.Delete(id)); }
    public void AddTag(Guid id, string raw) => TagIntent(id, raw, true);
    public void RemoveTag(Guid id, string raw) => TagIntent(id, raw, false);
    private void TagIntent(Guid id, string raw, bool adding)
    {
        string tag = raw.Trim();
        if (tag.Length == 0 || tag.Length > 16 || !index.ContainsKey(new(AssetKind.Saved, id))) return;
        Edit?.Invoke(adding ? new AssetEdit.AddTag(id, tag) : new AssetEdit.RemoveTag(id, tag));
    }
}
