using System.Collections.Concurrent;
using System.IO;
using Nocturne.Host;

namespace Nocturne.Server;

/// All decoder and WASAPI creation, use, and release stay on one MTA thread.
/// Compressed video cannot be dropped between reference frames; overload closes
/// the stream, while audio and already decoded images can be dropped safely.
internal sealed class NativeReceiver : IDisposable
{
    private readonly BlockingCollection<object> incoming = new(16);
    private readonly CancellationTokenSource stopped = new();
    private readonly VideoAssembler assembler = new();
    private readonly Thread worker;
    private readonly int width, height;
    private volatile bool muted;
    private readonly object audioChanged = new();
    private int disposed;
    private static int active;
    private static int playingAudio;
    public static int Active => Volatile.Read(ref active);
    public static int PlayingAudio => Volatile.Read(ref playingAudio);
    public bool Muted
    {
        get => muted;
        set { muted = value; if (Volatile.Read(ref disposed) == 0) incoming.TryAdd(audioChanged); }
    }
    public event Action<byte[], int, int>? Frame;
    public event Action<Exception>? Failed;
    public event Action<string>? AudioFailed;
    public NativeReceiver(int width, int height)
    {
        this.width = width; this.height = height;
        worker = new(Run) { IsBackground = true, Name = "Nocturne media playback" }; worker.SetApartmentState(ApartmentState.MTA); worker.Start();
    }
    public void Receive(Packet packet)
    {
        if (Volatile.Read(ref disposed) != 0) return;
        if (packet.Operation == "desktopAudio")
        {
            if (packet.Audio?.IsValid != true) throw new IOException("The host sent invalid audio.");
            if (!muted) incoming.TryAdd(packet.Audio); return;
        }
        var frame = assembler.Receive(packet);
        if (frame != null && !incoming.TryAdd(frame)) throw new IOException("Video decoding fell behind. Reduce the window size, then reconnect.");
    }
    private void Run()
    {
        Interlocked.Increment(ref active);
        nint decoder = 0, playback = 0; byte[][]? parameters = null; bool audioFailed = false;
        var pixels = new byte[4096 * 4096 * 4];
        try
        {
            foreach (var item in incoming.GetConsumingEnumerable(stopped.Token))
            {
                if ((muted || audioFailed) && playback != 0) { WindowsMedia.Native.PlaybackClose(playback); playback = 0; Interlocked.Decrement(ref playingAudio); }
                if (item is DesktopAudio audio)
                {
                    if (muted || audioFailed) continue;
                    try
                    {
                        if (playback == 0) { playback = WindowsMedia.Check(WindowsMedia.Native.PlaybackOpen()); Interlocked.Increment(ref playingAudio); }
                        WindowsMedia.Check(WindowsMedia.Native.PlaybackWrite(playback, audio.Data, audio.Frames));
                    }
                    catch (Exception error) { audioFailed = true; AudioFailed?.Invoke(error.Message); }
                }
                else if (item is AppVideo frame)
                {
                    if (parameters == null || !parameters.Zip(frame.ParameterSets).All(pair => pair.First.AsSpan().SequenceEqual(pair.Second)))
                    {
                        if (decoder != 0) WindowsMedia.Native.DecoderClose(decoder);
                        decoder = 0; decoder = WindowsMedia.Check(WindowsMedia.Native.DecoderOpen(width, height)); parameters = frame.ParameterSets;
                    }
                    var bytes = VideoAssembler.AnnexB(frame);
                    WindowsMedia.Check(WindowsMedia.Native.DecoderFrame(decoder, bytes, bytes.Length, frame.Timestamp, pixels, pixels.Length, out var w, out var h, out var size));
                    if (size > 0) Frame?.Invoke(pixels[..size], w, h);
                }
            }
        }
        catch (OperationCanceledException) when (stopped.IsCancellationRequested) { }
        catch (Exception error) { if (!stopped.IsCancellationRequested) Failed?.Invoke(error); }
        finally
        {
            if (decoder != 0) WindowsMedia.Native.DecoderClose(decoder);
            if (playback != 0) { WindowsMedia.Native.PlaybackClose(playback); Interlocked.Decrement(ref playingAudio); }
            Interlocked.Decrement(ref active);
        }
    }
    public void Dispose()
    {
        if (Interlocked.Exchange(ref disposed, 1) != 0) return;
        stopped.Cancel(); incoming.CompleteAdding();
    }
}
