using System.IO.Compression;

namespace LazyPDF.Core;

/// <summary>The writing side of the filters a writer chooses from.</summary>
public static class PdfFilterEncoders
{
    public static byte[] Flate(ReadOnlySpan<byte> data, CompressionLevel level = CompressionLevel.Optimal)
    {
        using var output = new MemoryStream();
        using (var z = new ZLibStream(output, level, leaveOpen: true)) z.Write(data);
        return output.ToArray();
    }

    /// <summary>Hex digits in upper case and the closing "&gt;".</summary>
    public static byte[] AsciiHex(ReadOnlySpan<byte> data)
    {
        var output = new byte[data.Length * 2 + 1];
        const string digits = "0123456789ABCDEF";
        for (int i = 0; i < data.Length; i++)
        {
            output[i * 2] = (byte)digits[data[i] >> 4];
            output[i * 2 + 1] = (byte)digits[data[i] & 15];
        }
        output[^1] = (byte)'>';
        return output;
    }

    /// <summary>Base-85 text with "z" for a group of four zero bytes and the closing "~&gt;".</summary>
    public static byte[] Ascii85(ReadOnlySpan<byte> data)
    {
        var output = new List<byte>(data.Length / 4 * 5 + 8);
        Span<byte> chars = stackalloc byte[5];
        for (int i = 0; i < data.Length; i += 4)
        {
            int n = Math.Min(4, data.Length - i);
            uint value = 0;
            for (int j = 0; j < 4; j++) value = value << 8 | (j < n ? data[i + j] : (uint)0);
            if (value == 0 && n == 4)
            {
                output.Add((byte)'z');
                continue;
            }
            for (int j = 4; j >= 0; j--)
            {
                chars[j] = (byte)(value % 85 + '!');
                value /= 85;
            }
            for (int j = 0; j < n + 1; j++) output.Add(chars[j]);
        }
        output.AddRange("~>"u8);
        return output.ToArray();
    }

    public static byte[] RunLength(ReadOnlySpan<byte> data)
    {
        var output = new List<byte>(data.Length + data.Length / 64 + 2);
        int i = 0;
        while (i < data.Length)
        {
            int run = 1;
            while (i + run < data.Length && run < 128 && data[i + run] == data[i]) run++;
            if (run >= 2)
            {
                output.Add((byte)(257 - run));
                output.Add(data[i]);
                i += run;
                continue;
            }
            int end = i + 1;
            while (end < data.Length && end - i < 128 && !(end + 1 < data.Length && data[end] == data[end + 1])) end++;
            output.Add((byte)(end - i - 1));
            for (int j = i; j < end; j++) output.Add(data[j]);
            i = end;
        }
        output.Add(128);
        return output.ToArray();
    }

    public static byte[] Lzw(ReadOnlySpan<byte> data, bool earlyChange = true) => LzwCodec.Encode(data, earlyChange);
}
