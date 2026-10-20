using System.Text.Json;
using Xunit;

namespace Nocturne.Host.Tests;

public sealed class HostLifecycleTests
{
    [Fact]
    public async Task EnabledServicesStartOnLaunchAndAllDisabledServicesStayStopped()
    {
        foreach (var flags in new[] { new HostSettings(), new HostSettings { ScreenSharing = false, Terminal = true },
            new HostSettings { ScreenSharing = false, Files = true }, new HostSettings { ScreenSharing = false } })
        {
            var starts = 0;
            await using var model = new HostLifecycle(flags, new Login(), _ => { }, (_, _) => { starts++; return Task.FromResult<IRunningHost>(new Running()); });
            await model.StartAsync(); await model.StartAsync();
            Assert.Equal(flags.HasEnabledServices ? 1 : 0, starts);
            Assert.Equal(flags.HasEnabledServices, model.Running);
        }
    }
    [Fact]
    public async Task ApplyingSettingsRestartsOnceAndDisablingAllServicesStopsTheHost()
    {
        var login = new Login(); var saved = new List<HostSettings>(); var runs = new List<Running>();
        await using var model = new HostLifecycle(new(), login, saved.Add, (_, _) =>
        { var run = new Running(); runs.Add(run); return Task.FromResult<IRunningHost>(run); });
        await model.StartAsync();
        await model.ApplyAsync(model.Settings with { Terminal = true, LaunchAtLogin = true });
        Assert.True(runs[0].Stopped); Assert.Equal(2, runs.Count); Assert.True(login.Enabled);
        await model.ApplyAsync(model.Settings);
        Assert.Equal(2, runs.Count);
        await model.ApplyAsync(model.Settings with { ScreenSharing = false, Terminal = false });
        Assert.True(runs[1].Stopped); Assert.False(model.Running); Assert.Equal(2, saved.Count);
    }
    [Fact]
    public async Task InvalidSettingsAndLoginFailurePreserveTheRunningHost()
    {
        var login = new Login(); var run = new Running(); var saved = 0;
        await using var model = new HostLifecycle(new(), login, _ => saved++, (_, _) => Task.FromResult<IRunningHost>(run));
        await model.StartAsync();
        await Assert.ThrowsAsync<IOException>(() => model.ApplyAsync(model.Settings with { RemoteAccess = true, BrokerURL = "http://example.com" }));
        await Assert.ThrowsAsync<IOException>(() => model.ApplyAsync(model.Settings with { Microphone = true }));
        login.Reject = true;
        await Assert.ThrowsAsync<IOException>(() => model.ApplyAsync(model.Settings with { LaunchAtLogin = true }));
        Assert.Same(run, model.Runtime); Assert.False(run.Stopped); Assert.Equal(0, saved);
    }
    [Fact]
    public void ExistingSettingsKeepStreamingAndNewFeaturesAreOptIn()
    {
        var settings = JsonSerializer.Deserialize<HostSettings>("{\"name\":\"PC\",\"terminal\":true}", Wire.Json)!;
        Assert.True(settings.ScreenSharing); Assert.True(settings.Terminal);
        Assert.False(settings.RemoteAccess); Assert.False(settings.Microphone); Assert.False(settings.HeadlessDisplay);
    }
    [Theory]
    [InlineData("https://relay.example.com", "https://relay.example.com")]
    [InlineData("http://127.0.0.1:47991/", "http://127.0.0.1:47991")]
    public void BrokerValidationMatchesTheSwiftClient(string value, string expected) => Assert.Equal(expected, RemoteAccessInfo.ValidateBroker(value));
    [Theory]
    [InlineData("http://relay.example.com")]
    [InlineData("https://user:password@example.com")]
    [InlineData("https://example.com/path")]
    [InlineData("https://example.com?key=value")]
    public void InvalidBrokersAreRejected(string value) => Assert.Throws<IOException>(() => RemoteAccessInfo.ValidateBroker(value));
    private sealed class Login : ILoginStartup
    {
        public bool Enabled { get; private set; }
        public bool Reject;
        public void SetEnabled(bool value) { if (Reject) throw new IOException("Login registration failed."); Enabled = value; }
    }
    private sealed class Running : IRunningHost
    {
        public bool Stopped;
        public string[] ConnectedDevices => [];
        public RemoteAccessInfo? RemoteAccess => null;
        public string ScreenSharingStatus => "Ready";
        public Task RemoveDeviceAsync(string id, string name, CancellationToken cancellation) => Task.CompletedTask;
        public ValueTask DisposeAsync() { Stopped = true; return ValueTask.CompletedTask; }
    }
}
