using System.Runtime.InteropServices;
namespace Nocturne.Host;

public sealed class RemoteClient : IClientTunnel
{
    private nint handle;
    private RemoteClient(nint handle) => this.handle = handle;
    public ushort Port => Native.Port(handle);
    public string Route => Native.Route(handle) switch { 1 => "Direct peer to peer", 2 => "Encrypted relay", _ => "Remote connection" };
    public static async Task<IClientTunnel> ConnectAsync(RemoteAccessInfo access, CancellationToken cancellation)
    {
        var result = await Task.Run(() =>
        {
            var handle = Native.Client(RemoteAccessInfo.ValidateBroker(access.BrokerURL), access.EndpointID, false, out var error);
            try
            {
                if (handle == 0) throw new IOException(error == 0 ? "Remote connection failed." : Marshal.PtrToStringUTF8(error));
                return new RemoteClient(handle);
            }
            finally { if (error != 0) Native.Free(error); }
        }, CancellationToken.None);
        if (cancellation.IsCancellationRequested) { result.Dispose(); cancellation.ThrowIfCancellationRequested(); }
        return result;
    }
    public void Dispose() { var value = Interlocked.Exchange(ref handle, 0); if (value != 0) Native.Stop(value); }
    private static class Native
    {
        [DllImport("nocturne_remote", EntryPoint = "nocturne_remote_client", CallingConvention = CallingConvention.Cdecl)]
        internal static extern nint Client([MarshalAs(UnmanagedType.LPUTF8Str)] string broker, [MarshalAs(UnmanagedType.LPUTF8Str)] string endpoint, [MarshalAs(UnmanagedType.I1)] bool streaming, out nint error);
        [DllImport("nocturne_remote", EntryPoint = "nocturne_remote_port", CallingConvention = CallingConvention.Cdecl)] internal static extern ushort Port(nint handle);
        [DllImport("nocturne_remote", EntryPoint = "nocturne_remote_route", CallingConvention = CallingConvention.Cdecl)] internal static extern int Route(nint handle);
        [DllImport("nocturne_remote", EntryPoint = "nocturne_remote_stop", CallingConvention = CallingConvention.Cdecl)] internal static extern void Stop(nint handle);
        [DllImport("nocturne_remote", EntryPoint = "nocturne_remote_string_free", CallingConvention = CallingConvention.Cdecl)] internal static extern void Free(nint text);
    }
}
