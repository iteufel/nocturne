using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Interop;
using System.Windows.Media.Imaging;
using Nocturne.Host;

namespace Nocturne.Server;

internal sealed class WindowsApplications : IAppWindowHost
{
    private sealed record Application(string Id, string Name, string Executable, string Arguments = "", string Directory = "", string? AppUserModelID = null);
    private readonly Dictionary<string, Application> catalog = new(StringComparer.OrdinalIgnoreCase);
    private DateTime scanned = DateTime.MinValue;
    public RemoteApplication[] Applications()
    {
        Scan();
        return catalog.Values.Select(app => new RemoteApplication(app.Id, app.Name, app.AppUserModelID)).OrderBy(app => app.Name, StringComparer.CurrentCultureIgnoreCase).ToArray();
    }
    private void Scan()
    {
        if (DateTime.UtcNow - scanned < TimeSpan.FromSeconds(15)) return;
        catalog.Clear();
        object? script = null, shell = null;
        try
        {
            script = Activator.CreateInstance(Type.GetTypeFromProgID("WScript.Shell")!);
            foreach (var root in new[] { Environment.GetFolderPath(Environment.SpecialFolder.StartMenu), Environment.GetFolderPath(Environment.SpecialFolder.CommonStartMenu) })
            {
                if (!System.IO.Directory.Exists(root)) continue;
                foreach (var file in System.IO.Directory.EnumerateFiles(root, "*.lnk", SearchOption.AllDirectories))
                {
                    object? link = null;
                    try
                    {
                        link = ((dynamic)script!).CreateShortcut(file);
                        string path = ((dynamic)link).TargetPath;
                        if (!Path.IsPathFullyQualified(path) || !path.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) || !File.Exists(path)) continue;
                        path = Path.GetFullPath(path);
                        catalog.TryAdd(path, new(path, Path.GetFileNameWithoutExtension(file), path, ((dynamic)link).Arguments, ((dynamic)link).WorkingDirectory));
                    }
                    catch (Exception ex) when (ex is COMException or IOException or UnauthorizedAccessException) { }
                    finally { if (link != null) Marshal.ReleaseComObject(link); }
                }
            }
            shell = Activator.CreateInstance(Type.GetTypeFromProgID("Shell.Application")!);
            dynamic folder = ((dynamic)shell!).NameSpace("shell:AppsFolder");
            foreach (dynamic item in folder.Items())
            {
                try
                {
                    string? id = item.ExtendedProperty("System.AppUserModel.ID");
                    if (string.IsNullOrEmpty(id) || id.Length > 512 || id.Any(char.IsControl)) continue;
                    string name = item.Name;
                    catalog.TryAdd("app:" + id, new("app:" + id, name, "", AppUserModelID: id));
                }
                finally { Marshal.ReleaseComObject(item); }
            }
            Marshal.ReleaseComObject(folder);
        }
        catch (Exception ex) when (ex is COMException or IOException or UnauthorizedAccessException) { }
        finally { if (script != null) Marshal.ReleaseComObject(script); if (shell != null) Marshal.ReleaseComObject(shell); }
        foreach (var window in OpenWindows())
        {
            try
            {
                using var process = Process.GetProcessById((int)window.Process);
                var file = process.MainModule?.FileName;
                if (file == null || !File.Exists(file)) continue;
                catalog.TryAdd(file, new(file, process.MainModule?.FileVersionInfo.FileDescription ?? process.ProcessName, file));
            }
            catch (Exception ex) when (ex is Win32Exception or InvalidOperationException or ArgumentException) { }
        }
        scanned = DateTime.UtcNow;
    }
    private Application Find(string id) { Scan(); return catalog.GetValueOrDefault(id) ?? throw new IOException("This app is no longer installed. Refresh Apps on your device."); }
    private string? Owner(nint window, uint pid)
    {
        try
        {
            using var process = Process.GetProcessById((int)pid);
            var count = 0u;
            if (Native.GetApplicationUserModelId(process.Handle, ref count, null) == 122 && count is > 0 and < 1024)
            {
                var value = new StringBuilder((int)count);
                if (Native.GetApplicationUserModelId(process.Handle, ref count, value) == 0 && catalog.ContainsKey("app:" + value)) return "app:" + value;
            }
            var executable = process.MainModule?.FileName;
            if (executable != null && catalog.TryGetValue(executable, out var app)) return app.Id;
        }
        catch (Exception ex) when (ex is Win32Exception or InvalidOperationException or ArgumentException) { }
        return null;
    }
    public RemoteAppWindow[] Windows(string? application)
    {
        Scan(); if (application != null) _ = Find(application);
        return OpenWindows().Select(window => new { window, app = Owner(window.Handle, window.Process) })
            .Where(value => value.app != null && (application == null || value.app == application))
            .Select(value => new RemoteAppWindow(unchecked((uint)value.window.Handle), value.app!, value.window.Title, value.window.Width, value.window.Height))
            .Take(256).ToArray();
    }
    public byte[] Icon(string application)
    {
        var app = Find(application); var info = new Native.FileInfo();
        var path = app.Executable.Length == 0 ? "application.exe" : app.Executable;
        var flags = 0x100u | (app.Executable.Length == 0 ? 0x10u : 0);
        if (Native.SHGetFileInfo(path, 0x80, ref info, (uint)Marshal.SizeOf<Native.FileInfo>(), flags) == 0 || info.Icon == 0)
            throw new IOException("This application's icon is unavailable.");
        try
        {
            var bitmap = Imaging.CreateBitmapSourceFromHIcon(info.Icon, System.Windows.Int32Rect.Empty, BitmapSizeOptions.FromWidthAndHeight(96, 96));
            var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(bitmap));
            using var stream = new MemoryStream(); encoder.Save(stream);
            if (stream.Length > 131072) throw new IOException("The application icon is too large.");
            return stream.ToArray();
        }
        finally { Native.DestroyIcon(info.Icon); }
    }
    public RemoteAppWindow[] Launch(string application)
    {
        var app = Find(application);
        ProcessStartInfo start;
        if (app.AppUserModelID != null) start = new("explorer.exe") { UseShellExecute = false, ArgumentList = { "shell:AppsFolder\\" + app.AppUserModelID } };
        else start = new(app.Executable) { UseShellExecute = false, Arguments = app.Arguments, WorkingDirectory = app.Directory.Length == 0 ? Path.GetDirectoryName(app.Executable)! : app.Directory };
        Process.Start(start)?.Dispose();
        for (var i = 0; i < 40; i++) { var windows = Windows(app.Id); if (windows.Length != 0) return windows; Thread.Sleep(250); }
        throw new IOException(app.Name + " has no open window. Open a window on the PC, then refresh Apps.");
    }
    public IAppWindowCapture Capture(string application, uint window, AppViewport viewport, Func<Packet, Task> send, Action<Exception> ended)
    {
        _ = Find(application);
        var selected = Windows(application).FirstOrDefault(value => value.Id == window) ?? throw new IOException("This app window closed. Choose another window in Apps.");
        return new WindowsWindowCapture(selected, viewport, send, ended);
    }
    private sealed record Window(nint Handle, uint Process, string Title, int Width, int Height);
    private static Window[] OpenWindows()
    {
        var result = new List<Window>();
        Native.EnumWindows((window, _) =>
        {
            if (!Native.IsWindowVisible(window) || Native.GetWindow(window, 4) != 0) return true;
            Native.GetWindowThreadProcessId(window, out var process);
            if (process == Environment.ProcessId || !WindowsAppInput.Native.GetWindowRect(window, out var rect) || rect.Right - rect.Left < 100 || rect.Bottom - rect.Top < 80) return true;
            var text = new StringBuilder(512); Native.GetWindowText(window, text, text.Capacity);
            if (text.Length > 0) result.Add(new(window, process, text.ToString(), rect.Right - rect.Left, rect.Bottom - rect.Top));
            return true;
        }, 0);
        return result.ToArray();
    }
    public void Dispose() { }
    private static class Native
    {
        internal delegate bool EnumWindow(nint window, nint context);
        [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool EnumWindows(EnumWindow callback, nint context);
        [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool IsWindowVisible(nint window);
        [DllImport("user32.dll")] internal static extern nint GetWindow(nint window, uint command);
        [DllImport("user32.dll")] internal static extern uint GetWindowThreadProcessId(nint window, out uint process);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] internal static extern int GetWindowText(nint window, StringBuilder text, int length);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] internal static extern int GetApplicationUserModelId(nint process, ref uint length, StringBuilder? text);
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] internal struct FileInfo
        { public nint Icon; public int Index; public uint Attributes; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string DisplayName; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 80)] public string TypeName; }
        [DllImport("shell32.dll", CharSet = CharSet.Unicode)] internal static extern nint SHGetFileInfo(string path, uint attributes, ref FileInfo info, uint size, uint flags);
        [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool DestroyIcon(nint icon);
    }
}

internal sealed class WindowsWindowCapture : IAppWindowCapture
{
    private readonly object gate = new();
    private readonly nint window;
    private readonly WindowsAppInput input;
    private readonly CancellationTokenSource stopped = new();
    private WindowsMedia.CaptureHandle? capture;
    private readonly Task worker;
    public RemoteAppWindow Window { get; private set; }
    public DisplaySize Display { get; private set; }
    public WindowsWindowCapture(RemoteAppWindow window, AppViewport viewport, Func<Packet, Task> send, Action<Exception> ended)
    {
        Window = window; this.window = unchecked((nint)(int)window.Id); input = new(this.window); Display = viewport.Pixels();
        Resize(viewport);
        worker = Task.Run(async () =>
        {
            var bytes = new byte[4_194_304]; var header = new byte[8192]; var codec = new H264Frame();
            try
            {
                while (!stopped.IsCancellationRequested)
                {
                    int length, headerLength; double timestamp;
                    lock (gate)
                    {
                        if (capture == null) break;
                        WindowsMedia.Check(WindowsMedia.Native.CaptureRead(capture, bytes, bytes.Length, out length, header, header.Length, out headerLength, out timestamp));
                    }
                    if (length == 0) continue;
                    var frame = codec.Convert(bytes[..length], header[..headerLength], timestamp);
                    var id = Guid.NewGuid().ToString();
                    for (var offset = 0; offset < frame.Data.Length; offset += Wire.ChunkSize)
                    {
                        stopped.Token.ThrowIfCancellationRequested();
                        await send(new("appVideo") { TransferID = id, Offset = offset, Size = frame.Data.Length,
                            Video = frame with { Data = frame.Data[offset..Math.Min(frame.Data.Length, offset + Wire.ChunkSize)] } });
                    }
                }
            }
            catch (Exception error) { if (!stopped.IsCancellationRequested) ended(error); }
            finally { lock (gate) { capture?.Dispose(); capture = null; } }
        });
    }
    public void Resize(AppViewport viewport)
    {
        lock (gate)
        {
            if (stopped.IsCancellationRequested) throw new IOException("The app window stream stopped.");
            var pixels = viewport.Pixels();
            WindowsAppInput.Native.ShowWindow(window, 9);
            var dpi = Native.GetDpiForWindow(window); var scale = Math.Max(1, dpi / 96.0);
            if (!Native.SetWindowPos(window, 0, 0, 0, (int)Math.Round(viewport.Width * scale), (int)Math.Round(viewport.Height * scale), 0x0002 | 0x0004 | 0x0010)) throw new Win32Exception();
            var next = new WindowsMedia.CaptureHandle(WindowsMedia.Check(WindowsMedia.Native.CaptureOpen(window, pixels.Width, pixels.Height, pixels.FrameRate)));
            capture?.Dispose(); capture = next; Display = pixels;
            if (WindowsAppInput.Native.GetWindowRect(window, out var rect)) Window = Window with { Width = rect.Right - rect.Left, Height = rect.Bottom - rect.Top };
        }
    }
    public void Input(AppInput value) { lock (gate) { if (stopped.IsCancellationRequested) throw new IOException("The app window stream stopped."); input.Handle(value); } }
    public void Dispose()
    {
        lock (gate)
        {
            if (stopped.IsCancellationRequested) return;
            stopped.Cancel();
            try { input.Release(); } finally { capture?.Dispose(); capture = null; }
        }
    }
    private static class Native
    {
        [DllImport("user32.dll")] internal static extern uint GetDpiForWindow(nint window);
        [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool SetWindowPos(nint window, nint after, int x, int y, int width, int height, uint flags);
    }
}
