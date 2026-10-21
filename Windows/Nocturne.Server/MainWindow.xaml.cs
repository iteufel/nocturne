using System.ComponentModel;
using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Microsoft.Win32;
using Nocturne.Host;
using QRCoder;

namespace Nocturne.Server;

public partial class MainWindow : Window
{
    private readonly ServerModel model;
    private bool closing;
    private readonly ComputerModel computers;
    private UserPreferences preferences;
    internal bool KeepAlive { get; set; }
    internal bool WelcomeCompleted => preferences.WelcomeCompleted;
    public MainWindow() : this(new ServerModel()) { }
    internal MainWindow(ServerModel model)
    {
        this.model = model; preferences = UserPreferences.Load(model.Storage); preferences.Apply(); computers = new(model.Storage);
        InitializeComponent(); DataContext = model; ComputersPanel.DataContext = computers;
        AppearancePicker.ItemsSource = new[] { "System", "Light", "Dark" }; AppearancePicker.SelectedItem = preferences.Appearance;
    }
    internal Task InitializeHostAsync() => model.RunAsync(model.InitializeAsync);
    private void Navigate(object sender, RoutedEventArgs e)
    {
        var selected = (string)((Button)sender).Tag;
        foreach (var panel in new[] { Overview, ComputersPanel, GeneralPanel, Sharing, DisplaysPanel, RemotePanel, Devices }) panel.Visibility = panel.Name == selected ? Visibility.Visible : Visibility.Collapsed;
        MainScroll.ScrollToTop();
    }
    private async void ToggleServer(object sender, RoutedEventArgs e) => await model.RunAsync(model.Running ? model.StopAsync : model.StartAsync);
    private async void SaveSettings(object sender, RoutedEventArgs e) => await model.RunAsync(model.ApplySettingsAsync);
    private void DiscardSettings(object sender, RoutedEventArgs e) => model.DiscardSettings();
    private async void RefreshHardware(object sender, RoutedEventArgs e) => await model.RunAsync(model.RefreshHardwareAsync);
    private async void RestoreDisplays(object sender, RoutedEventArgs e) => await model.RunAsync(model.RecoverDisplaysAsync);
    private void ControllerSetup(object sender, RoutedEventArgs e) => Process.Start(new ProcessStartInfo("https://docs.lizardbyte.dev/projects/sunshine/latest/md_docs_2getting__started.html") { UseShellExecute = true });
    private void DriverSetup(object sender, RoutedEventArgs e) => Process.Start(new ProcessStartInfo("https://github.com/VirtualDrivers/Virtual-Driver-Control/releases") { UseShellExecute = true });
    private async void ConfigureDisplayDriver(object sender, RoutedEventArgs e) => await model.RunAsync(async () =>
    {
        await model.StopAsync();
        var script = System.IO.Path.Combine(AppContext.BaseDirectory, "configure-windows-display.ps1");
        if (!System.IO.File.Exists(script)) throw new System.IO.IOException("The display setup helper is missing. Install the complete Windows package.");
        using var process = Process.Start(new ProcessStartInfo("powershell.exe")
        {
            UseShellExecute = true, Verb = "runas", ArgumentList = { "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", script,
                "-UserSid", System.Security.Principal.WindowsIdentity.GetCurrent().User!.Value }
        }) ?? throw new System.IO.IOException("Display setup could not start.");
        await process.WaitForExitAsync();
        if (process.ExitCode != 0) throw new System.IO.IOException("Display setup did not complete. Install the driver and retry.");
        await model.RefreshHardwareAsync();
    });
    private void ChooseFolder(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFolderDialog { Title = "Choose the folder to share", Multiselect = false };
        if (dialog.ShowDialog(this) == true) model.SharedFolder = dialog.FolderName;
    }
    private async void RemoveDevice(object sender, RoutedEventArgs e)
    {
        var device = (DeviceRow)((Button)sender).Tag;
        if (MessageBox.Show(this, $"Remove {device.Name}? Its streams, terminals, and file transfers will close.", "Remove device", MessageBoxButton.OKCancel, MessageBoxImage.Question) == MessageBoxResult.OK)
            await model.RunAsync(() => model.RemoveAsync(device));
    }
    private async void OpenLog(object sender, RoutedEventArgs e) => await model.RunAsync(() =>
    {
        var path = ((Button)sender).Tag is string value && value == "engine" ? model.EngineLogPath : model.LogPath;
        if (!System.IO.File.Exists(path)) throw new System.IO.IOException("Start the server once to create its log.");
        Process.Start(new ProcessStartInfo("notepad.exe") { ArgumentList = { path }, UseShellExecute = false });
        return Task.CompletedTask;
    });

    private async void PairDevice(object sender, RoutedEventArgs e) => await model.RunAsync(() =>
    {
        var addresses = HostStorage.NetworkAddresses();
        if (addresses.Length == 0) throw new System.IO.IOException("Connect this PC to your local network, then try pairing again.");
        var window = new Window { Title = "Pair a device", Owner = this, Width = 550, Height = 760, MinWidth = 500, MinHeight = 720, WindowStartupLocation = WindowStartupLocation.CenterOwner, ResizeMode = ResizeMode.NoResize };
        var content = new StackPanel { Margin = new Thickness(30) };
        content.Children.Add(new TextBlock { Text = "Bring your workspace along.", FontFamily = new FontFamily("Bahnschrift"), FontSize = 25, Margin = new Thickness(0, 0, 0, 10) });
        content.Children.Add(new TextBlock { Text = "Scan with iPhone or iPad. On another computer, use Computers → Add host and paste a pairing code.", Margin = new Thickness(0, 0, 0, 18) });
        var address = new ComboBox { ItemsSource = addresses, SelectedIndex = 0, Margin = new Thickness(0, 0, 0, 18), Padding = new Thickness(8), Foreground = Brushes.Black };
        System.Windows.Automation.AutomationProperties.SetName(address, "PC network address");
        content.Children.Add(address);
        string? pairingCode = null;
        var image = new Image { Width = 330, Height = 330, SnapsToDevicePixels = true };
        RenderOptions.SetBitmapScalingMode(image, BitmapScalingMode.NearestNeighbor);
        content.Children.Add(image);
        var caption = new TextBlock { Text = "One device · expires in 5:00", Margin = new Thickness(0, 18, 0, 10), HorizontalAlignment = HorizontalAlignment.Center };
        content.Children.Add(caption);
        var copy = new Button { Content = "Copy pairing code", Margin = new Thickness(0, 8, 0, 0) };
        copy.Click += (_, _) => { if (pairingCode != null && model.HasInvitation) Clipboard.SetText(pairingCode); };
        content.Children.Add(copy);
        var close = new Button { Content = "Done", Margin = new Thickness(0, 10, 0, 0), IsCancel = true };
        close.Click += (_, _) => window.Close(); content.Children.Add(close);
        var expires = DateTimeOffset.UtcNow.AddMinutes(5);
        var timer = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
        void UpdateCode()
        {
            var invitation = model.CreateInvitation((string)address.SelectedItem); pairingCode = invitation;
            using var generator = new QRCodeGenerator();
            using var data = generator.CreateQrCode(invitation, QRCodeGenerator.ECCLevel.M);
            using var qr = new PngByteQRCode(data);
            using var stream = new System.IO.MemoryStream(qr.GetGraphic(8));
            var bitmap = new BitmapImage(); bitmap.BeginInit(); bitmap.CacheOption = BitmapCacheOption.OnLoad; bitmap.StreamSource = stream; bitmap.EndInit(); bitmap.Freeze(); image.Source = bitmap;
            expires = DateTimeOffset.UtcNow.AddMinutes(5);
            timer.Start();
        }
        address.SelectionChanged += (_, _) => UpdateCode(); UpdateCode();
        timer.Tick += (_, _) =>
        {
            if (!model.Running)
            {
                image.Source = null;
                caption.Text = "Server stopped. Close this window to continue.";
                timer.Stop(); return;
            }
            var remaining = expires - DateTimeOffset.UtcNow;
            if (remaining <= TimeSpan.Zero) { image.Source = null; caption.Text = "Code expired. Close and choose Pair a device again."; model.CancelInvitation(); timer.Stop(); }
            else if (!model.HasInvitation) { image.Source = null; caption.Text = "Device paired. You can close this window."; timer.Stop(); }
            else caption.Text = $"One device · expires in {remaining.Minutes}:{remaining.Seconds:00}";
        };
        window.Content = content; timer.Start();
        try { window.ShowDialog(); }
        finally { timer.Stop(); image.Source = null; model.CancelInvitation(); }
        return Task.CompletedTask;
    });

    internal void Reveal() { Show(); if (WindowState == WindowState.Minimized) WindowState = WindowState.Normal; Activate(); }
    internal void ShowPairing() { Reveal(); PairDevice(this, new()); }
    internal void RestoreScreens() { Reveal(); RestoreDisplays(this, new()); }
    internal void ShowWelcome() { Reveal(); ShowWelcomeDialog(); }
    private void ReplayWelcome(object sender, RoutedEventArgs e) => ShowWelcome();
    internal void AddComputer()
    {
        Reveal();
        var dialog = new Window { Title = "Add host", Owner = this, Width = 560, Height = 340, ResizeMode = ResizeMode.NoResize, WindowStartupLocation = WindowStartupLocation.CenterOwner };
        var content = new StackPanel { Margin = new(28) };
        content.Children.Add(new TextBlock { Text = "Another computer, within reach.", FontSize = 23, Margin = new(0, 0, 0, 14) });
        content.Children.Add(new TextBlock { Text = "Copy a pairing code from Pair a device on the other computer. This code grants access to that computer.", Margin = new(0, 0, 0, 14) });
        var code = new PasswordBox { Padding = new(10), Margin = new(0, 0, 0, 16) }; System.Windows.Automation.AutomationProperties.SetName(code, "Pairing code"); content.Children.Add(code);
        var buttons = new WrapPanel(); var paste = new Button { Content = "Paste", Margin = new(0, 0, 12, 0) }; paste.Click += (_, _) => { if (Clipboard.ContainsText()) code.Password = Clipboard.GetText(); }; buttons.Children.Add(paste);
        var connect = new Button { Content = "Add & connect", IsDefault = true }; connect.Click += (_, _) => { var value = code.Password; if (TryComputer(() => computers.Add(value))) dialog.Close(); }; buttons.Children.Add(connect);
        content.Children.Add(buttons); dialog.Content = content; dialog.ShowDialog();
    }
    internal void OpenComputerCode(string code) => TryComputer(() => computers.Add(code));
    private bool TryComputer(Action action) { try { action(); return true; } catch (Exception error) { MessageBox.Show(this, error.Message, "Nocturne"); return false; } }
    private void AddHost(object sender, RoutedEventArgs e) => AddComputer();
    private void ConnectComputer(object sender, RoutedEventArgs e) => TryComputer(() => computers.Connect((string)((Button)sender).Tag));
    private void BrowseComputer(object sender, RoutedEventArgs e) => TryComputer(() => computers.Browse((string)((Button)sender).Tag));
    private void ForgetComputer(object sender, RoutedEventArgs e)
    {
        if (MessageBox.Show(this, "Forget this computer? You can pair it again with a new code.", "Forget host", MessageBoxButton.OKCancel) == MessageBoxResult.OK)
            TryComputer(() => computers.Forget((string)((Button)sender).Tag));
    }
    private async void ResetPairing(object sender, RoutedEventArgs e)
    {
        if (MessageBox.Show(this, "Remove every paired device and replace this PC’s pairing keys? All current sessions will disconnect. Pair your devices again afterward.", "Reset all pairings", MessageBoxButton.OKCancel, MessageBoxImage.Warning) == MessageBoxResult.OK)
            await model.RunAsync(model.ResetPairingAsync);
    }
    private void AppearanceChanged(object sender, SelectionChangedEventArgs e)
    {
        if (AppearancePicker.SelectedItem is not string appearance) return;
        preferences = preferences with { Appearance = appearance }; preferences.Save(model.Storage); preferences.Apply();
    }
    internal void RefreshAppearance() => preferences.Apply();
    private void OpenSharedFolder(object sender, RoutedEventArgs e) => TryComputer(() => Process.Start(new ProcessStartInfo("explorer.exe") { UseShellExecute = false, ArgumentList = { model.SharedFolder } }));
    private async void ConfigureFirewall(object sender, RoutedEventArgs e) => await model.RunAsync(async () =>
    {
        using var process = Process.Start(new ProcessStartInfo("powershell.exe") { UseShellExecute = true, Verb = "runas", ArgumentList = { "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", System.IO.Path.Combine(AppContext.BaseDirectory, "configure-windows-firewall.ps1") } })
            ?? throw new System.IO.IOException("Network setup could not start.");
        await process.WaitForExitAsync(); if (process.ExitCode != 0) throw new System.IO.IOException("Network setup did not complete.");
    });
    private async void QuitApplication(object sender, RoutedEventArgs e) => await QuitAsync();
    internal async Task QuitAsync()
    {
        if (closing) return;
        closing = true; KeepAlive = false; computers.Close();
        try { await model.CloseAsync(); }
        finally { Close(); Application.Current.Shutdown(); }
    }
    private void ShowWelcomeDialog()
    {
        var dialog = new WelcomeWindow(this, () => { preferences = preferences with { WelcomeCompleted = true }; preferences.Save(model.Storage); }); dialog.ShowDialog();
    }
    private async void WindowClosing(object? sender, CancelEventArgs e)
    {
        if (closing) return;
        e.Cancel = true;
        if (KeepAlive) { Hide(); return; }
        if (!model.CanAct) return;
        closing = true;
        computers.Close();
        await model.RunAsync(model.CloseAsync);
        Close();
        if (Application.Current.MainWindow == this) Application.Current.Shutdown();
    }
}
