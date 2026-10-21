using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Interop;
using Nocturne.Host;
namespace Nocturne.Server;

/// One background host per signed-in session. The private pipe also allows an
/// installer to request graceful shutdown before replacing files in use.
internal sealed class BackgroundShell : IDisposable
{
    private readonly MainWindow window;
    private readonly string channel;
    private readonly HwndSource source;
    private readonly CancellationTokenSource lifetime = new();
    private NotifyIcon icon;
    private readonly Task commands;
    private static string PipeName => "Nocturne." + WindowsIdentity.GetCurrent().User!.Value + "." + System.Diagnostics.Process.GetCurrentProcess().SessionId;
    public BackgroundShell(MainWindow window, string? channel = null)
    {
        this.window = window; this.channel = channel ?? PipeName;
        source = HwndSource.FromHwnd(new WindowInteropHelper(window).EnsureHandle())!; source.AddHook(Messages);
        var handle = Native.ExtractIcon(0, Environment.ProcessPath!, 0);
        icon = new() { Size = (uint)Marshal.SizeOf<NotifyIcon>(), Window = source.Handle, Id = 1, Flags = 7, Callback = 0x801F, Icon = handle, Tip = "Nocturne · Sharing in the background" };
        if (!Native.Notify(0, ref icon)) { if (handle != 0) Native.DestroyIcon(handle); throw new IOException("Windows could not create the Nocturne tray icon."); }
        commands = Task.Run(CommandLoop);
    }
    private nint Messages(nint handle, int message, nint wparam, nint lparam, ref bool handled)
    {
        if (message != 0x801F) return 0;
        var notification = (int)lparam & 0xffff;
        if (notification is 0x202 or 0x203) window.Reveal();
        if (notification == 0x205)
        {
            var menu = new ContextMenu { PlacementTarget = window, Placement = PlacementMode.MousePoint };
            void Item(string label, Action action) { var item = new MenuItem { Header = label }; item.Click += (_, _) => action(); menu.Items.Add(item); }
            Item("Open Nocturne", window.Reveal); Item("Connect to a computer…", window.AddComputer);
            Item("Pair a device", window.ShowPairing); Item("Welcome to Nocturne…", window.ShowWelcome);
            Item("Restore displays", window.RestoreScreens); menu.Items.Add(new Separator()); Item("Quit Nocturne", () => _ = window.QuitAsync());
            menu.IsOpen = true;
        }
        handled = true; return 0;
    }
    private async Task CommandLoop()
    {
        while (!lifetime.IsCancellationRequested)
        {
            try
            {
                await using var pipe = new NamedPipeServerStream(channel, PipeDirection.InOut, 1, PipeTransmissionMode.Byte,
                    PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
                await pipe.WaitForConnectionAsync(lifetime.Token);
                var request = await Task.Run(() => Wire.Read(pipe), lifetime.Token).WaitAsync(TimeSpan.FromSeconds(5), lifetime.Token);
                if (request.Operation == "quit") await window.Dispatcher.InvokeAsync(window.QuitAsync).Task.Unwrap();
                else await window.Dispatcher.InvokeAsync(() =>
                {
                    window.Reveal(); if (request.Operation == "pair" && request.Path is { Length: <= 8192 } code) window.OpenComputerCode(code);
                });
                if (pipe.IsConnected) await pipe.WriteAsync(Wire.Encode(request.Reply()), lifetime.Token);
            }
            catch (Exception error) when (error is IOException or OperationCanceledException or TimeoutException or ObjectDisposedException) { }
        }
    }
    public static async Task<int> SendAsync(string operation, string? code = null, string? channel = null)
    {
        await using var pipe = new NamedPipeClientStream(".", channel ?? PipeName, PipeDirection.InOut, PipeOptions.Asynchronous);
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(30));
        await pipe.ConnectAsync(5000, deadline.Token);
        if (!Native.ServerProcess(pipe.SafePipeHandle, out var process)) throw new IOException("The running Nocturne process could not be identified.");
        using var abort = deadline.Token.Register(pipe.Dispose);
        await pipe.WriteAsync(Wire.Encode(new(operation) { Path = code }), deadline.Token);
        // Shutdown acknowledgement can be lost when the application exits. The
        // installer separately waits for the executable to leave memory.
        if (operation != "quit") _ = await Task.Run(() => Wire.Read(pipe), deadline.Token);
        return checked((int)process);
    }
    public void Dispose()
    {
        lifetime.Cancel(); Native.Notify(2, ref icon); source.RemoveHook(Messages); if (icon.Icon != 0) Native.DestroyIcon(icon.Icon);
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct NotifyIcon
    {
        public uint Size; public nint Window; public uint Id, Flags, Callback; public nint Icon;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Tip;
        public uint State, StateMask;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string Info;
        public uint Timeout;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string Title;
        public uint InfoFlags; public Guid Guid; public nint BalloonIcon;
    }
    private static class Native
    {
        [DllImport("shell32.dll", EntryPoint = "Shell_NotifyIconW", CharSet = CharSet.Unicode)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool Notify(uint command, ref NotifyIcon icon);
        [DllImport("shell32.dll", EntryPoint = "ExtractIconW", CharSet = CharSet.Unicode)] internal static extern nint ExtractIcon(nint instance, string file, uint index);
        [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool DestroyIcon(nint icon);
        [DllImport("kernel32.dll", EntryPoint = "GetNamedPipeServerProcessId", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool ServerProcess(Microsoft.Win32.SafeHandles.SafePipeHandle pipe, out uint process);
    }
}
