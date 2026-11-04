using System.Buffers.Text;
using System.IO.Compression;

namespace LazyPDF.Core;

// The embedded tables are raw-deflated and base64 encoded; this undoes both.
internal static class TableBlob
{
    public static byte[] Inflate(string base64) => Inflate(Convert.FromBase64String(base64));

    public static byte[] InflateUtf8(ReadOnlySpan<byte> base64)
    {
        var packed = new byte[Base64.GetMaxDecodedFromUtf8Length(base64.Length)];
        Base64.DecodeFromUtf8(base64, packed, out _, out int written);
        return Inflate(packed.AsSpan(0, written).ToArray());
    }

    public static string InflateText(string base64) => System.Text.Encoding.UTF8.GetString(Inflate(base64));

    static byte[] Inflate(byte[] packed)
    {
        using var input = new MemoryStream(packed);
        using var deflate = new DeflateStream(input, CompressionMode.Decompress);
        using var output = new MemoryStream();
        deflate.CopyTo(output);
        return output.ToArray();
    }
}
