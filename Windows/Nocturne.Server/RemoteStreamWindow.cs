using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using System.Threading.Channels;
using Nocturne.Host;

namespace Nocturne.Server;

internal sealed class RemoteStreamWindow : Window
{
    private readonly ClientInvitation invitation;
    private readonly ClientCredentials identity;
    private readonly Action<ClientInvitation> save;
    private readonly RemoteAppWindow? app;
    private readonly Image image = new() { Stretch = Stretch.Uniform, Focusable = true };
    private readonly TextBlock status = new() { Margin = new(16), Padding = new(12), Foreground = Brushes.White,
        Background = new SolidColorBrush(Color.FromArgb(200, 0, 0, 0)), VerticalAlignment = VerticalAlignment.Center, IsHitTestVisible = false };
    private readonly ComboBox displays = new() { MinWidth = 160, MaxWidth = 260, DisplayMemberPath = "Name", SelectedValuePath = "Id", Foreground = Brushes.Black };
    private readonly TextBlock route = new() { Margin = new(12, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
    private readonly DispatcherTimer resize = new() { Interval = TimeSpan.FromMilliseconds(300) };
    private readonly HashSet<ushort> heldKeys = [];
    private readonly HashSet<int> heldButtons = [];
    private readonly SemaphoreSlim configure = new(1);
    private CancellationTokenSource? lifetime;
    private WorkspaceClient? client;
    private NativeReceiver? receiver;
    private Channel<AppInput>? inputs;
    private WriteableBitmap? bitmap;
    private string session = "";
    private uint? displayID;
    private bool ready, selecting, muted, closed;
    private Point pointer;
    private (byte[] Bytes, int Width, int Height)? latest;
    private readonly object frameGate = new();
    private bool framePending;
    private WindowStyle previousStyle;
    private WindowState previousState;
    public string ServerId => invitation.Id;
    internal bool VideoReady => ready;
    internal string StreamStatus => status.Text;
    internal BitmapSource? VideoImage => bitmap;
    private string Operation(string suffix) => (app == null ? "desktop" : "app") + suffix;
    public RemoteStreamWindow(ClientInvitation invitation, ClientCredentials identity, Action<ClientInvitation> save, RemoteAppWindow? app, Action? browseApps = null)
    {
        this.invitation = invitation; this.identity = identity; this.save = save; this.app = app;
        Title = app?.Title ?? invitation.Name; Width = 1280; Height = 800; MinWidth = 640; MinHeight = 400;
        SetResourceReference(StyleProperty, typeof(Window));
        var root = new DockPanel(); root.SetResourceReference(Panel.BackgroundProperty, "Canvas");
        var tools = new WrapPanel { Margin = new(10) }; DockPanel.SetDock(tools, Dock.Top);
        Button Action(string label, Action action)
        {
            var button = new Button { Content = label, Margin = new(0, 0, 8, 0), Padding = new(12, 8, 12, 8) };
            button.Click += (_, _) => action(); tools.Children.Add(button); return button;
        }
        Action("Disconnect", Close); Action("Reconnect", () => _ = ConnectAsync());
        Action("Full screen", ToggleFullscreen);
        Action("Paste text", () => { if (ready && Clipboard.ContainsText()) { var text = Clipboard.GetText(); for (var offset = 0; offset < text.Length; offset += 512) QueueInput(new("text", Text: text.Substring(offset, Math.Min(512, text.Length - offset)))); } });
        if (app == null)
        {
            if (browseApps != null) Action("Apps", browseApps);
            var mute = Action("Mute audio", () => { muted = !muted; if (receiver != null) receiver.Muted = muted; });
            mute.Click += (_, _) => mute.Content = muted ? "Unmute audio" : "Mute audio";
            displays.Margin = new(0, 0, 8, 0); tools.Children.Add(displays);
            displays.SelectionChanged += (_, _) =>
            {
                if (!selecting && displays.SelectedValue is uint id && id != displayID) { displayID = id; _ = ConnectAsync(); }
            };
        }
        tools.Children.Add(route); root.Children.Add(tools);
        var hint = new TextBlock { Text = "Click the picture to control · Ctrl+Alt+Esc releases the keyboard · Close to disconnect", Margin = new(14, 6, 14, 10), FontSize = 12 };
        hint.SetResourceReference(TextBlock.ForegroundProperty, "Muted"); DockPanel.SetDock(hint, Dock.Bottom); root.Children.Add(hint);
        var surface = new Grid { Background = Brushes.Black, ClipToBounds = true }; surface.Children.Add(image); surface.Children.Add(status); root.Children.Add(surface); Content = root;
        image.MouseMove += (_, e) => { if (!ready || !image.IsKeyboardFocused) return; if (Position(e.GetPosition(image), out var point)) { pointer = point; QueueInput(Input("move"), true); } };
        image.MouseDown += (_, e) =>
        {
            if (!ready || !Position(e.GetPosition(image), out var point)) return;
            pointer = point; image.Focus(); image.CaptureMouse(); var button = Button(e.ChangedButton); heldButtons.Add(button);
            QueueInput(Input("down", button) with { ClickCount = Math.Min(3, e.ClickCount) }); e.Handled = true;
        };
        image.MouseUp += (_, e) => { var button = Button(e.ChangedButton); heldButtons.Remove(button); QueueInput(Input("up", button)); if (heldButtons.Count == 0) image.ReleaseMouseCapture(); e.Handled = true; };
        image.MouseWheel += (_, e) => { if (image.IsKeyboardFocused) { QueueInput(Input("scroll") with { DeltaY = -e.Delta / 4.0 }); e.Handled = true; } };
        image.PreviewKeyDown += (_, e) => KeyEvent(e, true); image.PreviewKeyUp += (_, e) => KeyEvent(e, false);
        image.LostKeyboardFocus += (_, _) => ReleaseInput(); Deactivated += (_, _) => ReleaseInput();
        image.SizeChanged += (_, _) => { resize.Stop(); resize.Start(); };
        resize.Tick += async (_, _) => { resize.Stop(); await ResizeAsync(); };
        Loaded += async (_, _) => await ConnectAsync();
        Closed += (_, _) => { closed = true; resize.Stop(); ReleaseInput(); _ = StopAsync(); };
    }
    private async Task ConnectAsync()
    {
        await StopAsync(); if (closed) return;
        var cancellation = new CancellationTokenSource(); lifetime = cancellation;
        status.Text = "Connecting to " + invitation.Name + "…"; status.Visibility = Visibility.Visible;
        try
        {
            var connected = await WorkspaceClient.ConnectAsync(invitation, identity, Environment.MachineName, cancellation.Token);
            if (lifetime != cancellation) { await connected.DisposeAsync(); return; }
            client = connected;
            if (!connected.Capabilities.Contains(app == null ? "desktop-stream-v1" : "app-windows-v1"))
                throw new IOException("Enable Screen sharing and update Nocturne on the other computer, then reconnect.");
            save(connected.Invitation); route.Text = connected.Route;
            session = Guid.NewGuid().ToString(); var viewport = Viewport();
            var nextReceiver = new NativeReceiver(viewport.Pixels().Width, viewport.Pixels().Height) { Muted = muted }; receiver = nextReceiver;
            nextReceiver.Frame += (bytes, width, height) => Present(nextReceiver, bytes, width, height);
            nextReceiver.Failed += error => _ = Dispatcher.BeginInvoke(() => { if (receiver == nextReceiver) Fail(error); });
            nextReceiver.AudioFailed += error => _ = Dispatcher.BeginInvoke(() => { if (receiver == nextReceiver) route.Text = "Audio unavailable · " + error; });
            connected.Media += packet =>
            {
                if (packet.SessionID != session || receiver != nextReceiver) return;
                if (packet.Operation == Operation("Ended")) { _ = Dispatcher.BeginInvoke(() => Fail(new IOException(packet.Error ?? "Sharing ended."))); return; }
                nextReceiver.Receive(packet);
            };
            connected.Disconnected += error => _ = Dispatcher.BeginInvoke(() => { if (client == connected) Fail(error); });
            if (app == null)
            {
                var list = await connected.RequestAsync(new("desktopList"), cancellation.Token, 30);
                if (lifetime != cancellation) return;
                var available = list.Displays ?? [];
                if (available.Length > 64 || available.Any(display => display.Width <= 0 || display.Height <= 0)) throw new IOException("The host sent an invalid display list.");
                selecting = true; displays.ItemsSource = available;
                if (!available.Any(display => display.Id == displayID)) displayID = available.FirstOrDefault(display => display.IsMain)?.Id ?? available.FirstOrDefault()?.Id;
                displays.SelectedValue = displayID; selecting = false;
            }
            var response = await connected.RequestAsync(new(Operation("Open")) { SessionID = session, Viewport = viewport, DisplayID = displayID, ApplicationID = app?.ApplicationID, WindowID = app?.Id }, cancellation.Token, 30);
            if (lifetime != cancellation) return;
            if (response.SessionID != session || response.Display == null || app != null && (response.Window?.Id != app.Id || response.Window.ApplicationID != app.ApplicationID)) throw new IOException("The host sent an invalid stream reply.");
            status.Text = "Waiting for video…";
            inputs = Channel.CreateBounded<AppInput>(128); _ = InputLoop(connected, inputs, cancellation.Token);
            _ = Heartbeat(connected, cancellation.Token);
            _ = FirstFrameDeadline(cancellation);
        }
        catch (Exception error) { if (lifetime == cancellation && !cancellation.IsCancellationRequested) Fail(error); }
    }
    private async Task FirstFrameDeadline(CancellationTokenSource generation)
    {
        try { await Task.Delay(TimeSpan.FromSeconds(12), generation.Token); if (lifetime == generation && !ready) Fail(new IOException("No video arrived. Check capture permission and the host’s display, then reconnect.")); }
        catch (OperationCanceledException) { }
    }
    private async Task Heartbeat(WorkspaceClient connected, CancellationToken cancellation)
    {
        try
        {
            while (!cancellation.IsCancellationRequested)
            {
                await Task.Delay(TimeSpan.FromSeconds(5), cancellation);
                var reply = await connected.RequestAsync(new(Operation("Heartbeat")) { SessionID = session }, cancellation, 8);
                if (client != connected) return;
                route.Text = reply.ScreenLocked == true ? "Host locked · type the host password to unlock" : connected.Route;
            }
        }
        catch (Exception error) { if (!cancellation.IsCancellationRequested && client == connected) Fail(error); }
    }
    private AppViewport Viewport()
    {
        var dpi = VisualTreeHelper.GetDpi(this);
        return new(Math.Clamp((int)image.ActualWidth, 240, 4096), Math.Clamp((int)image.ActualHeight, 160, 4096), Math.Clamp(dpi.DpiScaleX, 1, 3));
    }
    private async Task ResizeAsync()
    {
        if (!ready || client == null || lifetime == null || !configure.Wait(0)) return;
        var connected = client; var cancellation = lifetime.Token;
        try { await connected.RequestAsync(new(Operation("Resize")) { SessionID = session, Viewport = Viewport() }, cancellation, 30); }
        catch (Exception error) { if (!cancellation.IsCancellationRequested && client == connected) Fail(error); }
        finally { configure.Release(); }
    }
    private void Present(NativeReceiver source, byte[] bytes, int width, int height)
    {
        lock (frameGate)
        {
            if (receiver != source || closed) return;
            latest = (bytes, width, height); if (framePending) return; framePending = true;
        }
        _ = Dispatcher.BeginInvoke(() =>
        {
            (byte[] Bytes, int Width, int Height)? frame;
            lock (frameGate) { frame = latest; latest = null; framePending = false; }
            if (receiver != source || frame == null || closed) return;
            var value = frame.Value;
            if (bitmap?.PixelWidth != value.Width || bitmap.PixelHeight != value.Height)
            { bitmap = new(value.Width, value.Height, 96, 96, PixelFormats.Bgra32, null); image.Source = bitmap; }
            bitmap.WritePixels(new Int32Rect(0, 0, value.Width, value.Height), value.Bytes, value.Width * 4, 0);
            ready = true; status.Visibility = Visibility.Collapsed;
        }, DispatcherPriority.Render);
    }
    private AppInput Input(string kind, int button = 0) => new(kind, pointer.X, pointer.Y, button, Modifiers: Modifiers());
    private static ulong Modifiers() => (Keyboard.Modifiers.HasFlag(ModifierKeys.Shift) ? 1UL << 17 : 0) |
        (Keyboard.Modifiers.HasFlag(ModifierKeys.Control) ? 1UL << 18 : 0) | (Keyboard.Modifiers.HasFlag(ModifierKeys.Alt) ? 1UL << 19 : 0) |
        (Keyboard.Modifiers.HasFlag(ModifierKeys.Windows) ? 1UL << 20 : 0);
    private bool Position(Point point, out Point normalized)
    {
        normalized = default; if (bitmap == null || image.ActualWidth <= 0 || image.ActualHeight <= 0) return false;
        var scale = Math.Min(image.ActualWidth / bitmap.PixelWidth, image.ActualHeight / bitmap.PixelHeight);
        var w = bitmap.PixelWidth * scale; var h = bitmap.PixelHeight * scale;
        var x = (point.X - (image.ActualWidth - w) / 2) / w; var y = (point.Y - (image.ActualHeight - h) / 2) / h;
        if (x is < 0 or > 1 || y is < 0 or > 1) return false;
        normalized = new(x, y); return true;
    }
    private static int Button(MouseButton button) => button switch { MouseButton.Right => 1, MouseButton.Middle => 2, _ => 0 };
    private void KeyEvent(KeyEventArgs e, bool down)
    {
        if (!ready || !image.IsKeyboardFocused) return;
        var key = e.Key == Key.System ? e.SystemKey : e.Key;
        if (key == Key.Escape && Keyboard.Modifiers.HasFlag(ModifierKeys.Control) && Keyboard.Modifiers.HasFlag(ModifierKeys.Alt))
        { ReleaseInput(); Keyboard.ClearFocus(); e.Handled = true; return; }
        var vk = KeyInterop.VirtualKeyFromKey(key);
        ushort? mac = key switch { Key.LeftCtrl => 59, Key.RightCtrl => 62, Key.LWin => 55, Key.RWin => 54, _ => null };
        mac ??= Enumerable.Range(0, 128).Select(value => (ushort?)value).FirstOrDefault(value => AppKeyCodes.Windows(value!.Value) == vk);
        if (mac == null) return;
        if (down) heldKeys.Add(mac.Value); else heldKeys.Remove(mac.Value);
        QueueInput(new(down ? "keyDown" : "keyUp", KeyCode: mac.Value, Modifiers: Modifiers())); e.Handled = true;
    }
    private void QueueInput(AppInput input, bool expendable = false)
    {
        if (!ready || inputs == null) return;
        if (expendable && inputs.Reader.Count >= 8) return;
        if (!inputs.Writer.TryWrite(input)) Fail(new IOException("Input fell behind. Reconnect to continue."));
    }
    private async Task InputLoop(WorkspaceClient connected, Channel<AppInput> channel, CancellationToken cancellation)
    {
        try { await foreach (var input in channel.Reader.ReadAllAsync(cancellation)) await connected.RequestAsync(new(Operation("Input")) { SessionID = session, Input = input }, cancellation); }
        catch (Exception error) { if (!cancellation.IsCancellationRequested && client == connected) Fail(error); }
    }
    private void ReleaseInput()
    {
        foreach (var key in heldKeys) QueueInput(new("keyUp", KeyCode: key)); heldKeys.Clear();
        foreach (var button in heldButtons) QueueInput(Input("up", button) with { Modifiers = 0 }); heldButtons.Clear(); image.ReleaseMouseCapture();
    }
    private async Task StopAsync()
    {
        var old = client; client = null; lifetime?.Cancel(); lifetime = null;
        inputs?.Writer.TryComplete(); inputs = null; receiver?.Dispose(); receiver = null; ready = false;
        heldKeys.Clear(); heldButtons.Clear(); image.ReleaseMouseCapture(); image.Source = null; bitmap = null;
        if (old != null) await old.DisposeAsync();
    }
    private void Fail(Exception error) { status.Text = error.Message; status.Visibility = Visibility.Visible; _ = StopAsync(); }
    private void ToggleFullscreen()
    {
        if (WindowStyle == WindowStyle.None) { WindowStyle = previousStyle; WindowState = previousState; }
        else { previousStyle = WindowStyle; previousState = WindowState; WindowStyle = WindowStyle.None; WindowState = WindowState.Maximized; }
    }
}
