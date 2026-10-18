using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Threading.Channels;
using Microsoft.Win32.SafeHandles;

namespace Nocturne.Host;

[SupportedOSPlatform("windows")]
public sealed class ConPtyTerminal(int columns, int rows) : ITerminal
{
    public event Action<byte[]>? Output;
    public event Action? Exited;
    private nint console;
    private WindowsJob? job;
    private Process? process;
    private FileStream? input, output;
    private int disposed, ended;
    private Task? reader;
    private sealed record Command(byte[]? Data = null, int Columns = 0, int Rows = 0);
    private readonly Channel<Command> writes = Channel.CreateBounded<Command>(32);
    public Task Completion { get; private set; } = Task.CompletedTask;

    public void Start()
    {
        if (process != null || Volatile.Read(ref disposed) != 0) throw new IOException("Terminal is closed.");
        SafeFileHandle? inputRead = null, inputWrite = null, outputRead = null, outputWrite = null;
        nint attributes = 0; bool initialized = false;
        try
        {
            if (!CreatePipe(out inputRead, out inputWrite, 0, 0) || !CreatePipe(out outputRead, out outputWrite, 0, 0))
                throw new Win32Exception();
            Marshal.ThrowExceptionForHR(CreatePseudoConsole(new((short)columns, (short)rows), inputRead, outputWrite, 0, out console));
            nuint bytes = 0; InitializeProcThreadAttributeList(0, 1, 0, ref bytes);
            attributes = Marshal.AllocHGlobal(checked((int)bytes));
            if (!InitializeProcThreadAttributeList(attributes, 1, 0, ref bytes)) throw new Win32Exception();
            initialized = true;
            if (!UpdateProcThreadAttribute(attributes, 0, (nuint)0x00020016, console, (nuint)nint.Size, 0, 0))
                throw new Win32Exception();
            input = new(inputWrite, FileAccess.Write, 4096, false); inputWrite = null;
            output = new(outputRead, FileAccess.Read, 4096, false); outputRead = null;
            job = new();
            var shell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe");
            process = WindowsProcess.Launch(shell, "-NoLogo -NoProfile", Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), job, attributes);
            inputRead.Dispose(); inputRead = null; outputWrite.Dispose(); outputWrite = null;
            // ConPTY uses synchronous pipes. Each direction gets its own worker.
            reader = Task.Run(ReadLoop);
            _ = Task.Run(WriteLoop);
            Completion = MonitorAsync(process);
        }
        catch { Dispose(); throw; }
        finally
        {
            inputRead?.Dispose(); inputWrite?.Dispose(); outputRead?.Dispose(); outputWrite?.Dispose();
            if (initialized) DeleteProcThreadAttributeList(attributes);
            if (attributes != 0) Marshal.FreeHGlobal(attributes);
        }
    }

    private void ReadLoop()
    {
        try
        {
            var buffer = new byte[16_384];
            while (true)
            {
                int count = output!.Read(buffer);
                if (count == 0) break;
                Output?.Invoke(buffer.AsSpan(0, count).ToArray());
            }
        }
        catch (Exception ex) when (ex is IOException or ObjectDisposedException) { }
    }

    private void WriteLoop()
    {
        try
        {
            while (writes.Reader.WaitToReadAsync().AsTask().GetAwaiter().GetResult())
                while (writes.Reader.TryRead(out var command))
                {
                    if (command.Data != null) { input!.Write(command.Data); input.Flush(); }
                    else
                    {
                        var handle = Volatile.Read(ref console);
                        if (handle != 0) Marshal.ThrowExceptionForHR(ResizePseudoConsole(handle, new((short)command.Columns, (short)command.Rows)));
                    }
                }
        }
        catch (Exception ex) when (ex is IOException or ObjectDisposedException or COMException) { Dispose(); }
    }

    private async Task MonitorAsync(Process child)
    {
        try
        {
            await child.WaitForExitAsync();
            Volatile.Write(ref ended, 1);
            job?.Dispose();
            writes.Writer.TryComplete();
            // ClosePseudoConsole can wait for output consumption; the reader remains active.
            await Task.Run(CloseConsole);
            if (reader != null) await reader;
            Exited?.Invoke();
        }
        finally { input?.Dispose(); output?.Dispose(); child.Dispose(); }
    }

    public void Input(byte[] data)
    {
        if (Volatile.Read(ref disposed) != 0 || Volatile.Read(ref ended) != 0 || process == null) throw new IOException("This shell has ended.");
        if (!writes.Writer.TryWrite(new((byte[])data.Clone()))) throw new IOException("The terminal is busy. Try again.");
    }
    public void Resize(int columns, int rows)
    {
        if (Volatile.Read(ref disposed) != 0 || Volatile.Read(ref ended) != 0) return;
        // ConPTY resize can block on its output pipe. Never call it while the
        // registry holds the output-history lock; use the independent input worker.
        if (!writes.Writer.TryWrite(new(Columns: columns, Rows: rows))) throw new IOException("The terminal is busy. Try again.");
    }
    private void CloseConsole()
    {
        var handle = Interlocked.Exchange(ref console, 0);
        if (handle != 0) ClosePseudoConsole(handle);
    }
    public void Dispose()
    {
        if (Interlocked.Exchange(ref disposed, 1) != 0) return;
        writes.Writer.TryComplete();
        job?.Dispose(); // Terminates all commands, even children of the shell.
        if (process == null) _ = Task.Run(() =>
        {
            CloseConsole();
            input?.Dispose(); output?.Dispose();
        });
    }

    [StructLayout(LayoutKind.Sequential)] private readonly record struct Coord(short X, short Y);
    [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CreatePipe(out SafeFileHandle read, out SafeFileHandle write, nint attributes, uint size);
    [DllImport("kernel32.dll")] private static extern int CreatePseudoConsole(Coord size, SafeFileHandle input, SafeFileHandle output, uint flags, out nint console);
    [DllImport("kernel32.dll")] private static extern int ResizePseudoConsole(nint console, Coord size);
    [DllImport("kernel32.dll")] private static extern void ClosePseudoConsole(nint console);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool InitializeProcThreadAttributeList(nint list, int count, uint flags, ref nuint size);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool UpdateProcThreadAttribute(nint list, uint flags, nuint attribute, nint value, nuint size, nint previous, nint returnedSize);
    [DllImport("kernel32.dll")] private static extern void DeleteProcThreadAttributeList(nint list);
}
