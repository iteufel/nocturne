using System.Net;
using Xunit;
namespace Nocturne.Host.Tests;
public sealed class DiscoveryTests
{
    [Fact]
    public void AdvertisementContainsOnlyPublicIdentityAndUsesTheSharedDiscoveryHash()
    {
        var key = Enumerable.Range(0, 32).Select(value => (byte)value).ToArray(); var id = WorkspaceDiscovery.Identifier(key);
        var records = WorkspaceDiscovery.Parse(WorkspaceDiscovery.Announcement(id, Wire.Port, [IPAddress.Parse("192.0.2.10")]));
        Assert.Equal(4, records.Length);
        var srv = Assert.Single(records, record => record.Type == 33); Assert.Equal(Wire.Port, srv.Port);
        var txt = Assert.Single(records, record => record.Type == 16); Assert.Equal("id=" + id, System.Text.Encoding.UTF8.GetString(txt.Data[1..]));
        Assert.Equal("192.0.2.10", new IPAddress(Assert.Single(records, record => record.Type == 1).Data).ToString());
        Assert.Equal("b65fc0b1aa6a472ee24ba6a0f9a3a8f0751ff152b39fcc4418de1a4f35515d42", id);
        Assert.DoesNotContain(Convert.ToBase64String(key), System.Text.Encoding.UTF8.GetString(WorkspaceDiscovery.Announcement(id, Wire.Port, [])));
    }
    [Fact]
    public void DiscoveryRejectsTruncationAndCompressionLoops()
    {
        var bytes = WorkspaceDiscovery.Announcement(new string('a', 64), Wire.Port, [IPAddress.Loopback]);
        Assert.Throws<IOException>(() => WorkspaceDiscovery.Parse(bytes[..^1]));
        var loop = new byte[18]; loop[5] = 1; loop[12] = 0xc0; loop[13] = 12;
        Assert.Throws<IOException>(() => WorkspaceDiscovery.Parse(loop));
        loop[13] = 255; Assert.Throws<IOException>(() => WorkspaceDiscovery.Parse(loop));
        Assert.Throws<IOException>(() => WorkspaceDiscovery.Parse(new byte[9001]));
    }
}
