using System.Diagnostics;
using System.Runtime.Versioning;
using System.Text;
using System.Text.Json;
using Xunit;
using Xunit.Abstractions;

namespace Nocturne.Host.Tests;

public sealed class WindowsFactAttribute : FactAttribute
{
    public WindowsFactAttribute() { if (!OperatingSystem.IsWindows()) Skip = "Requires a Windows desktop runner."; }
}

[SupportedOSPlatform("windows")]
public sealed class WindowsPlatformTests(ITestOutputHelper testOutput)
{
    [WindowsFact]
    public void TransfersAreHiddenBoundedAndNeverOverwrite()
    {
        var root = Path.Combine(Path.GetTempPath(), "nocturne-files-" + Guid.NewGuid());
        try
        {
            using (var folder = new WindowsSharedFolder(root))
            {
                using (var cancelled = folder.BeginUpload("cancelled.txt", 3))
                { cancelled.Append([1], 0); Assert.Empty(folder.List("")); }
                using var upload = folder.BeginUpload("hello.txt", 5);
                Assert.Throws<IOException>(() => upload.Append([1], 1));
                upload.Append(Encoding.UTF8.GetBytes("hello"), 0); upload.Commit();
                Assert.Equal("hello", Encoding.UTF8.GetString(folder.Read("hello.txt", 0).Data));
                Assert.Equal("hello.txt", Assert.Single(folder.List("")).Name);
                Assert.Throws<IOException>(() => folder.BeginUpload("hello.txt", 0));
                using var race = folder.BeginUpload("race.txt", 3); race.Append([1, 2, 3], 0);
                File.WriteAllText(Path.Combine(root, "race.txt"), "original");
                Assert.Throws<IOException>(() => race.Commit());
                Assert.Equal("original", File.ReadAllText(Path.Combine(root, "race.txt")));
            }
            Assert.DoesNotContain(Directory.EnumerateFiles(root), p => Path.GetFileName(p).StartsWith(".nocturne-upload-"));
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
    }

    [WindowsFact]
    public void JunctionsAndDirectoryReplacementAreRejected()
    {
        var root = Path.Combine(Path.GetTempPath(), "nocturne-junction-" + Guid.NewGuid());
        var outside = root + "-outside";
        var link = Path.Combine(root, "escape");
        var child = Path.Combine(root, "child");
        try
        {
            Directory.CreateDirectory(outside); File.WriteAllText(Path.Combine(outside, "secret"), "private");
            using (var folder = new WindowsSharedFolder(root))
            {
                using var command = Process.Start(new ProcessStartInfo("cmd.exe")
                { ArgumentList = { "/d", "/c", "mklink", "/J", link, outside }, UseShellExecute = false, CreateNoWindow = true });
                command!.WaitForExit(); Assert.Equal(0, command.ExitCode);
                Assert.Throws<IOException>(() => folder.List("escape"));
                Assert.Throws<IOException>(() => folder.Read("escape/secret", 0));
                Assert.Throws<IOException>(() => folder.BeginUpload("escape/created", 0));
                Assert.Empty(folder.List(""));
                Directory.CreateDirectory(child);
                using (var upload = folder.BeginUpload("child/pending", 0))
                    Assert.Throws<IOException>(() => Directory.Move(child, child + "-renamed"));
                using var completed = folder.BeginUpload("child/complete", 3);
                completed.Append([1, 2, 3], 0); completed.Commit();
                Assert.Equal(new byte[] { 1, 2, 3 }, folder.Read("child/complete", 0).Data);
            }
            Directory.Move(child, child + "-renamed"); // Disposing the guards releases the directories.
            Assert.True(File.Exists(Path.Combine(outside, "secret")));
        }
        finally
        {
            // Delete the junction itself without recursion, including when an assertion
            // fails. .NET 10 recursive cleanup can otherwise mask the original failure.
            if (Directory.Exists(link)) Directory.Delete(link);
            if (Directory.Exists(root)) Directory.Delete(root, true);
            if (Directory.Exists(outside)) Directory.Delete(outside, true);
        }
    }

    [WindowsFact]
    public async Task ConPtyRunsPowerShellResizesAndDrainsBeforeExit()
    {
        using var terminal = new ConPtyTerminal(80, 24);
        var output = new MemoryStream(); var gate = new object();
        var ended = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        terminal.Output += bytes => { lock (gate) output.Write(bytes); };
        terminal.Exited += () => ended.TrySetResult();
        terminal.Start(); terminal.Resize(100, 30);
        // The echoed command contains only base64, so it cannot satisfy the output assertion.
        terminal.Input(Encoding.UTF8.GetBytes("[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('Tk9DVFVSTkVfUFRZX09L')); exit\r"));
        await ended.Task.WaitAsync(TimeSpan.FromSeconds(20));
        await terminal.Completion;
        lock (gate)
        {
            var captured = Encoding.UTF8.GetString(output.ToArray());
            Assert.True(captured.Contains("NOCTURNE_PTY_OK", StringComparison.Ordinal),
                "ConPTY output did not contain the command result: " + JsonSerializer.Serialize(captured));
        }
    }

    [WindowsFact]
    public async Task ConPtyAcceptsCommandsAfterThePrompt()
    {
        using var terminal = new ConPtyTerminal(80, 24);
        var captured = new StringBuilder(); var gate = new object();
        var prompt = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var result = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        terminal.Output += bytes =>
        {
            lock (gate)
            {
                captured.Append(Encoding.UTF8.GetString(bytes));
                var text = captured.ToString();
                if (text.Contains("PS ", StringComparison.Ordinal)) prompt.TrySetResult();
                if (text.Contains("NOCTURNE_PTY_OK", StringComparison.Ordinal)) result.TrySetResult();
            }
        };
        terminal.Start();
        try
        {
            await prompt.Task.WaitAsync(TimeSpan.FromSeconds(15));
            terminal.Resize(100, 30);
            terminal.Input(Encoding.UTF8.GetBytes("[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('Tk9DVFVSTkVfUFRZX09L'))\r"));
            await result.Task.WaitAsync(TimeSpan.FromSeconds(15));
            terminal.Input(Encoding.UTF8.GetBytes("exit\r"));
            await terminal.Completion.WaitAsync(TimeSpan.FromSeconds(15));
        }
        finally
        {
            lock (gate) testOutput.WriteLine("ConPTY output: " + JsonSerializer.Serialize(captured.ToString()));
        }
    }

    [WindowsFact]
    public void WorkspaceKeyIsProtectedForTheCurrentWindowsUser()
    {
        var root = Path.Combine(Path.GetTempPath(), "nocturne-key-" + Guid.NewGuid());
        try
        {
            var storage = new HostStorage(root); var secret = storage.LoadSecret();
            Assert.Equal(secret, new HostStorage(root).LoadSecret());
            Assert.NotEqual(secret, File.ReadAllBytes(Path.Combine(root, "workspace.key")));
            Assert.Equal(32, secret.Length);
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
    }
}
