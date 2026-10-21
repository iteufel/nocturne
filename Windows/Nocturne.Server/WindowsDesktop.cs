using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using Nocturne.Host;

namespace Nocturne.Server;

internal sealed class WindowsDesktopHost : IDesktopHost
{
    internal sealed record Target(nint Handle, string Device, uint Id, WindowsAppInput.Rect Bounds, bool Primary);
    internal static Target[] Targets()
    {
        var targets = new List<Target>();
        if (!Native.EnumDisplayMonitors(0, 0, (nint handle, nint dc, ref WindowsAppInput.Rect rectangle, nint data) =>
        {
            var info = new MonitorInfo { Size = Marshal.SizeOf<MonitorInfo>() };
            if (Native.GetMonitorInfo(handle, ref info))
            {
                var hash = SHA256.HashData(Encoding.UTF8.GetBytes(info.Device));
                targets.Add(new(handle, info.Device, System.Buffers.Binary.BinaryPrimitives.ReadUInt32LittleEndian(hash), info.Monitor, (info.Flags & 1) != 0));
            }
            return true;
        }, 0)) throw new Win32Exception();
        return targets.OrderByDescending(target => target.Primary).ToArray();
    }
    public RemoteDesktopDisplay[] Displays()
    {
        var names = WindowsMedia.Displays();
        return Targets().Select(target => new RemoteDesktopDisplay(target.Id,
            names.FirstOrDefault(display => display.Id == target.Device)?.Name ?? target.Device,
            target.Bounds.Right - target.Bounds.Left, target.Bounds.Bottom - target.Bounds.Top, target.Primary)).ToArray();
    }
    public IDesktopCapture Capture(uint? display, AppViewport viewport, Func<Packet, Task> send, Action<Exception> ended)
    {
        var target = Targets().FirstOrDefault(target => display == null || target.Id == display)
            ?? throw new IOException("This display disconnected. Reconnect to refresh the display list.");
        return new WindowsDesktopCapture(target, viewport, send, ended);
    }
    public void Dispose() { }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct MonitorInfo { public int Size; public WindowsAppInput.Rect Monitor, Work; public uint Flags; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string Device; }
    private delegate bool MonitorCallback(nint monitor, nint dc, ref WindowsAppInput.Rect rect, nint data);
    private static class Native
    {
        [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool EnumDisplayMonitors(nint dc, nint clip, MonitorCallback callback, nint data);
        [DllImport("user32.dll", EntryPoint = "GetMonitorInfoW", CharSet = CharSet.Unicode)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool GetMonitorInfo(nint monitor, ref MonitorInfo info);
    }
}

internal sealed class WindowsDesktopCapture : IDesktopCapture
{
    private readonly object gate = new();
    private readonly WindowsDesktopHost.Target target;
    private readonly WindowsAppInput input;
    private readonly CancellationTokenSource stopped = new();
    private AppViewport desired;
    private DisplaySize display;
    private readonly Task video, audio;
    public DisplaySize Display { get { lock (gate) return display; } }
    public uint DisplayID => target.Id;
    public bool ScreenLocked => !InteractiveDesktopAvailable();
    public WindowsDesktopCapture(WindowsDesktopHost.Target target, AppViewport viewport, Func<Packet, Task> send, Action<Exception> ended)
    {
        this.target = target; desired = viewport; display = Fit(viewport);
        input = new(0, () =>
        {
            if (!InteractiveDesktopAvailable()) throw new IOException("Unlock this Windows session locally before controlling it.");
            return WindowsDesktopHost.Targets().FirstOrDefault(item => item.Id == target.Id)?.Bounds ?? throw new IOException("The display disconnected.");
        });
        var ready = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        video = Task.Factory.StartNew(() =>
        {
            WindowsMedia.CaptureHandle? capture = null; AppViewport? applied = null;
            var bytes = new byte[4194304]; var header = new byte[8192]; var codec = new H264Frame();
            try
            {
                while (!stopped.IsCancellationRequested)
                {
                    if (!InteractiveDesktopAvailable()) throw new IOException("Windows switched to the lock or security desktop. Unlock the PC locally, then reconnect.");
                    AppViewport next; lock (gate) next = desired;
                    if (next != applied)
                    {
                        var pixels = Fit(next);
                        capture?.Dispose(); capture = new(WindowsMedia.Check(WindowsMedia.Native.DesktopOpen(target.Handle, pixels.Width, pixels.Height, pixels.FrameRate)));
                        applied = next; lock (gate) display = pixels; codec = new(); ready.TrySetResult();
                    }
                    WindowsMedia.Check(WindowsMedia.Native.CaptureRead(capture!, bytes, bytes.Length, out var length, header, header.Length, out var headerLength, out var timestamp));
                    if (length == 0) continue;
                    var frame = codec.Convert(bytes[..length], header[..headerLength], timestamp);
                    var id = Guid.NewGuid().ToString();
                    for (var offset = 0; offset < frame.Data.Length; offset += Wire.ChunkSize)
                    {
                        stopped.Token.ThrowIfCancellationRequested();
                        send(new("desktopVideo") { TransferID = id, Offset = offset, Size = frame.Data.Length,
                            Video = frame with { Data = frame.Data[offset..Math.Min(frame.Data.Length, offset + Wire.ChunkSize)] } }).GetAwaiter().GetResult();
                    }
                }
            }
            catch (Exception error)
            {
                if (!ready.TrySetException(error) && !stopped.IsCancellationRequested) ended(error);
            }
            finally { capture?.Dispose(); }
        }, CancellationToken.None, TaskCreationOptions.LongRunning, TaskScheduler.Default);
        try { ready.Task.GetAwaiter().GetResult(); }
        catch { stopped.Cancel(); throw; }
        audio = Task.Factory.StartNew(() =>
        {
            nint loopback = 0;
            try
            {
                loopback = WindowsMedia.Check(WindowsMedia.Native.LoopbackOpen()); var bytes = new byte[38400];
                while (!stopped.IsCancellationRequested)
                {
                    WindowsMedia.Check(WindowsMedia.Native.LoopbackRead(loopback, bytes, bytes.Length, out var frames));
                    if (frames == 0 || NativeReceiver.PlayingAudio > 0 && WindowsMedia.Native.LoopbackIsolated(loopback) == 0) continue;
                    send(new("desktopAudio") { Audio = new(bytes[..(frames * 8)], frames) }).GetAwaiter().GetResult();
                }
            }
            catch (Exception error) { System.Diagnostics.Debug.WriteLine("Desktop audio: " + error.Message); }
            finally { if (loopback != 0) WindowsMedia.Native.LoopbackClose(loopback); }
        }, CancellationToken.None, TaskCreationOptions.LongRunning, TaskScheduler.Default);
    }
    private DisplaySize Fit(AppViewport viewport)
    {
        var budget = viewport.Pixels(); var bounds = target.Bounds;
        var width = bounds.Right - bounds.Left; var height = bounds.Bottom - bounds.Top;
        var scale = Math.Min((double)budget.Width / width, (double)budget.Height / height);
        return new(Math.Max(2, (int)(width * scale / 2) * 2), Math.Max(2, (int)(height * scale / 2) * 2), viewport.FrameRate);
    }
    public void Resize(AppViewport viewport) { lock (gate) { desired = viewport; display = Fit(viewport); } }
    public void Input(AppInput value) { lock (gate) { if (stopped.IsCancellationRequested) throw new IOException("The desktop stopped."); input.Handle(value); } }
    public void Dispose() { lock (gate) { stopped.Cancel(); input.Release(); } }
    private static bool InteractiveDesktopAvailable()
    {
        var desktop = Native.OpenInputDesktop(0, false, 1);
        if (desktop == 0) return false;
        try
        {
            var name = new StringBuilder(256);
            return Native.GetUserObjectInformation(desktop, 2, name, 512, out _) && name.ToString() == "Default";
        }
        finally { Native.CloseDesktop(desktop); }
    }
    private static class Native
    {
        [DllImport("user32.dll")] internal static extern nint OpenInputDesktop(uint flags, [MarshalAs(UnmanagedType.Bool)] bool inherit, uint access);
        [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool CloseDesktop(nint desktop);
        [DllImport("user32.dll", EntryPoint = "GetUserObjectInformationW", CharSet = CharSet.Unicode)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool GetUserObjectInformation(nint handle, int index, StringBuilder name, int size, out int needed);
    }
}
