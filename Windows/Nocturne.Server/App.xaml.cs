using System.Security.Principal;
using System.Windows;

namespace Nocturne.Server;

public partial class App : Application
{
    private Mutex? instance;
    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 19041))
        { MessageBox.Show("Nocturne Server requires Windows 10 version 2004 or Windows 11."); Shutdown(); return; }
        instance = new Mutex(true, "Local\\Nocturne.Server." + WindowsIdentity.GetCurrent().User!.Value, out var first);
        if (!first) { MessageBox.Show("Nocturne Server is already open in this Windows session."); Shutdown(); return; }
        try { MainWindow = new MainWindow(); MainWindow.Show(); }
        catch (Exception error) { MessageBox.Show(error.Message, "Nocturne Server"); Shutdown(1); }
    }
    protected override void OnExit(ExitEventArgs e) { instance?.Dispose(); base.OnExit(e); }
}
