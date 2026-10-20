using System.Collections.Concurrent;
using System.Runtime.ExceptionServices;

namespace Nocturne.Host;

/// Native audio services must be created, used, and released on their owning thread.
public sealed class ThreadBoundMicrophoneOutput : IMicrophoneOutput
{
    private sealed record Command(Action<IMicrophoneOutput> Action, TaskCompletionSource Completion);
    private readonly BlockingCollection<Command> commands = new(1);
    private readonly object gate = new();
    private readonly Thread worker;
    private bool disposed;
    private ExceptionDispatchInfo? cleanupFailure;

    public ThreadBoundMicrophoneOutput(Func<IMicrophoneOutput> create)
    {
        var ready = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        worker = new Thread(() =>
        {
            IMicrophoneOutput? output = null;
            try
            {
                output = create(); ready.TrySetResult();
                foreach (var command in commands.GetConsumingEnumerable())
                {
                    try { command.Action(output); command.Completion.TrySetResult(); }
                    catch (Exception error) { command.Completion.TrySetException(error); }
                }
            }
            catch (Exception error) { ready.TrySetException(error); }
            finally
            {
                try { output?.Dispose(); }
                catch (Exception error) { cleanupFailure = ExceptionDispatchInfo.Capture(error); }
            }
        }) { IsBackground = true, Name = "Nocturne microphone" };
        if (OperatingSystem.IsWindows()) worker.SetApartmentState(ApartmentState.MTA);
        worker.Start();
        try { ready.Task.GetAwaiter().GetResult(); }
        catch { worker.Join(); commands.Dispose(); throw; }
    }
    private void Invoke(Action<IMicrophoneOutput> action)
    {
        var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        lock (gate)
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            commands.Add(new(action, completion));
        }
        completion.Task.GetAwaiter().GetResult();
    }
    public void Start() => Invoke(output => output.Start());
    public void Write(byte[] pcm) => Invoke(output => output.Write(pcm));
    public void Stop() => Invoke(output => output.Stop());
    public void Dispose()
    {
        lock (gate)
        {
            if (disposed) return;
            disposed = true; commands.CompleteAdding(); worker.Join(); commands.Dispose();
            cleanupFailure?.Throw();
        }
    }
}
