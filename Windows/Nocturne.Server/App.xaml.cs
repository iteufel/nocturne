using System.Security.Principal;
using System.Windows;
using System.Diagnostics;
using System.IO;
using Nocturne.Host;

namespace Nocturne.Server;

public partial class App : Application
{
    private Mutex? instance;
    protected override async void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        if (e.Args.Length == 2 && e.Args[0] == "--display-watchdog" && int.TryParse(e.Args[1], out var parent) && parent > 0 && parent != Environment.ProcessId)
        {
            try
            {
                try { using var process = Process.GetProcessById(parent); await process.WaitForExitAsync(); }
                catch (ArgumentException) { }
                WindowsDisplayControl.Recover(new HostStorage().DirectoryPath);
            }
            catch (Exception error) { Debug.WriteLine("Display recovery: " + error.Message); }
            Shutdown(); return;
        }
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 19041))
        { MessageBox.Show("Nocturne Server requires Windows 10 version 2004 or Windows 11."); Shutdown(); return; }
        instance = new Mutex(true, "Local\\Nocturne.Server." + WindowsIdentity.GetCurrent().User!.Value, out var first);
        if (!first) { MessageBox.Show("Nocturne Server is already open in this Windows session."); Shutdown(); return; }
        try { var window = new MainWindow(); MainWindow = window; window.Show(); await window.InitializeHostAsync(); }
        catch (Exception error) { MessageBox.Show(error.Message, "Nocturne Server"); Shutdown(1); }
    }
    protected override void OnExit(ExitEventArgs e) { instance?.Dispose(); base.OnExit(e); }
}
