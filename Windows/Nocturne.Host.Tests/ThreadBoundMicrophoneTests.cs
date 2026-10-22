using System.Collections.Concurrent;
using Xunit;

namespace Nocturne.Host.Tests;

public sealed class ThreadBoundMicrophoneTests
{
    [Fact]
    public async Task AudioCreatedByASessionIsStoppedAndReleasedOnItsOriginalThread()
    {
        var calls = new ConcurrentQueue<(string Operation, int Thread)>();
        var output = new ThreadBoundMicrophoneOutput(() => new RecordingOutput(calls));
        await Task.Run(output.Start);
        await Task.Run(() => output.Write(new byte[MicrophoneSession.FrameBytes]));
        // Timeouts and disconnects can arrive on different worker threads.
        await Task.Run(output.Stop);
        await Task.Run(output.Dispose);
        output.Dispose();
        Assert.Equal(new[] { "create", "start", "write", "stop", "dispose" }, calls.Select(call => call.Operation));
        Assert.Single(calls.Select(call => call.Thread).Distinct());
        Assert.Throws<ObjectDisposedException>(output.Start);
    }

    [Fact]
    public void NativeFailureIsReturnedToTheSessionAndStillAllowsCleanup()
    {
        var calls = new ConcurrentQueue<(string Operation, int Thread)>();
        using var output = new ThreadBoundMicrophoneOutput(() => new RecordingOutput(calls, failWrites: true));
        output.Start();
        Assert.Throws<IOException>(() => output.Write([]));
        output.Stop();
        Assert.Equal(new[] { "create", "start", "write", "stop" }, calls.Select(call => call.Operation));
    }

    private sealed class RecordingOutput : IMicrophoneOutput
    {
        private readonly ConcurrentQueue<(string Operation, int Thread)> calls;
        private readonly bool failWrites;
        public RecordingOutput(ConcurrentQueue<(string Operation, int Thread)> calls, bool failWrites = false)
        { this.calls = calls; this.failWrites = failWrites; Record("create"); }
        private void Record(string operation) => calls.Enqueue((operation, Environment.CurrentManagedThreadId));
        public void Start() => Record("start");
        public void Write(byte[] pcm) { Record("write"); if (failWrites) throw new IOException("Audio endpoint disconnected."); }
        public void Stop() => Record("stop");
        public void Dispose() => Record("dispose");
    }
}
