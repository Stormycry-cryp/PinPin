using System.Text;
using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace PinPin.Core;

internal static class LocalJson
{
    internal static readonly JsonSerializerOptions Options = new(JsonSerializerDefaults.Web)
    { Converters = { new JsonStringEnumConverter() }, WriteIndented = false };

    // Write beside the destination so commit is one same-volume rename. Never truncate old data.
    internal static async Task WriteAsync<T>(string path, T value, CancellationToken token)
    {
        var directory = Path.GetDirectoryName(path)!;
        Directory.CreateDirectory(directory);
        if (File.Exists(path) && (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
            throw new IOException("Refusing a linked data file.");
        var temporary = Path.Combine(directory, $".pinpin-{Guid.NewGuid():N}.tmp");
        try
        {
            await using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write,
                FileShare.None, 4096, FileOptions.Asynchronous | FileOptions.WriteThrough))
            {
                await JsonSerializer.SerializeAsync(stream, value, Options, token).ConfigureAwait(false);
                await stream.FlushAsync(token).ConfigureAwait(false);
                stream.Flush(true);
            }
            token.ThrowIfCancellationRequested();
            File.Move(temporary, path, true);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
}

public static class ActionRules
{
    public static string? NormalizeTag(string raw)
    {
        var value = System.Text.RegularExpressions.Regex.Replace(raw.Trim(), @"\s+", " ");
        return CharacterCount(value) is > 0 and <= 16 ? value : null;
    }
    public static string[] NormalizeTags(IEnumerable<string> tags, int limit = 8) => tags
        .Select(NormalizeTag).Where(x => x is not null).Select(x => x!)
        .Distinct(StringComparer.OrdinalIgnoreCase).Take(limit).ToArray();
    internal static int CharacterCount(string value) => new StringInfo(value).LengthInTextElements;
    public static int OutputTokens(string text) => Math.Clamp(CharacterCount(text) + 120, 240, 1600);
    internal static string Prefix(string value, int count)
    {
        var offsets = StringInfo.ParseCombiningCharacters(value);
        return offsets.Length <= count ? value : value[..offsets[count]];
    }
}

/// Owns one independent Windows data directory. Acknowledged records alone are observable.
public sealed class JsonAssetStore : IAssetStore
{
    private sealed record Envelope(int Version, List<AssetRecord> Items);
    private readonly string directory;
    private readonly string file;
    private readonly SemaphoreSlim gate = new(1, 1);
    private List<AssetRecord> items = [];
    private bool loaded;
    public JsonAssetStore(string directoryPath)
    { directory = Path.GetFullPath(directoryPath); file = Path.Combine(directory, "assets.json"); }

    private static AssetRecord Copy(AssetRecord item) => item with { Tags = (string[])item.Tags.Clone() };
    private IReadOnlyList<AssetRecord> Snapshot() => items.OrderByDescending(x => x.CreatedAt)
        .ThenBy(x => x.Kind == AssetKind.Color ? 0 : 1).ThenBy(x => x.Id.ToString("N"), StringComparer.Ordinal).Select(Copy).ToArray();
    private async Task LoadCoreAsync(CancellationToken token)
    {
        if (loaded) return;
        if (Directory.Exists(file)) throw new IOException("Asset file is a directory.");
        if (File.Exists(file))
        {
            await using var stream = File.OpenRead(file);
            var envelope = await JsonSerializer.DeserializeAsync<Envelope>(stream, LocalJson.Options, token).ConfigureAwait(false)
                ?? throw new InvalidDataException("Invalid asset data.");
            if (envelope.Version != 1 || envelope.Items is null) throw new InvalidDataException("Unsupported asset data.");
            var keys = new HashSet<AssetId>();
            var restored = new List<AssetRecord>();
            foreach (var item in envelope.Items)
            {
                if (!Enum.IsDefined(item.Kind) || item.Tags is null || !keys.Add(item.Key) ||
                    (item.Kind == AssetKind.Color && item.Color is null)) throw new InvalidDataException("Invalid asset record.");
                var image = item.ImagePath;
                if (image is not null)
                {
                    var name = Path.GetFileName(image);
                    if (name != $"{item.Id:N}.png" || item.Kind != AssetKind.Saved) throw new InvalidDataException("Invalid asset image path.");
                    image = Path.Combine(directory, "Images", name);
                }
                restored.Add(Copy(item with { ImagePath = image }));
            }
            items = restored;
        }
        loaded = true;
    }
    private async Task CommitAsync(List<AssetRecord> next, CancellationToken token)
    {
        await LocalJson.WriteAsync(file, new Envelope(1, next), token).ConfigureAwait(false);
        items = next;
    }
    public async Task<IReadOnlyList<AssetRecord>> LoadAsync(CancellationToken cancellationToken = default)
    {
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try { await LoadCoreAsync(cancellationToken).ConfigureAwait(false); return Snapshot(); }
        finally { gate.Release(); }
    }
    public async Task<AssetRecord> SaveOriginalAsync(Guid id, PromptContext evidence, CancellationToken cancellationToken)
    {
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        string? newlyWritten = null;
        try
        {
            await LoadCoreAsync(cancellationToken).ConfigureAwait(false);
            var existing = items.FirstOrDefault(x => x.Key == new AssetId(AssetKind.Saved, id));
            if (existing is not null) return Copy(existing);
            var text = evidence.SelectedText.Trim();
            if (ActionRules.CharacterCount(text) > 4000) throw new InvalidDataException("Selected text exceeds 4000 characters.");
            var image = text.Length == 0 ? evidence.Image : null;
            if (text.Length == 0 && image?.UnmarkedPng.Length is not > 0) throw new InvalidDataException("无法识别指向的内容。");
            var duplicate = image is null ? items.FindIndex(x => x.Kind == AssetKind.Saved && x.ImagePath is null && x.Text == text) : -1;
            if (duplicate >= 0)
            {
                var refreshed = items[duplicate] with { CreatedAt = DateTimeOffset.UtcNow };
                var moved = new List<AssetRecord>(items); moved[duplicate] = refreshed;
                await CommitAsync(moved, cancellationToken).ConfigureAwait(false); return Copy(refreshed);
            }
            string? path = null;
            if (image is not null)
            {
                if (image.UnmarkedPng.Length > 8_000_000) throw new InvalidDataException("Image is too large.");
                var images = Path.Combine(directory, "Images"); Directory.CreateDirectory(images);
                path = Path.Combine(images, $"{id:N}.png");
                // The original bytes have no pointing mark; do not re-encode them.
                var temp = Path.Combine(images, $".{Guid.NewGuid():N}.tmp");
                try
                {
                    await File.WriteAllBytesAsync(temp, image.UnmarkedPng, cancellationToken).ConfigureAwait(false);
                    cancellationToken.ThrowIfCancellationRequested();
                    File.Move(temp, path, false); newlyWritten = path;
                }
                finally { if (File.Exists(temp)) File.Delete(temp); }
            }
            var record = new AssetRecord(id, AssetKind.Saved, DateTimeOffset.UtcNow, text, [],
                ActionRules.Prefix(evidence.AppName, 200), ActionRules.Prefix(evidence.WindowTitle, 300), path,
                image?.OriginalPointInImage);
            await CommitAsync([.. items, record], cancellationToken).ConfigureAwait(false);
            newlyWritten = null;
            return Copy(record);
        }
        finally
        {
            try { if (newlyWritten is not null) File.Delete(newlyWritten); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { /* A failed metadata write may leave an unreferenced original. */ }
            finally { gate.Release(); }
        }
    }
    public async Task<AssetRecord> SaveColorAsync(Guid id, PixelColor color, string appName, string windowTitle, CancellationToken cancellationToken)
    {
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await LoadCoreAsync(cancellationToken).ConfigureAwait(false);
            var existing = items.FirstOrDefault(x => x.Key == new AssetId(AssetKind.Color, id));
            if (existing is not null) return Copy(existing);
            var record = new AssetRecord(id, AssetKind.Color, DateTimeOffset.UtcNow, color.Hex, [],
                ActionRules.Prefix(appName, 200), ActionRules.Prefix(windowTitle, 300), Color: color);
            await CommitAsync([.. items, record], cancellationToken).ConfigureAwait(false); return Copy(record);
        }
        finally { gate.Release(); }
    }
    public async Task<AssetRecord?> EnrichAsync(Guid id, SavedDescription description, CancellationToken cancellationToken)
    {
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await LoadCoreAsync(cancellationToken).ConfigureAwait(false);
            var index = items.FindIndex(x => x.Key == new AssetId(AssetKind.Saved, id));
            if (index < 0) return null;
            var old = items[index];
            var record = old with { Text = old.ImagePath is null ? old.Text : ActionRules.Prefix(description.Text, 4000),
                Tags = old.Tags.Length == 0 ? ActionRules.NormalizeTags(description.Tags) : old.Tags };
            var next = new List<AssetRecord>(items); next[index] = record;
            await CommitAsync(next, cancellationToken).ConfigureAwait(false); return Copy(record);
        }
        finally { gate.Release(); }
    }
    public async Task ApplyAsync(AssetEdit edit, CancellationToken cancellationToken = default)
    {
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await LoadCoreAsync(cancellationToken).ConfigureAwait(false);
            var key = edit switch { AssetEdit.Delete d => d.Key, AssetEdit.AddTag a => new AssetId(AssetKind.Saved, a.Id),
                AssetEdit.RemoveTag r => new AssetId(AssetKind.Saved, r.Id), _ => throw new ArgumentException("Unknown edit.") };
            var index = items.FindIndex(x => x.Key == key); if (index < 0) return;
            var old = items[index]; var next = new List<AssetRecord>(items);
            if (edit is AssetEdit.Delete)
            {
                next.RemoveAt(index);
                // Move the image aside first, and restore it if metadata commit fails.
                var trash = old.ImagePath is not null && File.Exists(old.ImagePath) ? old.ImagePath + $".{Guid.NewGuid():N}.delete" : null;
                if (trash is not null) File.Move(old.ImagePath!, trash);
                try { await CommitAsync(next, cancellationToken).ConfigureAwait(false); }
                catch { if (trash is not null) File.Move(trash, old.ImagePath!); throw; }
                if (trash is not null) { try { File.Delete(trash); } catch (Exception e) when (e is IOException or UnauthorizedAccessException) { /* Already committed; an orphan is safe. */ } }
                return;
            }
            var raw = edit is AssetEdit.AddTag add ? add.Tag : ((AssetEdit.RemoveTag)edit).Tag;
            var tag = ActionRules.NormalizeTag(raw); if (tag is null) return;
            var tags = edit is AssetEdit.AddTag ? ActionRules.NormalizeTags(old.Tags.Append(tag)) :
                old.Tags.Where(x => !string.Equals(x, tag, StringComparison.OrdinalIgnoreCase)).ToArray();
            if (old.Tags.SequenceEqual(tags)) return;
            next[index] = old with { Tags = tags };
            await CommitAsync(next, cancellationToken).ConfigureAwait(false);
        }
        finally { gate.Release(); }
    }
}

public sealed class JsonWheelSettingsStore : IWheelSettingsStore
{
    private readonly string file;
    private readonly SemaphoreSlim gate = new(1, 1);
    private long latestRequested;
    public JsonWheelSettingsStore(string filePath) { file = Path.GetFullPath(filePath); }
    public async Task<WheelSettings> LoadAsync(CancellationToken cancellationToken = default)
    {
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (Directory.Exists(file)) throw new IOException("Settings file is a directory.");
            if (!File.Exists(file)) return WheelSettings.Default.Copy();
            await using var stream = File.OpenRead(file);
            var value = await JsonSerializer.DeserializeAsync<WheelSettings>(stream, LocalJson.Options, cancellationToken).ConfigureAwait(false);
            if (value?.Slots is null || value.Colors is null || !value.IsValid || value.Colors.Keys.Any(k => !Enum.IsDefined(k)))
                throw new InvalidDataException("Invalid wheel settings.");
            return value.Copy();
        }
        finally { gate.Release(); }
    }
    public async Task<bool> SaveAsync(WheelSettings settings, CancellationToken cancellationToken = default)
    {
        var revision = Interlocked.Increment(ref latestRequested);
        var copy = settings.Copy();
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (revision != Volatile.Read(ref latestRequested) || !copy.IsValid || copy.Colors.Keys.Any(k => !Enum.IsDefined(k))) return false;
            await LocalJson.WriteAsync(file, copy, cancellationToken).ConfigureAwait(false);
            return true;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException) { return false; }
        finally { gate.Release(); }
    }
}
