using System.Security.Principal;
using System.Windows;
using System.Diagnostics;
using System.IO;
using Nocturne.Host;

namespace Nocturne.Server;

public partial class App : Application
{
    private Mutex? instance;
    private BackgroundShell? shell;
    private MainWindow? window;
    private bool ownsInstance;
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
        { MessageBox.Show("Nocturne requires Windows 10 version 2004 or Windows 11."); Shutdown(); return; }
        instance = new Mutex(true, "Local\\Nocturne.Server." + WindowsIdentity.GetCurrent().User!.Value, out var first);
        ownsInstance = first;
        var pairing = e.Args.FirstOrDefault(argument => argument.StartsWith("nocturne://", StringComparison.OrdinalIgnoreCase));
        if (!first)
        {
            try
            {
                await BackgroundShell.SendAsync(e.Args.Contains("--shutdown") ? "quit" : pairing == null ? "activate" : "pair", pairing);
                if (e.Args.Contains("--shutdown")) await Task.Run(() =>
                {
                    var acquired = false;
                    try { acquired = instance.WaitOne(TimeSpan.FromSeconds(30)); }
                    catch (AbandonedMutexException) { acquired = true; }
                    finally { if (acquired) instance.ReleaseMutex(); }
                    if (!acquired) throw new IOException("Nocturne is still closing. Wait for its sessions to finish, then retry.");
                });
            }
            catch (Exception error) { if (!e.Args.Contains("--shutdown")) MessageBox.Show(error.Message, "Nocturne"); Shutdown(1); return; }
            Shutdown(); return;
        }
        if (e.Args.Contains("--shutdown")) { Shutdown(); return; }
        try
        {
            window = new MainWindow(); MainWindow = window; window.Show();
            shell = new(window); window.KeepAlive = true;
            Microsoft.Win32.SystemEvents.UserPreferenceChanged += SystemAppearanceChanged;
            await window.InitializeHostAsync();
            if (pairing != null) window.OpenComputerCode(pairing);
            else if (!window.WelcomeCompleted) window.ShowWelcome();
            else if (e.Args.Contains("--login")) window.Hide();
        }
        catch (Exception error) { MessageBox.Show(error.Message, "Nocturne"); Shutdown(1); }
    }
    private void SystemAppearanceChanged(object sender, Microsoft.Win32.UserPreferenceChangedEventArgs e)
    { if (!Dispatcher.HasShutdownStarted) _ = Dispatcher.BeginInvoke(() => window?.RefreshAppearance()); }
    protected override void OnExit(ExitEventArgs e)
    {
        Microsoft.Win32.SystemEvents.UserPreferenceChanged -= SystemAppearanceChanged;
        shell?.Dispose(); if (ownsInstance) instance?.ReleaseMutex(); instance?.Dispose(); base.OnExit(e);
    }
}
