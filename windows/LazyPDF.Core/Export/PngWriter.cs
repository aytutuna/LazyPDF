using System.IO.Compression;

namespace LazyPDF.Core;

/// <summary>A PNG encoder for 8-bit pixels: gray, RGB or RGBA, whichever the pixels need, rows filtered adaptively.</summary>
public static class PngWriter
{
    private static readonly byte[] Signature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

    /// <exception cref="ArgumentException">The size is not positive or does not fit the data.</exception>
    public static byte[] Encode(PdfRgbaImage image)
    {
        int width = image.Width, height = image.Height;
        if (width < 1 || height < 1 || (long)width * height * 4 != image.Rgba.Length) throw new ArgumentException("The pixel data does not fit the size.", nameof(image));
        var rgba = image.Rgba;
        bool opaque = true, gray = true;
        for (int i = 0; i < rgba.Length; i += 4)
        {
            if (rgba[i + 3] != 255) opaque = false;
            if (rgba[i] != rgba[i + 1] || rgba[i] != rgba[i + 2]) gray = false;
        }
        int channels = gray && opaque ? 1 : opaque ? 3 : 4;
        byte colorType = channels switch { 1 => 0, 3 => 2, _ => 6 };

        int stride = width * channels;
        var pixels = new byte[height * stride];
        for (int y = 0; y < height; y++)
        {
            for (int x = 0; x < width; x++)
            {
                int s = (y * width + x) * 4, d = y * stride + x * channels;
                pixels[d] = rgba[s];
                if (channels == 1) continue;
                pixels[d + 1] = rgba[s + 1];
                pixels[d + 2] = rgba[s + 2];
                if (channels == 4) pixels[d + 3] = rgba[s + 3];
            }
        }

        using var data = new MemoryStream();
        using (var z = new ZLibStream(data, CompressionLevel.Optimal, leaveOpen: true))
        {
            var filtered = new byte[stride];
            var best = new byte[stride];
            for (int y = 0; y < height; y++)
            {
                var row = pixels.AsSpan(y * stride, stride);
                var above = y == 0 ? default : pixels.AsSpan((y - 1) * stride, stride);
                byte bestType = 0;
                long bestCost = long.MaxValue;
                for (byte type = 0; type <= 4; type++)
                {
                    Filter(type, row, above, channels, filtered);
                    long cost = 0;
                    foreach (byte b in filtered) cost += b < 128 ? b : 256 - b;
                    if (cost >= bestCost) continue;
                    bestCost = cost;
                    bestType = type;
                    (filtered, best) = (best, filtered);
                }
                z.WriteByte(bestType);
                z.Write(best);
            }
        }

        using var png = new MemoryStream();
        png.Write(Signature);
        var header = new byte[13];
        WriteInt(header, 0, width);
        WriteInt(header, 4, height);
        header[8] = 8;
        header[9] = colorType;
        Chunk(png, "IHDR"u8, header);
        Chunk(png, "IDAT"u8, data.ToArray());
        Chunk(png, "IEND"u8, []);
        return png.ToArray();
    }

    // ISO/IEC 15948 9.2 (the five filter types); `above` is empty for the first row.
    private static void Filter(byte type, ReadOnlySpan<byte> row, ReadOnlySpan<byte> above, int bpp, byte[] output)
    {
        for (int i = 0; i < row.Length; i++)
        {
            int a = i >= bpp ? row[i - bpp] : 0;
            int b = above.IsEmpty ? 0 : above[i];
            int c = i >= bpp && !above.IsEmpty ? above[i - bpp] : 0;
            int predicted = type switch
            {
                0 => 0,
                1 => a,
                2 => b,
                3 => (a + b) / 2,
                _ => Paeth(a, b, c),
            };
            output[i] = (byte)(row[i] - predicted);
        }
    }

    private static int Paeth(int a, int b, int c)
    {
        int p = a + b - c;
        int pa = Math.Abs(p - a), pb = Math.Abs(p - b), pc = Math.Abs(p - c);
        return pa <= pb && pa <= pc ? a : pb <= pc ? b : c;
    }

    private static void Chunk(Stream output, ReadOnlySpan<byte> type, byte[] body)
    {
        var length = new byte[4];
        WriteInt(length, 0, body.Length);
        output.Write(length);
        output.Write(type);
        output.Write(body);
        uint crc = ExportZip.Crc32(body, ExportZip.Crc32(type));
        WriteInt(length, 0, (int)crc);
        output.Write(length);
    }

    private static void WriteInt(byte[] buffer, int at, int value)
    {
        buffer[at] = (byte)(value >> 24);
        buffer[at + 1] = (byte)(value >> 16);
        buffer[at + 2] = (byte)(value >> 8);
        buffer[at + 3] = (byte)value;
    }
}
