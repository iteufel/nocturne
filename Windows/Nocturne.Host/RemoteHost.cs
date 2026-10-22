using System.Runtime.InteropServices;
using System.Security.Cryptography;

namespace Nocturne.Host;

public interface IRemoteHost : IDisposable
{
    string EndpointID { get; }
    void Authorize(ushort sourcePort, string device);
    void Revoke(string device);
}

/// Uses the same Rust QUIC transport and device-proof gate as the Mac host.
public sealed class RemoteHost : IRemoteHost
{
    private readonly object gate = new();
    private nint handle;
    private RemoteHost(nint handle) => this.handle = handle;
    public static async Task<RemoteHost> StartAsync(string broker, byte[] key, ushort port, CancellationToken cancellation)
    {
        broker = RemoteAccessInfo.ValidateBroker(broker);
        if (key.Length != 32) throw new ArgumentException("Invalid remote endpoint key.");
        cancellation.ThrowIfCancellationRequested();
        var copy = (byte[])key.Clone();
        var result = await Task.Run(() =>
        {
            try
            {
                var pointer = Native.Host(broker, copy, port, out var error);
                try
                {
                    if (pointer == 0) throw new IOException(error == 0 ? "Remote access could not start." : Marshal.PtrToStringUTF8(error));
                    return new RemoteHost(pointer);
                }
                finally { if (error != 0) Native.Free(error); }
            }
            catch (DllNotFoundException ex) { throw new IOException("The remote runtime is missing. Install the complete Nocturne Windows package.", ex); }
            finally { CryptographicOperations.ZeroMemory(copy); }
        }, CancellationToken.None);
        if (cancellation.IsCancellationRequested) { result.Dispose(); cancellation.ThrowIfCancellationRequested(); }
        return result;
    }
    public string EndpointID
    {
        get
        {
            lock (gate)
            {
                ObjectDisposedException.ThrowIf(handle == 0, this);
                var text = Native.Id(handle);
                try { return Marshal.PtrToStringUTF8(text) ?? throw new IOException("Invalid remote endpoint."); }
                finally { if (text != 0) Native.Free(text); }
            }
        }
    }
    public void Authorize(ushort sourcePort, string device)
    {
        lock (gate)
        {
            ObjectDisposedException.ThrowIf(handle == 0, this);
            if (Native.Authorize(handle, sourcePort, device) < 0) throw new IOException("The remote device proof does not match this connection.");
        }
    }
    public void Revoke(string device) { lock (gate) { if (handle != 0) Native.Revoke(handle, device); } }
    public void Dispose() { lock (gate) { if (handle == 0) return; Native.Stop(handle); handle = 0; } }
    private static class Native
    {
        [DllImport("nocturne_remote", EntryPoint = "nocturne_remote_host", CallingConvention = CallingConvention.Cdecl)]
        internal static extern nint Host([MarshalAs(UnmanagedType.LPUTF8Str)] string broker, byte[] key, ushort port, out nint error);
        [DllImport("nocturne_remote", EntryPoint = "nocturne_remote_id", CallingConvention = CallingConvention.Cdecl)] internal static extern nint Id(nint handle);
        [DllImport("nocturne_remote", EntryPoint = "nocturne_remote_string_free", CallingConvention = CallingConvention.Cdecl)] internal static extern void Free(nint text);
        [DllImport("nocturne_remote", EntryPoint = "nocturne_remote_authorize", CallingConvention = CallingConvention.Cdecl)]
        internal static extern int Authorize(nint handle, ushort port, [MarshalAs(UnmanagedType.LPUTF8Str)] string device);
        [DllImport("nocturne_remote", EntryPoint = "nocturne_remote_revoke", CallingConvention = CallingConvention.Cdecl)]
        internal static extern void Revoke(nint handle, [MarshalAs(UnmanagedType.LPUTF8Str)] string device);
        [DllImport("nocturne_remote", EntryPoint = "nocturne_remote_stop", CallingConvention = CallingConvention.Cdecl)] internal static extern void Stop(nint handle);
    }
}
