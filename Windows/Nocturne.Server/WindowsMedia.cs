using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.Json;
using Microsoft.Win32.SafeHandles;
using Nocturne.Host;

namespace Nocturne.Server;

public sealed record DisplayOption(string Id, string Name, bool IsVirtual, bool IsPrimary = false)
{
    public string Label => Id.Length == 0 ? Name : Name + " · " + Id.Replace(@"\\.\", "") + (IsVirtual ? " · Virtual" : "") + (IsPrimary ? " · Main" : "");
}
public sealed record AudioEndpoint(string Id, string Name);

internal static class WindowsMedia
{
    public static DisplayOption[] Displays() => Decode<DisplayOption[]>(Native.Displays());
    public static AudioEndpoint[] AudioEndpoints() => Decode<AudioEndpoint[]>(Native.AudioDevices());
    private static T Decode<T>(nint text) => JsonSerializer.Deserialize<T>(Marshal.PtrToStringUni(Check(text))!, Wire.Json)
        ?? throw new IOException("Windows returned an invalid device list.");
    public static nint Check(nint value) { if (value == 0) throw Error(); return value; }
    public static void Check(int value) { if (value < 0) throw Error(); }
    private static IOException Error() => new(Marshal.PtrToStringUni(Native.Error()) ?? "The Windows media operation failed.");

    internal static class Native
    {
        private const string Library = "nocturne_host";
        [DllImport(Library, EntryPoint = "nocturne_host_error", CallingConvention = CallingConvention.Cdecl)] internal static extern nint Error();
        [DllImport(Library, EntryPoint = "nocturne_displays", CallingConvention = CallingConvention.Cdecl)] internal static extern nint Displays();
        [DllImport(Library, EntryPoint = "nocturne_display_save", CharSet = CharSet.Unicode, ExactSpelling = true, CallingConvention = CallingConvention.Cdecl)] internal static extern int DisplaySave(string path);
        [DllImport(Library, EntryPoint = "nocturne_display_prepare", CharSet = CharSet.Unicode, ExactSpelling = true, CallingConvention = CallingConvention.Cdecl)] internal static extern int DisplayPrepare(string device, int width, int height, int fps, int disableOthers);
        [DllImport(Library, EntryPoint = "nocturne_display_restore", CharSet = CharSet.Unicode, ExactSpelling = true, CallingConvention = CallingConvention.Cdecl)] internal static extern int DisplayRestore(string path);
        [DllImport(Library, EntryPoint = "nocturne_audio_devices", CallingConvention = CallingConvention.Cdecl)] internal static extern nint AudioDevices();
        [DllImport(Library, EntryPoint = "nocturne_audio_open", CharSet = CharSet.Unicode, ExactSpelling = true, CallingConvention = CallingConvention.Cdecl)] internal static extern nint AudioOpen(string device);
        [DllImport(Library, EntryPoint = "nocturne_audio_write", CallingConvention = CallingConvention.Cdecl)] internal static extern int AudioWrite(AudioHandle handle, byte[] pcm, int length);
        [DllImport(Library, EntryPoint = "nocturne_audio_close", CallingConvention = CallingConvention.Cdecl)] internal static extern void AudioClose(nint handle);
        [DllImport(Library, EntryPoint = "nocturne_capture_open", CallingConvention = CallingConvention.Cdecl)] internal static extern nint CaptureOpen(nint window, int width, int height, int fps);
        [DllImport(Library, EntryPoint = "nocturne_capture_read", CallingConvention = CallingConvention.Cdecl)] internal static extern int CaptureRead(CaptureHandle handle,
            [Out] byte[] bytes, int capacity, out int length, [Out] byte[] header, int headerCapacity, out int headerLength, out double timestamp);
        [DllImport(Library, EntryPoint = "nocturne_capture_close", CallingConvention = CallingConvention.Cdecl)] internal static extern void CaptureClose(nint handle);
    }
    internal sealed class AudioHandle : SafeHandleZeroOrMinusOneIsInvalid
    {
        public AudioHandle(nint value) : base(true) => SetHandle(value);
        protected override bool ReleaseHandle() { Native.AudioClose(handle); return true; }
    }
    internal sealed class CaptureHandle : SafeHandleZeroOrMinusOneIsInvalid
    {
        public CaptureHandle(nint value) : base(true) => SetHandle(value);
        protected override bool ReleaseHandle() { Native.CaptureClose(handle); return true; }
    }
}

internal sealed class WindowsMicrophoneOutput(string device) : IMicrophoneOutput
{
    private WindowsMedia.AudioHandle? handle;
    public void Start()
    {
        Stop();
        handle = new(WindowsMedia.Check(WindowsMedia.Native.AudioOpen(device)));
    }
    public void Write(byte[] pcm) => WindowsMedia.Check(WindowsMedia.Native.AudioWrite(handle ?? throw new IOException("The microphone stopped."), pcm, pcm.Length));
    public void Stop() { handle?.Dispose(); handle = null; }
    public void Dispose() => Stop();
}

internal sealed class WindowsDisplayControl(HostSettings settings, string directory, CancellationToken cancellation = default) : IDisplayControl
{
    private readonly string recovery = Path.Combine(directory, "display-recovery.bin");
    private bool saved;
    private static bool watchdogStarted;
    public static void Recover(string directory)
    {
        var path = Path.Combine(directory, "display-recovery.bin");
        if (!File.Exists(path)) return;
        WindowsMedia.Check(WindowsMedia.Native.DisplayRestore(path)); File.Delete(path);
    }
    public DisplaySize Prepare(DisplaySize size)
    {
        if (!saved)
        {
            Recover(directory);
            WindowsMedia.Check(WindowsMedia.Native.DisplaySave(recovery)); saved = true;
            StartWatchdog();
        }
        var reload = settings.HeadlessDisplay && VirtualDisplayModes.Ensure(size);
        var deadline = DateTime.UtcNow.AddSeconds(reload ? 45 : 0);
        while (true)
        {
            cancellation.ThrowIfCancellationRequested();
            try
            {
                var displays = WindowsMedia.Displays();
                var selected = settings.HeadlessDisplay ? displays.FirstOrDefault(display => display.IsVirtual && display.Id == settings.PhysicalDisplay)
                    ?? displays.FirstOrDefault(display => display.IsVirtual) :
                    settings.PhysicalDisplay.Length == 0 ? displays.FirstOrDefault(display => display.IsPrimary) ?? displays.FirstOrDefault() :
                    displays.FirstOrDefault(display => display.Id == settings.PhysicalDisplay);
                if (selected == null) throw new IOException(settings.HeadlessDisplay
                    ? "Install and enable a virtual display driver, then refresh Displays in Nocturne Server."
                    : "The selected display is unavailable. Refresh Displays in Nocturne Server.");
                WindowsMedia.Check(WindowsMedia.Native.DisplayPrepare(selected.Id, size.Width, size.Height, size.FrameRate, settings.DisablePhysicalDisplays ? 1 : 0));
                return size;
            }
            catch (IOException) when (DateTime.UtcNow < deadline) { Thread.Sleep(250); }
        }
    }
    private static void StartWatchdog()
    {
        if (watchdogStarted || !string.Equals(Path.GetFileName(Environment.ProcessPath), "Nocturne Server.exe", StringComparison.OrdinalIgnoreCase)) return;
        var process = Process.Start(new ProcessStartInfo(Environment.ProcessPath!)
        { ArgumentList = { "--display-watchdog", Environment.ProcessId.ToString() }, UseShellExecute = false, CreateNoWindow = true })
            ?? throw new IOException("The display recovery helper could not start.");
        process.Dispose(); watchdogStarted = true;
    }
    public void Restore()
    {
        if (!saved) return;
        Recover(directory); saved = false;
    }
    public void Dispose() => Restore();
}
