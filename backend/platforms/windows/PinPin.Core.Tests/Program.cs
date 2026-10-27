using PinPin.Core;
using PinPin.Core.Tests;

var tests = new List<(string Name, Func<Task> Run)>();
StoreTests.Register(tests); GatewayTests.Register(tests); CoordinatorTests.Register(tests); ReplyCoachingTests.Register(tests);
int failed = 0;
foreach (var (name, run) in tests)
{
    try { await run(); Console.WriteLine($"PASS {name}"); }
    catch (Exception error) { failed++; Console.Error.WriteLine($"FAIL {name}: {error}"); }
}
Console.WriteLine($"RESULT {tests.Count - failed}/{tests.Count} passed; {failed} failed");
return failed == 0 ? 0 : 1;

namespace PinPin.Core.Tests
{
    internal static class Check
    {
        public static void True(bool value, string message = "Assertion failed") { if (!value) throw new Exception(message); }
        public static void Equal<T>(T expected, T actual) { if (!EqualityComparer<T>.Default.Equals(expected, actual)) throw new Exception($"Expected {expected}; actual {actual}"); }
        public static void Sequence<T>(IEnumerable<T> expected, IEnumerable<T> actual) { if (!expected.SequenceEqual(actual)) throw new Exception($"Expected [{string.Join(",", expected)}]; actual [{string.Join(",", actual)}]"); }
        public static async Task ThrowsAsync(Func<Task> action)
        { try { await action(); } catch { return; } throw new Exception("Expected operation to fail"); }
        public static async Task Eventually(Func<bool> condition)
        { using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5)); while (!condition()) await Task.Delay(5, timeout.Token); }
    }
    internal sealed class Temp : IDisposable
    {
        public string Path { get; } = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "pinpin-core-tests-" + Guid.NewGuid().ToString("N"));
        public Temp() { Directory.CreateDirectory(Path); }
        public void Dispose() { if (Directory.Exists(Path)) Directory.Delete(Path, true); }
    }
    internal static class Fixtures
    {
        public static TargetAnchor Anchor(Guid? id = null, double x = 500, double y = 500, double scale = 1) =>
            new(id ?? Guid.NewGuid(), new(x, y), 0, 0, new(0, 0, 1000, 1000), scale);
        public static ImageEvidence Image() => new([1, 2, 3, 4], [0xff, 0xd8, 0x42, 0xff, 0xd9], 64, 64,
            new(.25, .75), new(.2, .7), new(100, 200, 64, 64));
        public static PromptContext Context(CapturedEvidence evidence) => new(evidence.SelectedText, evidence.SurroundingText, evidence.LocalImage, evidence.AppName, evidence.WindowTitle);
        public static CapturedEvidence Capture(TargetAnchor? anchor = null, string text = "", bool image = true,
            Func<CancellationToken, Task<ImageEvidence?>>? expand = null, Action? release = null) =>
            new(anchor ?? Anchor(), text, "", "TestApp", "TestWindow", image ? Image() : null, expand, release);
    }
}
