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
    public MainWindow() : this(new ServerModel()) { }
    internal MainWindow(ServerModel model) { this.model = model; InitializeComponent(); DataContext = model; }
    internal Task InitializeHostAsync() => model.RunAsync(model.InitializeAsync);
    private void Navigate(object sender, RoutedEventArgs e)
    {
        var selected = (string)((Button)sender).Tag;
        foreach (var panel in new[] { Overview, Sharing, DisplaysPanel, RemotePanel, Devices }) panel.Visibility = panel.Name == selected ? Visibility.Visible : Visibility.Collapsed;
    }
    private async void ToggleServer(object sender, RoutedEventArgs e) => await model.RunAsync(model.Running ? model.StopAsync : model.StartAsync);
    private async void SaveSettings(object sender, RoutedEventArgs e) => await model.RunAsync(model.ApplySettingsAsync);
    private void DiscardSettings(object sender, RoutedEventArgs e) => model.DiscardSettings();
    private async void RefreshHardware(object sender, RoutedEventArgs e) => await model.RunAsync(model.RefreshHardwareAsync);
    private async void RestoreDisplays(object sender, RoutedEventArgs e) => await model.RunAsync(model.RecoverDisplaysAsync);
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
        var window = new Window { Title = "Pair a device", Owner = this, Width = 510, Height = 680, MinWidth = 460, MinHeight = 620, WindowStartupLocation = WindowStartupLocation.CenterOwner, ResizeMode = ResizeMode.NoResize };
        var content = new StackPanel { Margin = new Thickness(30) };
        content.Children.Add(new TextBlock { Text = "Bring your workspace along.", FontFamily = new FontFamily("Bahnschrift"), FontSize = 25, Margin = new Thickness(0, 0, 0, 10) });
        content.Children.Add(new TextBlock { Text = "In Nocturne on iPhone or iPad, choose Add host → Scan QR code.", Margin = new Thickness(0, 0, 0, 18) });
        var address = new ComboBox { ItemsSource = addresses, SelectedIndex = 0, Margin = new Thickness(0, 0, 0, 18), Padding = new Thickness(8), Foreground = Brushes.Black };
        System.Windows.Automation.AutomationProperties.SetName(address, "PC network address");
        content.Children.Add(address);
        var image = new Image { Width = 350, Height = 350, SnapsToDevicePixels = true };
        RenderOptions.SetBitmapScalingMode(image, BitmapScalingMode.NearestNeighbor);
        content.Children.Add(image);
        var caption = new TextBlock { Text = "One device · expires in 5:00", Margin = new Thickness(0, 18, 0, 10), HorizontalAlignment = HorizontalAlignment.Center };
        content.Children.Add(caption);
        var close = new Button { Content = "Done", Margin = new Thickness(0, 10, 0, 0), IsCancel = true };
        close.Click += (_, _) => window.Close(); content.Children.Add(close);
        var expires = DateTimeOffset.UtcNow.AddMinutes(5);
        var timer = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
        void UpdateCode()
        {
            var invitation = model.CreateInvitation((string)address.SelectedItem);
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

    private async void WindowClosing(object? sender, CancelEventArgs e)
    {
        if (closing) return;
        e.Cancel = true;
        if (!model.CanAct) return;
        closing = true;
        await model.RunAsync(model.CloseAsync);
        Close();
    }
}
