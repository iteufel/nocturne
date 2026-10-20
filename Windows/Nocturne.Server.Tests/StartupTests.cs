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
        var thread = new Thread(() =>
        {
            var profile = Path.Combine(Path.GetTempPath(), "nocturne-ui-" + Guid.NewGuid());
            App? app = null; MainWindow? window = null; ServerModel? model = null;
            try
            {
                // Generated BAML URIs already identify the application's assembly.
                RenderOptions.ProcessRenderMode = RenderMode.SoftwareOnly;
                app = new App(); app.InitializeComponent();
                model = new ServerModel(new HostStorage(profile));
                window = new MainWindow(model);
                app.MainWindow = window; window.Show();
                window.Dispatcher.Invoke(() =>
                {
                    window.UpdateLayout();
                    Assert.True(window.IsLoaded);
                    Assert.Equal("Nocturne Server", window.Title);
                    Assert.NotNull(window.Content);
                    Assert.True(model.CanAct);
                    Assert.NotNull(window.FindName("DisplaysPanel"));
                    Assert.NotNull(window.FindName("RemotePanel"));
                    Assert.True(model.ScreenSharing); Assert.False(model.HasSettingsChanges);
                    model.Terminal = true; Assert.True(model.CanApply);
                    model.DiscardSettings(); Assert.False(model.Terminal); Assert.False(model.HasSettingsChanges);
                    SaveScreens(window);
                }, DispatcherPriority.ContextIdle);
            }
            catch (Exception error) { failure = ExceptionDispatchInfo.Capture(error); }
            finally
            {
                try
                {
                    window?.Close();
                    model?.CloseAsync().GetAwaiter().GetResult();
                    app?.Shutdown();
                    if (Directory.Exists(profile)) Directory.Delete(profile, true);
                }
                catch (Exception error) { failure ??= ExceptionDispatchInfo.Capture(error); }
            }
        }) { IsBackground = true };
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        Assert.True(thread.Join(TimeSpan.FromSeconds(30)), "The Windows application did not finish its startup smoke test.");
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
        foreach (var tab in new[] { "Overview", "Sharing", "DisplaysPanel", "RemotePanel", "Devices" })
        {
            var button = Children(window).OfType<Button>().Single(button => button.Tag is string value && value == tab);
            button.RaiseEvent(new RoutedEventArgs(Button.ClickEvent)); window.UpdateLayout();
            var content = (FrameworkElement)window.Content;
            var image = new RenderTargetBitmap((int)content.ActualWidth, (int)content.ActualHeight, 96, 96, PixelFormats.Pbgra32);
            image.Render(content); var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(image));
            using var output = File.Create(Path.Combine(directory, tab + ".png")); encoder.Save(output);
        }
    }
}
