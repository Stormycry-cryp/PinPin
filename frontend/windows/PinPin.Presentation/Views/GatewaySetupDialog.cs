using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using PinPin.Core;
using PinPin.Presentation.Controls;

namespace PinPin.Presentation;

/// A small local configuration surface. Validation and secure persistence belong to the host.
public static class GatewaySetupDialog
{
    public static bool Show(string initialUrl, Func<GatewaySetupInput, bool> save, Action<nint>? windowCreated = null, string? appearancePath = null)
    {
        ArgumentNullException.ThrowIfNull(save);
        Application.Current.Dispatcher.VerifyAccess();
        using var theme = new Theme(appearancePath);
        var window = new GatewaySetupWindow(theme, initialUrl, save, windowCreated);
        try { window.ShowDialog(); return window.Accepted; }
        finally { window.ClearSensitiveState(); }
    }
}

internal sealed class GatewaySetupWindow : MatteWindow
{
    private Func<GatewaySetupInput, bool>? save;
    private readonly TextBox address;
    private readonly PasswordBox token;
    private readonly TextBlock failure;
    internal bool Accepted { get; private set; }

    internal GatewaySetupWindow(Theme theme, string initialUrl, Func<GatewaySetupInput, bool> save, Action<nint>? windowCreated = null)
        : base("PinPin AI 连接", false, windowCreated ?? (_ => { }))
    {
        this.save = save;
        Width = 360; SizeToContent = SizeToContent.Height;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        EscapePressed = Close;
        var p = theme.Palette;
        var root = new StackPanel { Margin = new Thickness(20) };
        Content = new MatteSurface(p) { WindowFrame = true, Radius = 18, Child = root };
        var header = new DockPanel { Height = 24, Background = Brushes.Transparent, Margin = new Thickness(0, 0, 0, 12) };
        var close = Ui.IconButton(p, "close", "关闭 AI 连接设置", Close);
        DockPanel.SetDock(close, Dock.Right); header.Children.Add(close);
        header.Children.Add(Ui.Label("AI 连接", p, 14, true));
        header.MouseLeftButtonDown += (_, e) => { if (e.LeftButton == MouseButtonState.Pressed) { DragMove(); e.Handled = true; } };
        root.Children.Add(header);
        root.Children.Add(Ui.Label("服务地址", p, 11, ink: p.Secondary));
        address = Ui.Input(p, "服务地址", 12); address.Text = initialUrl ?? "";
        AutomationProperties.SetAutomationId(address, "gateway-address");
        var addressWell = Ui.InputWell(p, address, 8, new Thickness(10, 5, 10, 5));
        addressWell.Height = 32; addressWell.Margin = new Thickness(0, 6, 0, 12); root.Children.Add(addressWell);
        root.Children.Add(Ui.Label("访问令牌", p, 11, ink: p.Secondary));
        token = new PasswordBox { FontFamily = Theme.Font, FontSize = 12, Foreground = p.Ink,
            Background = Brushes.Transparent, BorderThickness = new Thickness(0), Padding = new Thickness(0),
            VerticalContentAlignment = VerticalAlignment.Center, CaretBrush = p.Ink,
            SelectionBrush = p.Accent, FocusVisualStyle = null };
        Theme.Typography(token);
        AutomationProperties.SetName(token, "访问令牌"); AutomationProperties.SetAutomationId(token, "gateway-token");
        var tokenWell = Ui.InputWell(p, token, 8, new Thickness(10, 5, 10, 5));
        tokenWell.Height = 32; tokenWell.Margin = new Thickness(0, 6, 0, 0); root.Children.Add(tokenWell);
        failure = Ui.Text("", p, 11, ink: p.Secondary); failure.Margin = new Thickness(0, 8, 0, 0);
        failure.MinHeight = 16; root.Children.Add(failure);
        var actions = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right,
            Margin = new Thickness(0, 12, 0, 0) };
        var later = Ui.Pill(p, "稍后设置", Close, height: 28); later.Margin = new Thickness(0, 0, 10, 0);
        AutomationProperties.SetAutomationId(later, "gateway-later"); actions.Children.Add(later);
        var commit = Ui.Pill(p, "保存", Save, height: 28); commit.MinWidth = 70;
        commit.Graphite = true; ((TextBlock)commit.Content).Foreground = p.OnAccent;
        AutomationProperties.SetAutomationId(commit, "gateway-save"); actions.Children.Add(commit); root.Children.Add(actions);
        token.KeyDown += (_, e) => { if (e.Key == Key.Enter) { Save(); e.Handled = true; } };
        Loaded += (_, _) => { if (string.IsNullOrWhiteSpace(address.Text)) address.Focus(); else token.Focus(); };
        Closed += (_, _) => ClearSensitiveState();
    }

    private void Save()
    {
        using (var secure = token.SecurePassword)
        {
            if (string.IsNullOrWhiteSpace(address.Text) || secure.Length == 0)
            { failure.Text = "请填写服务地址和访问令牌。"; return; }
        }
        // The short-lived input crosses only this explicit save callback. No logging or network.
        bool saved = save?.Invoke(new GatewaySetupInput(address.Text.Trim(), token.Password)) == true;
        if (!saved) { failure.Text = "没能保存，请检查地址、令牌和本地写入权限。"; return; }
        Accepted = true; ClearSensitiveState(); Close();
    }

    internal void ClearSensitiveState()
    { token.Clear(); save = null; }
}
