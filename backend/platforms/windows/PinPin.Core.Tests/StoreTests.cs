using PinPin.Core;

namespace PinPin.Core.Tests;

internal static class StoreTests
{
    public static void Register(List<(string, Func<Task>)> tests)
    {
        tests.Add(("settings-trigger-legacy-default-copy-and-restart", async () =>
        {
            using var temp = new Temp(); var file = Path.Combine(temp.Path, "wheel.json");
            await File.WriteAllTextAsync(file, "{\"slots\":[\"Explain\"],\"colors\":{}}");
            var store = new JsonWheelSettingsStore(file); var legacy = await store.LoadAsync();
            Check.True(legacy.TriggerEnabled); Check.Equal(ActionKind.Explain, legacy.Slots[0]!.Value);
            var disabled = legacy with { TriggerEnabled = false };
            Check.True(!disabled.Copy().TriggerEnabled); Check.True(await store.SaveAsync(disabled));
            Check.True(!(await new JsonWheelSettingsStore(file).LoadAsync()).TriggerEnabled);
            Check.True((await File.ReadAllTextAsync(file)).Contains("\"triggerEnabled\":false", StringComparison.Ordinal));
            Check.True(await store.SaveAsync(disabled with { TriggerEnabled = true }));
            Check.True((await new JsonWheelSettingsStore(file).LoadAsync()).TriggerEnabled);
        }));
        tests.Add(("assets.original-bytes-typed-id-restart", async () =>
        {
            using var temp = new Temp(); var store = new JsonAssetStore(temp.Path); var id = Guid.NewGuid();
            using var evidence = Fixtures.Capture(Fixtures.Anchor(id));
            var saved = await store.SaveOriginalAsync(id, Fixtures.Context(evidence), default);
            Check.Sequence(evidence.LocalImage!.UnmarkedPng, await File.ReadAllBytesAsync(saved.ImagePath!));
            Check.Equal(evidence.LocalImage.OriginalPointInImage, saved.PointInImage!.Value);
            await store.SaveColorAsync(id, new(12, 34, 56, "Windows SDR encoded RGB"), "A", "W", default);
            var restarted = new JsonAssetStore(temp.Path); var all = await restarted.LoadAsync();
            Check.Equal(2, all.Count); Check.Equal(2, all.Select(x => x.Key).Distinct().Count());
            await restarted.ApplyAsync(new AssetEdit.Delete(new(AssetKind.Color, id)));
            Check.Equal(1, (await restarted.LoadAsync()).Count); Check.True(File.Exists(saved.ImagePath));
        }));
        tests.Add(("assets.atomic-tag-intents-and-enrichment", async () =>
        {
            using var temp = new Temp(); var store = new JsonAssetStore(temp.Path); var id = Guid.NewGuid();
            using var evidence = Fixtures.Capture(text: "原始文字", image: false);
            await store.SaveOriginalAsync(id, Fixtures.Context(evidence), default);
            await store.ApplyAsync(new AssetEdit.AddTag(id, " Old "));
            await Task.WhenAll(store.ApplyAsync(new AssetEdit.AddTag(id, "A")), store.ApplyAsync(new AssetEdit.AddTag(id, "B")), store.ApplyAsync(new AssetEdit.RemoveTag(id, "old")));
            await store.ApplyAsync(new AssetEdit.AddTag(id, "a"));
            await store.EnrichAsync(id, new("不应覆盖原文", ["Model"]), default);
            var item = (await store.LoadAsync()).Single();
            Check.Sequence(new[] { "A", "B" }, item.Tags); Check.Equal("原始文字", item.Text);
            item.Tags[0] = "external mutation";
            Check.Equal("A", (await store.LoadAsync()).Single().Tags[0]);
        }));
        tests.Add(("assets.failed-commit-keeps-bytes-and-recovery", async () =>
        {
            using var temp = new Temp(); var store = new JsonAssetStore(temp.Path); var id = Guid.NewGuid();
            await store.SaveColorAsync(id, new(1, 2, 3, "test"), "A", "W", default);
            var file = Path.Combine(temp.Path, "assets.json"); var original = await File.ReadAllBytesAsync(file); var backup = file + ".backup";
            File.Move(file, backup); Directory.CreateDirectory(file);
            await Check.ThrowsAsync(() => store.SaveColorAsync(Guid.NewGuid(), new(4, 5, 6, "test"), "", "", default));
            Check.Equal(1, (await store.LoadAsync()).Count); Check.Sequence(original, await File.ReadAllBytesAsync(backup));
            Directory.Delete(file); File.Move(backup, file);
            await store.SaveColorAsync(Guid.NewGuid(), new(7, 8, 9, "test"), "", "", default);
            Check.Equal(2, (await new JsonAssetStore(temp.Path).LoadAsync()).Count);
            Check.True(!Directory.EnumerateFiles(temp.Path, "*.tmp", SearchOption.AllDirectories).Any());
        }));
        tests.Add(("assets.failed-tag-and-delete-preserve-image", async () =>
        {
            using var temp = new Temp(); var store = new JsonAssetStore(temp.Path); var id = Guid.NewGuid();
            using var evidence = Fixtures.Capture(); var saved = await store.SaveOriginalAsync(id, Fixtures.Context(evidence), default);
            var file = Path.Combine(temp.Path, "assets.json"); var bytes = await File.ReadAllBytesAsync(file); File.Move(file, file + ".backup"); Directory.CreateDirectory(file);
            await Check.ThrowsAsync(() => store.ApplyAsync(new AssetEdit.AddTag(id, "lost")));
            await Check.ThrowsAsync(() => store.ApplyAsync(new AssetEdit.Delete(saved.Key)));
            Check.True(File.Exists(saved.ImagePath)); Check.Sequence(evidence.LocalImage!.UnmarkedPng, await File.ReadAllBytesAsync(saved.ImagePath!));
            Check.Equal(0, (await store.LoadAsync()).Single().Tags.Length); Check.Sequence(bytes, await File.ReadAllBytesAsync(file + ".backup"));
        }));
        tests.Add(("assets.corrupt-file-preserved", async () =>
        {
            using var temp = new Temp(); var file = Path.Combine(temp.Path, "assets.json"); await File.WriteAllTextAsync(file, "broken");
            var store = new JsonAssetStore(temp.Path);
            await Check.ThrowsAsync(() => store.LoadAsync());
            await Check.ThrowsAsync(() => store.SaveColorAsync(Guid.NewGuid(), new(1, 2, 3, "test"), "", "", default));
            Check.Equal("broken", await File.ReadAllTextAsync(file));
        }));
        tests.Add(("assets.no-silent-record-cap", async () =>
        {
            using var temp = new Temp(); var store = new JsonAssetStore(temp.Path);
            await Task.WhenAll(Enumerable.Range(0, 80).Select(i => store.SaveColorAsync(Guid.NewGuid(), new((byte)i, 2, 3, "test"), "", "", default)));
            Check.Equal(80, (await store.LoadAsync()).Count); Check.Equal(80, (await new JsonAssetStore(temp.Path).LoadAsync()).Count);
        }));
        tests.Add(("settings-clone-latest-order-and-validation", async () =>
        {
            using var temp = new Temp(); var store = new JsonWheelSettingsStore(Path.Combine(temp.Path, "wheel.json"));
            Check.True((await store.LoadAsync()).IsValid);
            var source = new WheelSettings([ActionKind.Explain], new() { [ActionKind.Explain] = new(1, 2, 3) });
            var save = store.SaveAsync(source); source.Slots[0] = ActionKind.Rewrite; source.Colors.Clear(); await save;
            var loaded = await store.LoadAsync(); Check.Equal(ActionKind.Explain, loaded.Slots[0]!.Value); Check.Equal((byte)1, loaded.Colors[ActionKind.Explain].Red);
            var pending = Enumerable.Range(1, 8).Select(count => store.SaveAsync(new(Enumerable.Repeat<ActionKind?>(ActionKind.Save, count).ToArray(), []))).ToArray();
            await Task.WhenAll(pending); Check.Equal(8, (await store.LoadAsync()).Slots.Length);
            var original = await File.ReadAllBytesAsync(Path.Combine(temp.Path, "wheel.json"));
            Check.True(!await store.SaveAsync(new([], []))); Check.Sequence(original, await File.ReadAllBytesAsync(Path.Combine(temp.Path, "wheel.json")));
        }));
        tests.Add(("geometry-center-top-clockwise-dpi-empty-slot", () =>
        {
            var anchor = Fixtures.Anchor(scale: 2); var settings = WheelSettings.Default;
            var snapshot = WheelGeometry.Create(anchor, settings, [new(0, 0, 2000, 2000)]);
            Check.Equal(anchor.Point, snapshot.Anchor.Point); Check.Equal<int?>(null, WheelGeometry.HitTest(snapshot, new(500, 450)));
            Check.Equal<int?>(0, WheelGeometry.HitTest(snapshot, new(500, 300))); Check.Equal<int?>(1, WheelGeometry.HitTest(snapshot, new(1000, 500)));
            Check.Equal<int?>(2, WheelGeometry.HitTest(snapshot, new(500, 1000))); Check.Equal<int?>(3, WheelGeometry.HitTest(snapshot, new(0, 500)));
            var empty = WheelGeometry.Create(anchor, new([null], []), [new(0, 0, 2000, 2000)]);
            Check.Equal<int?>(0, WheelGeometry.HitTest(empty, new(1000, 500))); Check.Equal<ActionKind?>(null, WheelGeometry.ActionAt(empty, new(1000, 500)));
            return Task.CompletedTask;
        }));
        tests.Add(("geometry-edge-fan-nearest-exterior-angle", () =>
        {
            var anchor = Fixtures.Anchor(x: 2, y: 2); var snapshot = WheelGeometry.Create(anchor, WheelSettings.Default, [new(0, 0, 1000, 1000)]);
            Check.Equal(anchor.Point, snapshot.Anchor.Point); Check.Equal(4, snapshot.Slots.Count);
            foreach (var slot in snapshot.Slots)
            {
                var visible = new ScreenPoint(anchor.Point.X + Math.Cos(slot.Mid) * 83, anchor.Point.Y - Math.Sin(slot.Mid) * 83);
                Check.True(snapshot.Screens[0].Contains(visible)); Check.Equal<int?>(slot.Index, WheelGeometry.HitTest(snapshot, visible));
            }
            Check.True(WheelGeometry.HitTest(snapshot, new(-1000, -1000)).HasValue);
            return Task.CompletedTask;
        }));
    }
}
