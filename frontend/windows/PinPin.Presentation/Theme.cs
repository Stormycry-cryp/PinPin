using System.ComponentModel;
using System.IO;
using System.Windows;
using System.Windows.Media;
using System.Windows.Markup;
using Microsoft.Win32;
using PinPin.Core;

namespace PinPin.Presentation;

/// Mac v4.4 tokens. All drawing resources are immutable and reused until the theme changes.
internal sealed class Theme : IDisposable
{
    private readonly string? preferencePath;
    private readonly object writeGate = new();
    private int writeRevision;
    private bool explicitChoice;
    public bool Dark { get; private set; }
    public bool HighContrast => SystemParameters.HighContrast;
    public bool ReduceMotion => !SystemParameters.ClientAreaAnimation;
    public event Action? Changed;
    public event Action<string>? SaveFailed;
    public Palette Palette { get; private set; }
    // Chinese UI text and adjacent Latin/numerals share one set of metrics. The Windows
    // UI variant has tighter line metrics than the document-oriented YaHei fallback.
    public static readonly FontFamily Font = new("Microsoft YaHei UI, Microsoft YaHei, Segoe UI");
    public static readonly XmlLanguage TextLanguage = XmlLanguage.GetLanguage("zh-CN");
    public static readonly FontFamily MonoFont = new("Consolas, Microsoft YaHei UI");

    public static void Typography(FrameworkElement element)
    {
        element.Language = TextLanguage;
        TextOptions.SetTextFormattingMode(element, TextFormattingMode.Ideal);
        // These windows use per-pixel transparency; grayscale keeps glyph edges neutral.
        TextOptions.SetTextRenderingMode(element, TextRenderingMode.Grayscale);
    }

    public Theme(string? preferencePath)
    {
        this.preferencePath = preferencePath;
        string? saved = null;
        try { if (preferencePath is not null && File.Exists(preferencePath)) saved = File.ReadAllText(preferencePath).Trim(); }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
        explicitChoice = saved is "light" or "dark";
        Dark = explicitChoice ? saved == "dark" : SystemDark();
        Palette = new(Dark, HighContrast);
        SystemParameters.StaticPropertyChanged += SystemChanged;
    }

    private static bool SystemDark()
    {
        using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
        return key?.GetValue("AppsUseLightTheme") is int value && value == 0;
    }

    private void SystemChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (!explicitChoice) Dark = SystemDark();
        Palette = new(Dark, HighContrast);
        Changed?.Invoke();
    }

    public async void Toggle()
    {
        explicitChoice = true;
        Dark = !Dark;
        Palette = new(Dark, HighContrast);
        Changed?.Invoke();
        if (preferencePath is null) return;
        int revision = Interlocked.Increment(ref writeRevision);
        string value = Dark ? "dark" : "light";
        try
        {
            await Task.Run(() =>
            {
                lock (writeGate)
                {
                    if (revision != writeRevision) return;
                    var directory = Path.GetDirectoryName(Path.GetFullPath(preferencePath))!;
                    Directory.CreateDirectory(directory);
                    string temporary = preferencePath + ".tmp";
                    File.WriteAllText(temporary, value);
                    File.Move(temporary, preferencePath, true);
                }
            });
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        { if (revision == writeRevision) SaveFailed?.Invoke("没能保存外观"); }
    }

    public void Dispose() => SystemParameters.StaticPropertyChanged -= SystemChanged;
}

internal sealed class Palette
{
    public readonly bool Dark, HighContrast;
    public readonly SolidColorBrush Surface, Well, Ink, Secondary, Tertiary, Hairline, Accent, OnAccent, LightEdge, DarkEdge;
    public readonly Pen HairlinePen;
    public readonly LinearGradientBrush Bevel;
    private readonly Dictionary<(ActionKind, byte, byte, byte), SolidColorBrush> featureCache = [];
    public static readonly uint[] Swatches = [0x2E5E9E, 0x6A4A9E, 0xA2365C, 0xA53D2E, 0x8A5410, 0x4A6619, 0x1B675C, 0x4A4A4F];
    private static readonly uint[] DarkSwatches = [0x8DB2E6, 0xB6A0E6, 0xE98BAA, 0xEE9484, 0xDDA65A, 0xA8C56C, 0x6CC2B3, 0xC0C0C5];
    private static readonly uint[] LightHigh = [0x1F4A82, 0x553782, 0x852746, 0x872E22, 0x6E420A, 0x3D5615, 0x135A50, 0x303034];
    private static readonly uint[] DarkHigh = [0xAECBF2, 0xCBBAF2, 0xF2AEC5, 0xF4B3A8, 0xEBC083, 0xC1D791, 0x92D6CA, 0xDADADF];

    public Palette(bool dark, bool highContrast)
    {
        Dark = dark; HighContrast = highContrast;
        Surface = Brush(dark ? 0x2C2C2Fu : 0xE5E5E8u);
        Well = Brush(dark ? (highContrast ? 0x222225u : 0x252528u) : (highContrast ? 0xD5D5DAu : 0xDCDCE0u));
        Ink = Brush(dark ? (highContrast ? 0xF5F5F7u : 0xECECEFu) : (highContrast ? 0x111113u : 0x1D1D1Fu));
        Secondary = Brush(dark ? (highContrast ? 0xD1D1D6u : 0xB6B6BBu) : (highContrast ? 0x2E2E31u : 0x48484Du));
        Tertiary = Brush(dark ? (highContrast ? 0xB0B0B5u : 0x949499u) : (highContrast ? 0x48484Du : 0x606065u));
        Hairline = Alpha(dark ? Colors.White : Colors.Black, highContrast ? .45 : .07);
        LightEdge = Alpha(Colors.White, dark ? (highContrast ? .14 : .075) : (highContrast ? 1 : .92));
        DarkEdge = Alpha(Colors.Black, dark ? (highContrast ? .75 : .55) : (highContrast ? .30 : .17));
        Accent = Brush(dark ? (highContrast ? 0x636366u : 0x6E6E73u) : (highContrast ? 0x1C1C1Eu : 0x2C2C2Eu));
        OnAccent = Brush(0xF5F5F7);
        HairlinePen = Pen(Hairline, .5);
        Bevel = new LinearGradientBrush(LightEdge.Color, DarkEdge.Color, new Point(0, 0), new Point(1, 1));
        Bevel.Freeze();
    }

    public static FeatureColor Default(ActionKind action) => ColorValue(Swatches[action switch
    { ActionKind.Explain => 0, ActionKind.Translate => 6, ActionKind.Rewrite => 4, ActionKind.Save => 2, ActionKind.ReplyCoach => 5, _ => 1 }]);
    public static FeatureColor ColorValue(uint hex) => new((byte)(hex >> 16), (byte)(hex >> 8), (byte)hex);
    public SolidColorBrush Feature(ActionKind action, WheelSettings settings)
    {
        FeatureColor c = settings.Colors.GetValueOrDefault(action) ?? Default(action);
        var key = (action, c.Red, c.Green, c.Blue);
        if (featureCache.TryGetValue(key, out var cached)) return cached;
        uint hex = ((uint)c.Red << 16) | ((uint)c.Green << 8) | c.Blue;
        int swatch = Array.IndexOf(Swatches, hex);
        Color color;
        if (swatch >= 0) color = Rgb((Dark ? (HighContrast ? DarkHigh : DarkSwatches) : (HighContrast ? LightHigh : Swatches))[swatch]);
        else
        {
            double mix = Dark ? (HighContrast ? .60 : .45) : (HighContrast ? -.20 : 0);
            byte Blend(byte channel) => (byte)Math.Round(mix >= 0 ? channel + (255 - channel) * mix : channel * (1 + mix));
            color = Color.FromRgb(Blend(c.Red), Blend(c.Green), Blend(c.Blue));
        }
        var brush = new SolidColorBrush(color); brush.Freeze(); featureCache[key] = brush; return brush;
    }
    public static Color Rgb(uint hex) => Color.FromRgb((byte)(hex >> 16), (byte)(hex >> 8), (byte)hex);
    public static SolidColorBrush Brush(uint hex) { var b = new SolidColorBrush(Rgb(hex)); b.Freeze(); return b; }
    public static SolidColorBrush Alpha(Color color, double opacity)
    { var b = new SolidColorBrush(Color.FromArgb((byte)Math.Round(opacity * 255), color.R, color.G, color.B)); b.Freeze(); return b; }
    public static Pen Pen(Brush brush, double thickness) { var p = new Pen(brush, thickness); p.Freeze(); return p; }
}

internal static class FeatureNames
{
    public static readonly ActionKind[] All = [ActionKind.Explain, ActionKind.Translate, ActionKind.Rewrite, ActionKind.Save, ActionKind.PickColor, ActionKind.ReplyCoach];
    public static string Name(ActionKind action) => action switch
    { ActionKind.Explain => "解释", ActionKind.Translate => "翻译", ActionKind.Rewrite => "改写", ActionKind.Save => "收藏", ActionKind.ReplyCoach => "嘴替", _ => "取色器" };
    public static string Prompt(ActionKind action) => action switch
    { ActionKind.Explain => "还有哪里不明白？", ActionKind.Translate => "还想怎么翻译？", ActionKind.ReplyCoach => "想用什么语气回复？", _ => "还想怎么改？" };
}
