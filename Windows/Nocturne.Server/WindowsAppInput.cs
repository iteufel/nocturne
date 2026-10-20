using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using Nocturne.Host;

namespace Nocturne.Server;

internal sealed class WindowsAppInput(nint window)
{
    private readonly HashSet<ushort> keys = [];
    private readonly HashSet<int> buttons = [];
    public void Handle(AppInput input)
    {
        if (!input.IsValid) throw new IOException("Invalid app input.");
        Native.ShowWindow(window, 9);
        if (Native.GetForegroundWindow() != window) Native.SetForegroundWindow(window);
        if (Native.GetForegroundWindow() != window) throw new IOException("Windows could not focus this window. Close any security prompt on the PC and retry.");
        Synchronize(0xA0, (input.Modifiers & (1UL << 17)) != 0);
        Synchronize(0xA2, (input.Modifiers & ((1UL << 18) | (1UL << 20))) != 0);
        Synchronize(0xA4, (input.Modifiers & (1UL << 19)) != 0);
        if (input.Kind is "move" or "down" or "up" or "scroll")
        {
            if (!Native.GetWindowRect(window, out var rect)) throw new Win32Exception();
            var x = rect.Left + (int)Math.Round(input.X * Math.Max(1, rect.Right - rect.Left - 1));
            var y = rect.Top + (int)Math.Round(input.Y * Math.Max(1, rect.Bottom - rect.Top - 1));
            if (!Native.SetCursorPos(x, y)) throw new Win32Exception();
        }
        if (input.Kind is "down" or "up")
        {
            var down = input.Kind == "down";
            if (down) buttons.Add(input.Button); else buttons.Remove(input.Button);
            Mouse(ButtonFlag(input.Button, down));
        }
        else if (input.Kind == "scroll")
        {
            if (input.DeltaY != 0) Mouse(0x0800, unchecked((uint)(int)Math.Round(-input.DeltaY * 4)));
            if (input.DeltaX != 0) Mouse(0x1000, unchecked((uint)(int)Math.Round(input.DeltaX * 4)));
        }
        else if (input.Kind is "keyDown" or "keyUp")
        {
            var key = AppKeyCodes.Windows(input.KeyCode);
            if (key == 0) throw new IOException("This keyboard key is not supported.");
            Synchronize(key, input.Kind == "keyDown");
        }
        else if (input.Kind == "text")
            foreach (var character in input.Text)
            {
                Send(new() { Type = 1, Data = new() { Keyboard = new() { Scan = character, Flags = 4 } } });
                Send(new() { Type = 1, Data = new() { Keyboard = new() { Scan = character, Flags = 6 } } });
            }
    }
    private void Synchronize(ushort key, bool down)
    {
        if (down ? !keys.Add(key) : !keys.Remove(key)) return;
        var extended = key is >= 0x21 and <= 0x28 or 0x2D or 0x2E or 0xA3 or 0xA5;
        Send(new() { Type = 1, Data = new() { Keyboard = new() { Key = key, Flags = (down ? 0u : 2u) | (extended ? 1u : 0u) } } });
    }
    public void Release()
    {
        foreach (var key in keys.ToArray()) try { Synchronize(key, false); } catch (IOException) { }
        foreach (var button in buttons) try { Mouse(ButtonFlag(button, false)); } catch (IOException) { }
        buttons.Clear();
    }
    private static uint ButtonFlag(int button, bool down) => (button, down) switch
    { (0, true) => 2, (0, false) => 4, (1, true) => 8, (1, false) => 16, (2, true) => 32, _ => 64 };
    private static void Mouse(uint flags, uint data = 0) => Send(new() { Data = new() { Mouse = new() { Flags = flags, Data = data } } });
    private static void Send(Input input)
    {
        if (Native.SendInput(1, [input], Marshal.SizeOf<Input>()) != 1)
            throw new IOException("Windows did not allow input to this app window. Elevated windows require matching permissions on the PC.");
    }
    [StructLayout(LayoutKind.Sequential)] internal struct Rect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] internal struct MouseInput { public int X, Y; public uint Data, Flags, Time; public nuint Extra; }
    [StructLayout(LayoutKind.Sequential)] internal struct KeyboardInput { public ushort Key, Scan; public uint Flags, Time; public nuint Extra; }
    [StructLayout(LayoutKind.Explicit)] internal struct InputData { [FieldOffset(0)] public MouseInput Mouse; [FieldOffset(0)] public KeyboardInput Keyboard; }
    [StructLayout(LayoutKind.Sequential)] internal struct Input { public uint Type; public InputData Data; }
    internal static class Native
    {
        [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool GetWindowRect(nint window, out Rect rect);
        [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool SetForegroundWindow(nint window);
        [DllImport("user32.dll")] internal static extern nint GetForegroundWindow();
        [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool ShowWindow(nint window, int command);
        [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool SetCursorPos(int x, int y);
        [DllImport("user32.dll", SetLastError = true)] internal static extern uint SendInput(uint count, Input[] inputs, int size);
    }
}
