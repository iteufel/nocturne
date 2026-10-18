using System.Net;
using System.Text.Json;
using Nocturne.Host;

// Test-only listener: exercises the actual Windows protocol implementation from Swift.
// Ephemeral test secrets are exchanged through inherited pipes, never command-line arguments.
var root = Path.Combine(Path.GetTempPath(), "nocturne-interop-" + Guid.NewGuid());
try
{
    var secret = Convert.FromBase64String(Console.ReadLine() ?? throw new IOException("Missing test key."));
    var devices = new DeviceStore(Path.Combine(root, "devices.json"));
    await using var server = new WorkspaceServer("Windows interop host", secret, devices, new(), null,
        (_, _) => throw new IOException("Terminal is disabled in the interoperability fixture."));
    server.SessionError += message => Console.Error.WriteLine(message);
    server.Start(0, IPAddress.Loopback);
    Console.WriteLine(JsonSerializer.Serialize(new { port = server.Port, token = devices.CreateInvitation() }, Wire.Json));
    while (Console.ReadLine() != null) { }
}
finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
