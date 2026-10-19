using System.IO;
using System.Runtime.ExceptionServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
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
                // Match the real application's resource lookup, even in testhost.
                Application.ResourceAssembly = typeof(App).Assembly;
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
}
