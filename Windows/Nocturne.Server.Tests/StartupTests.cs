using System.IO;
using System.Runtime.ExceptionServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using System.Windows.Controls;
using System.Windows.Media.Imaging;
using Nocturne.Host;
using Xunit;

namespace Nocturne.Server.Tests;

public sealed class StartupTests
{
    [Fact]
    public void MainWindowInitializesAndRendersOnAnStaThread()
    {
        ExceptionDispatchInfo? failure = null;
        var phase = "Create UI thread";
        void Stage(string value)
        {
            Volatile.Write(ref phase, value);
            var directory = Environment.GetEnvironmentVariable("NOCTURNE_WINDOWS_TEST_ARTIFACTS");
            if (!string.IsNullOrEmpty(directory))
            {
                Directory.CreateDirectory(directory);
                File.AppendAllText(Path.Combine(directory, "startup-stages.log"), DateTime.UtcNow.ToString("O") + " " + value + Environment.NewLine);
            }
        }
        var thread = new Thread(() =>
        {
            var profile = Path.Combine(Path.GetTempPath(), "nocturne-ui-" + Guid.NewGuid());
            App? app = null; MainWindow? window = null; ServerModel? model = null;
            try
            {
                // Generated BAML URIs already identify the application's assembly.
                RenderOptions.ProcessRenderMode = RenderMode.SoftwareOnly;
                Stage("Initialize application");
                // WPF requires the runtime App type and its compiled resources
                // to come from the same assembly. Only normal launch is disabled.
                var startupObserved = false;
                app = new App(launchShell: false);
                app.Startup += (_, _) => startupObserved = true;
                app.InitializeComponent();
                model = new ServerModel(new HostStorage(profile));
                window = new MainWindow(model);
                app.MainWindow = window; window.Show();
                window.Dispatcher.Invoke(() =>
                {
                    Assert.True(startupObserved);
                    Assert.Same(window, app.MainWindow);
                    Assert.Same(window, Assert.Single(app.Windows.Cast<Window>()));
                    window.UpdateLayout();
                    Assert.True(window.IsLoaded);
                    Assert.Equal("Nocturne", window.Title);
                    Assert.NotNull(window.Content);
                    Assert.True(model.CanAct);
                    Assert.NotNull(window.FindName("DisplaysPanel"));
                    Assert.NotNull(window.FindName("RemotePanel"));
                    Assert.NotNull(window.FindName("ComputersPanel"));
                    Assert.NotNull(window.FindName("GeneralPanel"));
                    var ink = Assert.IsType<SolidColorBrush>(app.FindResource("Ink")).Color;
                    Assert.Equal(ink, Assert.IsType<SolidColorBrush>(window.Foreground).Color);
                    var overview = Assert.IsType<StackPanel>(window.FindName("Overview"));
                    Assert.Equal(ink, Assert.IsType<SolidColorBrush>(Assert.IsType<TextBlock>(overview.Children[0]).Foreground).Color);
                    Assert.Equal(TextWrapping.Wrap, Assert.IsType<TextBlock>(overview.Children[1]).TextWrapping);
                    Assert.True(model.ScreenSharing); Assert.False(model.HasSettingsChanges);
                    model.Terminal = true; Assert.True(model.CanApply);
                    model.DiscardSettings(); Assert.False(model.Terminal); Assert.False(model.HasSettingsChanges);
                    Stage("Render settings panels"); SaveScreens(window);
                    Stage("Verify authenticated receiver");
                    VerifyReceiver(window, profile);
                    Stage("Verify background activation");
                    VerifyBackgroundHost(window, model, Stage);
                    Assert.Same(window, app.MainWindow);
                    Assert.Same(window, Assert.Single(app.Windows.Cast<Window>()));
                }, DispatcherPriority.ContextIdle);
            }
            catch (Exception error) { failure = ExceptionDispatchInfo.Capture(error); }
            finally
            {
                try
                {
                    Stage("Close main window"); window?.Close();
                    Stage("Dispose model");
                    model?.CloseAsync().GetAwaiter().GetResult();
                    Stage("Shut down application");
                    app?.Shutdown();
                    Stage("Remove test profile");
                    if (Directory.Exists(profile)) Directory.Delete(profile, true);
                }
                catch (Exception error) { failure ??= ExceptionDispatchInfo.Capture(error); }
            }
        }) { IsBackground = true };
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        Assert.True(thread.Join(TimeSpan.FromSeconds(60)), "The Windows application did not finish its startup smoke test. Last stage: " + Volatile.Read(ref phase));
        failure?.Throw();
    }

    [NativeFixtureFact]
    public void NativeWindowsEncoderProducesClientCompatibleVideoPackets()
    {
        var data = File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "native-h264-frame.bin"));
        var header = System.Buffers.Binary.BinaryPrimitives.ReadInt32LittleEndian(data);
        Assert.InRange(header, 1, 8192); Assert.True(data.Length > header + 4);
        var video = new H264Frame().Convert(data[(header + 4)..], data[4..(header + 4)], 1);
        Assert.Equal(2, video.ParameterSets.Length);
        Assert.Equal(7, video.ParameterSets[0][0] & 31); Assert.Equal(8, video.ParameterSets[1][0] & 31);
        for (var offset = 0; offset < video.Data.Length; offset += Wire.ChunkSize)
        {
            var packet = new Packet("appVideo") { SessionID = Guid.NewGuid().ToString(), TransferID = Guid.NewGuid().ToString(),
                Offset = offset, Size = video.Data.Length, Video = video with { Data = video.Data[offset..Math.Min(video.Data.Length, offset + Wire.ChunkSize)] } };
            Assert.InRange(Wire.Encode(packet).Length, 1, Wire.MaximumFrame + 4);
        }
    }
    private sealed class NativeFixtureFactAttribute : FactAttribute
    {
        public NativeFixtureFactAttribute()
        {
            if (!File.Exists(Path.Combine(AppContext.BaseDirectory, "native-h264-frame.bin")) && Environment.GetEnvironmentVariable("GITHUB_ACTIONS") != "true")
                Skip = "Run scripts/build-windows.ps1 to build and verify the native Windows encoder fixture.";
        }
    }
    private static void VerifyReceiver(MainWindow owner, string profile)
    {
        var path = Path.Combine(AppContext.BaseDirectory, "native-h264-frame.bin");
        if (!File.Exists(path)) return;
        var fixture = File.ReadAllBytes(path); var header = System.Buffers.Binary.BinaryPrimitives.ReadInt32LittleEndian(fixture);
        var video = new H264Frame().Convert(fixture[(header + 4)..], fixture[4..(header + 4)], 1);
        var devices = new DeviceStore(Path.Combine(profile, "receiver-fixture-devices.json"));
        var secret = System.Security.Cryptography.RandomNumberGenerator.GetBytes(32);
        var server = new WorkspaceServer("Receiver test host", secret, devices, new(), null, (_, _) => throw new IOException(), desktop: new(new ReceiverDesktop(video)));
        server.Start(0, System.Net.IPAddress.Loopback);
        var saved = 0;
        var window = new RemoteStreamWindow(new("127.0.0.1", (ushort)server.Port, "Receiver test host", secret, devices.CreateInvitation()),
            ClientCredentials.Create(), _ => saved++, null) { Owner = owner };
        try
        {
            window.Show(); var frame = new DispatcherFrame(); var deadline = DateTime.UtcNow.AddSeconds(20);
            var poll = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(25) };
            poll.Tick += (_, _) => { if (window.VideoReady || DateTime.UtcNow >= deadline) frame.Continue = false; };
            poll.Start(); Dispatcher.PushFrame(frame); poll.Stop();
            Assert.True(window.VideoReady, window.StreamStatus); Assert.Equal(1, saved);
            var picture = Assert.IsAssignableFrom<BitmapSource>(window.VideoImage);
            var pixel = new byte[4]; picture.CopyPixels(new Int32Rect(picture.PixelWidth / 2, picture.PixelHeight / 2, 1, 1), pixel, 4, 0);
            Assert.True(pixel[2] > 150 && pixel[1] < 80 && pixel[0] < 80, "The authenticated Windows receiver did not display its decoded red frame.");
            var directory = Environment.GetEnvironmentVariable("NOCTURNE_WINDOWS_TEST_ARTIFACTS");
            if (directory != null)
            {
                window.UpdateLayout(); var content = (FrameworkElement)window.Content;
                var image = new RenderTargetBitmap((int)content.ActualWidth, (int)content.ActualHeight, 96, 96, PixelFormats.Pbgra32); image.Render(content);
                var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(image)); using var output = File.Create(Path.Combine(directory, "Remote-desktop.png")); encoder.Save(output);
            }
        }
        finally
        {
            window.Close();
            // Dispose away from the dispatcher: server cleanup awaits session
            // workers and must not capture the UI context blocked by this test.
            Task.Run(async () => await server.DisposeAsync()).GetAwaiter().GetResult();
        }
    }
    private static void VerifyBackgroundHost(MainWindow window, ServerModel model, Action<string> stage)
    {
        var channel = "Nocturne-tests-" + Guid.NewGuid();
        stage("Create tray and activation listener");
        using var shell = new BackgroundShell(window, channel);
        stage("Hide main window while sharing stays available");
        window.KeepAlive = true; window.Close();
        Assert.False(window.IsVisible); Assert.True(model.CanAct);
        stage("Connect to activation pipe");
        var activate = BackgroundShell.SendAsync("activate", channel: channel);
        var frame = new DispatcherFrame(); var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(25) };
        var deadline = DateTime.UtcNow.AddSeconds(5);
        timer.Tick += (_, _) => { if (activate.IsCompleted || DateTime.UtcNow >= deadline) frame.Continue = false; };
        stage("Pump dispatcher until activation completes");
        timer.Start(); Dispatcher.PushFrame(frame); timer.Stop();
        stage("Verify activation reply and visible window");
        Assert.True(activate.IsCompletedSuccessfully, "The private activation pipe did not respond.");
        Assert.Equal(Environment.ProcessId, activate.Result); Assert.True(window.IsVisible);
        window.KeepAlive = false;
        stage("Dispose tray and activation listener");
    }
    private sealed class ReceiverDesktop(AppVideo frame) : IDesktopHost
    {
        public RemoteDesktopDisplay[] Displays() => [new(7, "Fixture monitor", 640, 480, true)];
        public IDesktopCapture Capture(uint? display, AppViewport viewport, Func<Packet, Task> send, Action<Exception> ended) => new ReceiverCapture(frame, send);
        public void Dispose() { }
    }
    private sealed class ReceiverCapture : IDesktopCapture
    {
        private readonly CancellationTokenSource lifetime = new();
        public DisplaySize Display => new(640, 480, 60);
        public uint DisplayID => 7;
        public bool ScreenLocked => false;
        public ReceiverCapture(AppVideo frame, Func<Packet, Task> send) => _ = Task.Run(async () =>
        {
            try
            {
                var timestamp = 1.0;
                while (!lifetime.IsCancellationRequested)
                {
                    await Task.Delay(100, lifetime.Token);
                    await send(new("desktopVideo") { Video = frame with { Timestamp = timestamp } }); timestamp += .1;
                }
            }
            catch (OperationCanceledException) { }
        });
        public void Resize(AppViewport viewport) { }
        public void Input(AppInput input) { }
        public void Dispose() => lifetime.Cancel();
    }
    private static void SaveScreens(MainWindow window)
    {
        var directory = Environment.GetEnvironmentVariable("NOCTURNE_WINDOWS_TEST_ARTIFACTS");
        if (string.IsNullOrEmpty(directory)) return;
        Directory.CreateDirectory(directory);
        static IEnumerable<DependencyObject> Children(DependencyObject parent)
        {
            for (var index = 0; index < VisualTreeHelper.GetChildrenCount(parent); index++)
            {
                var child = VisualTreeHelper.GetChild(parent, index); yield return child;
                foreach (var descendant in Children(child)) yield return descendant;
            }
        }
        void Save(string name)
        {
            window.UpdateLayout();
            var content = (FrameworkElement)window.Content;
            var image = new RenderTargetBitmap((int)content.ActualWidth, (int)content.ActualHeight, 96, 96, PixelFormats.Pbgra32);
            image.Render(content); var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(image));
            using var output = File.Create(Path.Combine(directory, name + ".png")); encoder.Save(output);
        }
        foreach (var tab in new[] { "Overview", "ComputersPanel", "Sharing", "DisplaysPanel", "RemotePanel", "Devices", "GeneralPanel" })
        {
            var button = Children(window).OfType<Button>().Single(button => button.Tag is string value && value == tab);
            button.RaiseEvent(new RoutedEventArgs(Button.ClickEvent)); Save(tab);
            if (tab is "Sharing" or "DisplaysPanel")
            {
                Assert.IsType<ScrollViewer>(window.FindName("MainScroll")).ScrollToEnd(); Save(tab + "-bottom");
            }
        }
    }
}
