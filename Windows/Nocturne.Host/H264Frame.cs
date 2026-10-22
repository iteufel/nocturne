using System.Buffers.Binary;

namespace Nocturne.Host;

/// Normalize Windows Media Foundation byte-stream output to the client's AVCC access units.
public sealed class H264Frame
{
    private byte[]? sps, pps;
    public AppVideo Convert(byte[] data, byte[] header, double timestamp)
    {
        if (!double.IsFinite(timestamp) || data.Length is 0 or > 4_194_304 || header.Length > 8192) throw new IOException("Invalid app video frame.");
        if (header.Length != 0) foreach (var nal in Units(header)) Parameter(nal);
        using var output = new MemoryStream();
        Span<byte> length = stackalloc byte[4];
        foreach (var nal in Units(data))
        {
            if (Parameter(nal)) continue;
            BinaryPrimitives.WriteInt32BigEndian(length, nal.Length);
            output.Write(length); output.Write(nal);
        }
        if (sps == null || pps == null || output.Length is 0 or > 4_194_304) throw new IOException("The video encoder did not provide H.264 parameter sets.");
        return new(output.ToArray(), [sps, pps], timestamp);
    }
    private bool Parameter(byte[] nal)
    {
        if (nal.Length == 0) throw new IOException("Invalid H.264 unit.");
        var type = nal[0] & 31;
        if (type is not (7 or 8)) return false;
        if (nal.Length > 4096) throw new IOException("Invalid H.264 parameter set.");
        if (type == 7) sps = nal; else pps = nal;
        return true;
    }
    private static IEnumerable<byte[]> Units(byte[] data)
    {
        static int Prefix(byte[] bytes, int at) => at + 3 < bytes.Length && bytes[at] == 0 && bytes[at + 1] == 0 && bytes[at + 2] == 0 && bytes[at + 3] == 1 ? 4 :
            at + 2 < bytes.Length && bytes[at] == 0 && bytes[at + 1] == 0 && bytes[at + 2] == 1 ? 3 : 0;
        var first = Prefix(data, 0);
        if (first != 0)
        {
            var at = first;
            for (var i = first; i <= data.Length; i++)
            {
                var prefix = i < data.Length ? Prefix(data, i) : 0;
                if (i != data.Length && prefix == 0) continue;
                var end = i;
                while (end > at && data[end - 1] == 0) end--;
                if (end > at) yield return data[at..end];
                if (i == data.Length) yield break;
                i += prefix - 1; at = i + 1;
            }
        }
        else
        {
            var at = 0;
            while (at < data.Length)
            {
                if (data.Length - at < 4) throw new IOException("Invalid H.264 length.");
                var length = BinaryPrimitives.ReadInt32BigEndian(data.AsSpan(at, 4)); at += 4;
                if (length <= 0 || length > data.Length - at) throw new IOException("Invalid H.264 length.");
                yield return data[at..(at + length)]; at += length;
            }
        }
    }
}
