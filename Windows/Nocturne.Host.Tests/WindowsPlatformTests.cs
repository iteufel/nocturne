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
public sealed class WindowsPlatformTests(ITestOutputHelper output)
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
        try
        {
            Directory.CreateDirectory(outside); File.WriteAllText(Path.Combine(outside, "secret"), "private");
            using (var folder = new WindowsSharedFolder(root))
            {
                var link = Path.Combine(root, "escape");
                using var command = Process.Start(new ProcessStartInfo("cmd.exe")
                { ArgumentList = { "/d", "/c", "mklink", "/J", link, outside }, UseShellExecute = false, CreateNoWindow = true });
                command!.WaitForExit(); Assert.Equal(0, command.ExitCode);
                Assert.Throws<IOException>(() => folder.List("escape"));
                Assert.Throws<IOException>(() => folder.Read("escape/secret", 0));
                Assert.Throws<IOException>(() => folder.BeginUpload("escape/created", 0));
                Assert.Empty(folder.List(""));
                var child = Path.Combine(root, "child"); Directory.CreateDirectory(child);
                using var upload = folder.BeginUpload("child/pending", 0);
                Assert.Throws<IOException>(() => Directory.Move(child, child + "-renamed"));
                Directory.Delete(link); // Remove only the junction itself before recursive cleanup.
            }
            Assert.True(File.Exists(Path.Combine(outside, "secret")));
        }
        catch (Exception error)
        {
            output.WriteLine("[DEBUG-pr7-junction] Failure before cleanup: " + error);
            throw;
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, true); if (Directory.Exists(outside)) Directory.Delete(outside, true); }
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
