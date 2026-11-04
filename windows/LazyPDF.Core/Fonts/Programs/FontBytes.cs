namespace LazyPDF.Core;

/// <summary>Big-endian reads that return 0 past the end, so a truncated table gives zeros and never an exception.</summary>
internal static class FontBytes
{
    public static int U8(ReadOnlySpan<byte> d, int o) => o >= 0 && o < d.Length ? d[o] : 0;

    public static int U16(ReadOnlySpan<byte> d, int o) => o >= 0 && o <= d.Length - 2 ? (d[o] << 8) | d[o + 1] : 0;

    public static int I16(ReadOnlySpan<byte> d, int o) => (short)U16(d, o);

    public static int U24(ReadOnlySpan<byte> d, int o) => o >= 0 && o <= d.Length - 3 ? (d[o] << 16) | (d[o + 1] << 8) | d[o + 2] : 0;

    public static uint U32(ReadOnlySpan<byte> d, int o) =>
        o >= 0 && o <= d.Length - 4 ? ((uint)d[o] << 24) | ((uint)d[o + 1] << 16) | ((uint)d[o + 2] << 8) | d[o + 3] : 0;

    /// <summary>A 32-bit offset or length, 0 when it is larger than an int could address.</summary>
    public static int Offset32(ReadOnlySpan<byte> d, int o)
    {
        var v = U32(d, o);
        return v > int.MaxValue ? 0 : (int)v;
    }

    public static void PutU16(Span<byte> d, int o, int v)
    {
        d[o] = (byte)(v >> 8);
        d[o + 1] = (byte)v;
    }

    public static void PutU32(Span<byte> d, int o, uint v)
    {
        d[o] = (byte)(v >> 24);
        d[o + 1] = (byte)(v >> 16);
        d[o + 2] = (byte)(v >> 8);
        d[o + 3] = (byte)v;
    }

    public static string Tag(ReadOnlySpan<byte> d, int o)
    {
        if (o < 0 || o > d.Length - 4) return "";
        Span<char> c = stackalloc char[4];
        for (var i = 0; i < 4; i++) c[i] = (char)d[o + i];
        return new string(c);
    }

    /// <summary>The sum of 32-bit words of the span, the last word padded with zeros (OpenType "Table checksums").</summary>
    public static uint Checksum(ReadOnlySpan<byte> d)
    {
        uint sum = 0;
        var i = 0;
        for (; i + 4 <= d.Length; i += 4) sum += U32(d, i);
        if (i < d.Length)
        {
            uint last = 0;
            for (var k = 0; k < 4; k++) last = (last << 8) | (i + k < d.Length ? d[i + k] : (uint)0);
            sum += last;
        }
        return sum;
    }
}
