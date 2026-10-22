using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Media;
using Microsoft.Win32;
using Nocturne.Host;
namespace Nocturne.Server;

internal sealed record UserPreferences(string Appearance = "System", bool WelcomeCompleted = false)
{
    public static UserPreferences Load(HostStorage storage)
    {
        var path = Path.Combine(storage.DirectoryPath, "preferences.json");
        return File.Exists(path) ? JsonSerializer.Deserialize<UserPreferences>(File.ReadAllBytes(path), Wire.Json)
            ?? throw new IOException("Preferences could not be read.") : new();
    }
    public void Save(HostStorage storage)
    {
        var path = Path.Combine(storage.DirectoryPath, "preferences.json");
        File.WriteAllBytes(path + ".tmp", JsonSerializer.SerializeToUtf8Bytes(this, Wire.Json)); File.Move(path + ".tmp", path, true);
    }
    public void Apply()
    {
        using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
        var light = Appearance == "Light" || Appearance == "System" && key?.GetValue("AppsUseLightTheme") is int value && value != 0;
        var colors = light
            ? new[] { "#F4F4FA", "#FFFFFF", "#E4E3F1", "#1B1D2B", "#555B70", "#6251B5", "#267256", "#E9E8F4", "#FCE8EC", "#832E41" }
            : new[] { "#10121B", "#232630", "#303440", "#F4F5FA", "#B0B5C7", "#BEBAFF", "#8CDDBB", "#191C28", "#402E36", "#FFD5D9" };
        var names = new[] { "Canvas", "Surface", "Elevated", "Ink", "Muted", "Accent", "Mint", "Sidebar", "ErrorSurface", "ErrorInk" };
        for (var index = 0; index < names.Length; index++)
            Application.Current.Resources[names[index]] = new SolidColorBrush((Color)ColorConverter.ConvertFromString(colors[index]));
        Application.Current.Resources["AccentInk"] = new SolidColorBrush(light ? Colors.White : (Color)ColorConverter.ConvertFromString("#10121B"));
    }
}
