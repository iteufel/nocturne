using System.IO;
using System.IO.Pipes;
using System.Text;
using System.Xml;
using System.Xml.Linq;
using Microsoft.Win32;
using Nocturne.Host;

namespace Nocturne.Server;

/// Only the configuration explicitly assigned to Nocturne by its elevated setup helper is edited.
internal static class VirtualDisplayModes
{
    private static readonly string directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "Nocturne", "VirtualDisplay");
    public static bool Ensure(DisplaySize size)
    {
        using var key = Registry.LocalMachine.OpenSubKey(@"SOFTWARE\MikeTheTech\VirtualDisplayDriver");
        if (key?.GetValue("VDDPATH") is not string configured || !string.Equals(Path.GetFullPath(configured), directory, StringComparison.OrdinalIgnoreCase)) return false;
        var path = Path.Combine(directory, "vdd_settings.xml");
        var settings = new XmlReaderSettings { DtdProcessing = DtdProcessing.Prohibit, XmlResolver = null, MaxCharactersInDocument = 1_048_576 };
        XDocument document;
        using (var reader = XmlReader.Create(path, settings)) document = XDocument.Load(reader);
        var root = document.Element("vdd_settings") ?? throw new IOException("The virtual display configuration is invalid. Run Nocturne display setup again.");
        var resolutions = root.Element("resolutions");
        if (resolutions == null) { resolutions = new("resolutions"); root.Add(resolutions); }
        var mode = resolutions.Elements("resolution").FirstOrDefault(mode => (int?)mode.Element("width") == size.Width && (int?)mode.Element("height") == size.Height);
        var hasRate = mode?.Elements("refresh_rate").Any(rate => (double?)rate == size.FrameRate) == true;
        if (hasRate && (int?)root.Element("monitors")?.Element("count") >= 1) return false;
        if (mode == null)
        {
            var generated = resolutions.Elements("resolution").Where(mode => (string?)mode.Attribute("owner") == "Nocturne").ToList();
            while (generated.Count >= 64) { generated[0].Remove(); generated.RemoveAt(0); }
            mode = new XElement("resolution", new XAttribute("owner", "Nocturne"), new XElement("width", size.Width), new XElement("height", size.Height));
            resolutions.Add(mode);
        }
        if (!hasRate) mode.Add(new XElement("refresh_rate", size.FrameRate));
        var monitors = root.Element("monitors");
        if (monitors == null) { monitors = new("monitors", new XElement("count", 1)); root.Add(monitors); }
        var count = Math.Clamp((int?)monitors.Element("count") ?? 1, 1, 99);
        monitors.SetElementValue("count", count);
        var temporary = Path.Combine(directory, "settings-" + Guid.NewGuid() + ".tmp");
        try { document.Save(temporary); File.Move(temporary, path, true); }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
        using var pipe = new NamedPipeClientStream(".", "MTTVirtualDisplayPipe", PipeDirection.InOut, PipeOptions.Asynchronous);
        pipe.Connect(4000);
        var bytes = Encoding.Unicode.GetBytes("SETDISPLAYCOUNT " + count);
        pipe.Write(bytes); pipe.Flush();
        return true;
    }
}
