using System.Diagnostics;
using System.Net;
using System.Net.Http.Headers;
using System.Runtime.Versioning;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.Json.Nodes;

namespace Nocturne.Host;

public static class EngineConfiguration
{
    public static string CredentialHash(string password, string salt) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(password + salt)).Reverse().ToArray());

    public static string Create(string directory, string name)
    {
        if (directory.IndexOfAny(['#', '\n', '\r']) >= 0) throw new IOException("The Nocturne data folder cannot contain # or a line break.");
        var options = new SortedDictionary<string, string>(StringComparer.Ordinal)
        {
            ["sunshine_name"] = name.Replace('\n', ' ').Replace('\r', ' ').Replace("#", ""),
            ["system_tray"] = "disabled", ["upnp"] = "disabled", ["origin_web_ui_allowed"] = "pc",
            ["port"] = "47989", ["min_log_level"] = "2", ["ping_timeout"] = "10000",
            // Desktop capture and hardware encoder selection remain native/automatic.
            ["dd_configuration_option"] = "disabled", ["install_steam_audio_drivers"] = "disabled"
        };
        foreach (var (key, file) in new Dictionary<string, string>
        {
            ["credentials_file"] = "credentials.json", ["file_state"] = "state.json", ["pkey"] = "key.pem",
            ["cert"] = "cert.pem", ["file_apps"] = "apps.json", ["log_path"] = "engine.log"
        }) options[key] = Path.Combine(directory, file);
        return string.Join('\n', options.Select(kv => kv.Key + " = " + kv.Value)) + "\n";
    }
}

[SupportedOSPlatform("windows")]
public sealed class StreamingEngine(string directory) : IStreamingEngine, IAsyncDisposable
{
    private Process? process;
    private WindowsJob? job;
    private HttpClient? api;
    private bool stopping;
    public event Action<string>? UnexpectedExit;
    public string LogPath => Path.Combine(directory, "engine.log");

    public async Task StartAsync(string executable, string name, CancellationToken cancellation)
    {
        if (process != null) throw new InvalidOperationException("The engine is already running.");
        if (!File.Exists(executable)) throw new IOException("The bundled streaming engine is missing. Build with scripts/build-windows.ps1.");
        Directory.CreateDirectory(directory);
        var password = Convert.ToBase64String(RandomNumberGenerator.GetBytes(32));
        var salt = Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(8));
        await File.WriteAllTextAsync(Path.Combine(directory, "credentials.json"), new JsonObject
        { ["username"] = "nocturne", ["salt"] = salt, ["password"] = EngineConfiguration.CredentialHash(password, salt) }.ToJsonString(), cancellation);
        var appsPath = Path.Combine(directory, "apps.json");
        var apps = File.Exists(appsPath) ? JsonNode.Parse(await File.ReadAllTextAsync(appsPath, cancellation))?.AsObject()
            ?? throw new IOException("The application library is invalid.") : new JsonObject { ["apps"] = new JsonArray(new JsonObject { ["name"] = "Desktop" }) };
        apps["env"] ??= new JsonObject();
        await File.WriteAllTextAsync(appsPath, apps.ToJsonString(), cancellation);
        var config = Path.Combine(directory, "engine.conf");
        await File.WriteAllTextAsync(config, EngineConfiguration.Create(directory, name), cancellation);
        stopping = false;
        job = new();
        try
        {
            process = WindowsProcess.Launch(executable, '"' + config + '"', Path.GetDirectoryName(executable)!, job);
            var child = process;
            _ = MonitorAsync(child);
            var deadline = DateTime.UtcNow.AddSeconds(25);
            while (DateTime.UtcNow < deadline)
            {
                cancellation.ThrowIfCancellationRequested();
                if (child.HasExited) throw new IOException("The streaming engine could not start. Check the log and stop any other streaming server.");
                var certPath = Path.Combine(directory, "cert.pem");
                if (api == null && File.Exists(certPath))
                {
                    using var certificate = X509Certificate2.CreateFromPem(await File.ReadAllTextAsync(certPath, cancellation));
                    var expected = certificate.RawData;
                    var handler = new HttpClientHandler
                    {
                        UseProxy = false, AllowAutoRedirect = false, UseCookies = false,
                        ServerCertificateCustomValidationCallback = (request, cert, _, _) =>
                            request.RequestUri?.Host == "127.0.0.1" && request.RequestUri.Port == 47990 &&
                            cert != null && CryptographicOperations.FixedTimeEquals(cert.RawData, expected)
                    };
                    api = new(handler) { BaseAddress = new("https://127.0.0.1:47990"), Timeout = TimeSpan.FromSeconds(4), MaxResponseContentBufferSize = Wire.MaximumFrame };
                    api.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Basic", Convert.ToBase64String(Encoding.UTF8.GetBytes("nocturne:" + password)));
                }
                if (api != null)
                {
                    try
                    {
                        await RequestAsync("/api/pin", null, cancellation);
                        cancellation.ThrowIfCancellationRequested();
                        if (child.HasExited) throw new IOException("The streaming engine stopped during startup. Review the server log.");
                        return;
                    }
                    catch (Exception ex) when (ex is HttpRequestException or IOException or TaskCanceledException && !cancellation.IsCancellationRequested) { }
                }
                await Task.Delay(250, cancellation);
            }
            throw new IOException("The streaming engine did not become ready. Review the log and check that its ports are free.");
        }
        catch { await DisposeAsync(); throw; }
    }

    private async Task MonitorAsync(Process child)
    {
        try
        {
            await child.WaitForExitAsync();
            if (!stopping) UnexpectedExit?.Invoke($"The streaming engine stopped (code {child.ExitCode}). Review the log, then start again.");
        }
        catch (ObjectDisposedException) { }
    }

    private async Task<JsonObject> RequestAsync(string path, JsonObject? body, CancellationToken cancellation)
    {
        var client = api ?? throw new IOException("Start the server first.");
        using var request = new HttpRequestMessage(body == null ? HttpMethod.Get : HttpMethod.Post, path);
        if (body != null)
        {
            request.Headers.Add("Origin", "https://127.0.0.1:47990");
            request.Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json");
        }
        using var response = await client.SendAsync(request, cancellation);
        if (response.StatusCode != HttpStatusCode.OK) throw new IOException("The streaming engine refused the request. Review the server log.");
        return JsonNode.Parse(await response.Content.ReadAsStringAsync(cancellation))?.AsObject() ?? throw new IOException("Invalid streaming engine response.");
    }

    public async Task PairAsync(string pin, string name, string address, CancellationToken cancellation)
    {
        if (pin.Length != 4 || pin.Any(c => c is < '0' or > '9')) throw new IOException("Invalid pairing request.");
        for (var attempt = 0; attempt < 24; attempt++)
        {
            var response = await RequestAsync("/api/pin", null, cancellation);
            var pending = response["pairings"]?.AsArray().OfType<JsonObject>().Where(p => SameAddress(p["address"]?.GetValue<string>(), address)).ToArray() ?? [];
            if (pending.Length > 1) throw new IOException("Several devices are pairing at this address. Scan one device at a time.");
            if (pending.Length == 1)
            {
                var result = await RequestAsync("/api/pin", new() { ["pairing_id"] = pending[0]["id"]?.GetValue<string>(), ["pin"] = pin, ["name"] = name }, cancellation);
                if (result["status"]?.GetValue<bool>() != true) throw new IOException("Video pairing did not complete. Scan a new pairing code.");
                return;
            }
            await Task.Delay(250, cancellation);
        }
        throw new IOException("The video pairing request was not found. Scan a new pairing code.");
    }

    public Device[] SavedDevices()
    {
        var path = Path.Combine(directory, "state.json");
        if (!File.Exists(path)) return [];
        var value = JsonNode.Parse(File.ReadAllBytes(path))?["root"]?["named_devices"];
        if (value == null || value is JsonValue text && text.ToString() == "") return [];
        return value.AsArray().OfType<JsonObject>().Select(d =>
        {
            using var cert = X509Certificate2.CreateFromPem(d["cert"]!.GetValue<string>());
            return new Device(Wire.Fingerprint(cert.RawData), d["name"]?.GetValue<string>() ?? "Device", DateTimeOffset.MinValue);
        }).ToArray();
    }

    public async Task RemoveAsync(string fingerprint, CancellationToken cancellation)
    {
        var path = Path.Combine(directory, "state.json");
        if (!File.Exists(path)) return;
        var value = JsonNode.Parse(await File.ReadAllBytesAsync(path, cancellation))?["root"]?["named_devices"];
        if (value == null || value is JsonValue text && text.ToString() == "") return;
        // Load IDs before any mutation; a certificate can have multiple upstream records.
        var ids = value.AsArray().OfType<JsonObject>().Where(d =>
        {
            using var cert = X509Certificate2.CreateFromPem(d["cert"]!.GetValue<string>());
            return Wire.Fingerprint(cert.RawData) == fingerprint;
        }).Select(d => d["uuid"]!.GetValue<string>()).ToArray();
        foreach (var id in ids)
        {
            var disabled = await RequestAsync("/api/clients/update", new() { ["uuid"] = id, ["enabled"] = false }, cancellation);
            if (disabled["status"]?.GetValue<bool>() != true) throw new IOException("This device could not be disconnected. Retry removal.");
            var removed = await RequestAsync("/api/clients/unpair", new() { ["uuid"] = id }, cancellation);
            if (removed["status"]?.GetValue<bool>() != true) throw new IOException("Access is blocked. Retry removal to finish revoking its streaming certificate.");
        }
    }

    private static bool SameAddress(string? left, string right) => IPAddress.TryParse(left, out var first) && IPAddress.TryParse(right, out var second)
        && first.MapToIPv6().Equals(second.MapToIPv6());

    public async ValueTask DisposeAsync()
    {
        stopping = true;
        api?.Dispose(); api = null;
        job?.Dispose(); job = null;
        var child = process; process = null;
        if (child != null)
        {
            try { await child.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(5)); }
            finally { child.Dispose(); }
        }
    }
}
