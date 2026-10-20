using Microsoft.Win32;
using Nocturne.Host;
using System.IO;

namespace Nocturne.Server;

internal sealed class WindowsStartup : ILoginStartup
{
    private const string Key = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private readonly string executable = Environment.ProcessPath ?? throw new IOException("The application path is unavailable.");
    private string Command => '"' + executable + "\" --login";
    public bool Enabled
    {
        get { using var key = Registry.CurrentUser.OpenSubKey(Key); return key?.GetValue("Nocturne Server") is string value && value == Command; }
    }
    public void SetEnabled(bool enabled)
    {
        using var key = Registry.CurrentUser.CreateSubKey(Key, true) ?? throw new IOException("Windows login settings could not be opened.");
        if (enabled) key.SetValue("Nocturne Server", Command, RegistryValueKind.String);
        else key.DeleteValue("Nocturne Server", false);
    }
}
