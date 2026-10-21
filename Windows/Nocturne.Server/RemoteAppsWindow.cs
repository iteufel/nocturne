using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Nocturne.Host;
namespace Nocturne.Server;

internal sealed class RemoteAppsWindow : Window
{
    private readonly ClientInvitation invitation;
    private readonly ClientCredentials identity;
    private readonly Action<ClientInvitation> save;
    private readonly Action<RemoteAppWindow> open;
    private readonly ListBox applications = new() { DisplayMemberPath = "Name", MinHeight = 160, Foreground = Brushes.Black };
    private readonly ListBox windows = new() { DisplayMemberPath = "Title", MinHeight = 120, Foreground = Brushes.Black };
    private readonly TextBlock status = new() { Margin = new(0, 10, 0, 10) };
    private readonly Image icon = new() { Width = 48, Height = 48, Margin = new(0, 0, 12, 0) };
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromSeconds(3) };
    private readonly CancellationTokenSource lifetime = new();
    private WorkspaceClient? client;
    private bool busy;
    public string ServerId => invitation.Id;
    public RemoteAppsWindow(ClientInvitation invitation, ClientCredentials identity, Action<ClientInvitation> save, Action<RemoteAppWindow> open)
    {
        this.invitation = invitation; this.identity = identity; this.save = save; this.open = open;
        Title = invitation.Name + " · Apps"; Width = 880; Height = 700; MinWidth = 600; MinHeight = 460;
        SetResourceReference(StyleProperty, typeof(Window));
        var root = new DockPanel { Margin = new(24) };
        root.SetResourceReference(Panel.BackgroundProperty, "Canvas");
        var title = new TextBlock { Text = "Apps on " + invitation.Name, FontSize = 28, Margin = new(0, 0, 0, 16) }; DockPanel.SetDock(title, Dock.Top); root.Children.Add(title);
        DockPanel.SetDock(status, Dock.Bottom); root.Children.Add(status);
        var actions = new WrapPanel { Margin = new(0, 12, 0, 8) }; DockPanel.SetDock(actions, Dock.Bottom);
        void Action(string label, Func<Task> action)
        { var button = new Button { Content = label, Margin = new(0, 0, 12, 0) }; button.Click += async (_, _) => await RunAsync(action); actions.Children.Add(button); }
        Action("Open selected window", () => { if (windows.SelectedItem is RemoteAppWindow window) open(window); return Task.CompletedTask; });
        Action("Launch selected app", LaunchAsync); Action("Refresh", () => RefreshAsync(true)); root.Children.Add(actions);
        var content = new Grid(); content.ColumnDefinitions.Add(new()); content.ColumnDefinitions.Add(new() { Width = new(24) }); content.ColumnDefinitions.Add(new());
        var appPanel = new DockPanel(); var heading = new StackPanel { Orientation = Orientation.Horizontal, Margin = new(0, 0, 0, 12) };
        heading.Children.Add(icon); heading.Children.Add(new TextBlock { Text = "Applications", FontSize = 18, VerticalAlignment = VerticalAlignment.Center }); DockPanel.SetDock(heading, Dock.Top); appPanel.Children.Add(heading); appPanel.Children.Add(applications); content.Children.Add(appPanel);
        var windowPanel = new DockPanel(); var windowHeading = new TextBlock { Text = "Open windows", FontSize = 18, Margin = new(0, 0, 0, 30) }; DockPanel.SetDock(windowHeading, Dock.Top); windowPanel.Children.Add(windowHeading); windowPanel.Children.Add(windows); Grid.SetColumn(windowPanel, 2); content.Children.Add(windowPanel);
        root.Children.Add(content); Content = root;
        windows.MouseDoubleClick += async (_, _) => await RunAsync(() => { if (windows.SelectedItem is RemoteAppWindow window) open(window); return Task.CompletedTask; });
        applications.MouseDoubleClick += async (_, _) => await RunAsync(LaunchAsync);
        applications.SelectionChanged += async (_, _) => await LoadIconAsync();
        timer.Tick += async (_, _) => await RunAsync(() => RefreshAsync(false));
        Loaded += async (_, _) => await RunAsync(ConnectAsync);
        Closed += (_, _) => { lifetime.Cancel(); timer.Stop(); if (client != null) _ = client.DisposeAsync(); };
    }
    private async Task RunAsync(Func<Task> action)
    {
        if (busy || lifetime.IsCancellationRequested) return; busy = true;
        try { await action(); status.Text = "Double-click an app to launch it, or a window to stream it."; }
        catch (Exception error) { if (!lifetime.IsCancellationRequested) status.Text = error.Message; }
        finally { busy = false; }
    }
    private async Task ConnectAsync()
    {
        status.Text = "Connecting…";
        var connected = await WorkspaceClient.ConnectAsync(invitation, identity, Environment.MachineName, lifetime.Token);
        if (lifetime.IsCancellationRequested) { await connected.DisposeAsync(); return; }
        client = connected;
        if (!connected.Capabilities.Contains("app-windows-v1")) throw new IOException("Enable Screen sharing and update Nocturne on the host to browse apps.");
        save(connected.Invitation); await RefreshAsync(true); timer.Start();
    }
    private async Task RefreshAsync(bool catalog)
    {
        if (client == null) return;
        var reply = await client.RequestAsync(new("appList"), lifetime.Token, 30);
        var selected = (windows.SelectedItem as RemoteAppWindow)?.Id;
        if (reply.Windows?.Length > 256) throw new IOException("Invalid window list.");
        windows.ItemsSource = reply.Windows ?? []; windows.SelectedItem = (reply.Windows ?? []).FirstOrDefault(window => window.Id == selected);
        if (!catalog) return;
        var all = new List<RemoteApplication>();
        while (true)
        {
            all.AddRange(reply.Applications ?? []);
            if (all.Count > 4096) throw new IOException("The host sent too many applications.");
            if (reply.Eof != false) break;
            if (reply.Offset == null || reply.Offset <= 0 || reply.Offset != all.Count) throw new IOException("Invalid application page.");
            reply = await client.RequestAsync(new("appList") { Offset = reply.Offset }, lifetime.Token, 30);
        }
        applications.ItemsSource = all;
    }
    private async Task LaunchAsync()
    {
        if (client == null || applications.SelectedItem is not RemoteApplication application) return;
        var reply = await client.RequestAsync(new("appLaunch") { ApplicationID = application.Id }, lifetime.Token, 30);
        windows.ItemsSource = reply.Windows ?? [];
        if (reply.Windows?.Length > 0) windows.SelectedIndex = 0;
        else await RefreshAsync(false);
    }
    private async Task LoadIconAsync()
    {
        if (client == null || applications.SelectedItem is not RemoteApplication selected) return;
        icon.Source = null;
        try
        {
            var reply = await client.RequestAsync(new("appIcon") { ApplicationID = selected.Id }, lifetime.Token);
            if (applications.SelectedItem as RemoteApplication != selected || reply.Data is not { Length: > 0 and <= 262144 }) return;
            using var stream = new MemoryStream(reply.Data);
            var bitmap = new BitmapImage(); bitmap.BeginInit(); bitmap.CacheOption = BitmapCacheOption.OnLoad;
            bitmap.DecodePixelWidth = 96; bitmap.DecodePixelHeight = 96;
            bitmap.StreamSource = stream; bitmap.EndInit(); bitmap.Freeze(); icon.Source = bitmap;
        }
        catch (Exception error) when (error is IOException or OperationCanceledException or NotSupportedException) { }
    }
}
