namespace LazyPDF.Core.Tests;

// The other side of the JBIG2 decoder, for tests: the MQ encoder of T.88 Annex E with the integer and symbol id
// encoders of Annex A, and the generic and refinement region procedures run backwards. Written from the
// standard, with its own copy of the templates, so a mistake in the decoder's tables does not cancel out.

/// <summary>A bilevel image, one byte per pixel, 1 black.</summary>
internal sealed class Bm(int width, int height)
{
    public int Width { get; } = width;
    public int Height { get; } = height;
    public byte[] Px { get; } = new byte[width * height];

    public int this[int x, int y]
    {
        get => x < 0 || y < 0 || x >= Width || y >= Height ? 0 : Px[y * Width + x];
        set => Px[y * Width + x] = (byte)value;
    }

    /// <summary>Strokes and blocks like printed text, with a few stray dots, from a fixed seed.</summary>
    public static Bm Text(int width, int height, int seed)
    {
        var bm = new Bm(width, height);
        var random = new Random(seed);
        for (int n = 0; n < width * height / 60 + 3; n++)
        {
            int w = random.Next(1, 9), h = random.Next(1, 14);
            int x = random.Next(width), y = random.Next(height);
            bool hollow = random.Next(3) == 0;
            for (int j = 0; j < h; j++)
            {
                for (int i = 0; i < w; i++)
                {
                    bool edge = i == 0 || j == 0 || i == w - 1 || j == h - 1;
                    if (x + i < width && y + j < height && (!hollow || edge)) bm[x + i, y + j] = 1;
                }
            }
        }
        for (int n = 0; n < width * height / 80; n++) bm[random.Next(width), random.Next(height)] ^= 1;
        return bm;
    }

    /// <summary>Rows made by the same few rows again and again, so that typical prediction has something to find.</summary>
    public static Bm Repeating(int width, int height, int seed)
    {
        var bm = new Bm(width, height);
        var random = new Random(seed);
        for (int y = 0; y < height; y++)
        {
            int copy = y > 0 && random.Next(3) != 0 ? y - 1 : -1;
            for (int x = 0; x < width; x++) bm[x, y] = copy >= 0 ? bm[x, copy] : (random.Next(4) == 0 ? 1 : 0);
        }
        return bm;
    }

    public Bm Sub(int x, int y, int w, int h)
    {
        var part = new Bm(w, h);
        for (int j = 0; j < h; j++)
        {
            for (int i = 0; i < w; i++) part[i, j] = this[x + i, y + j];
        }
        return part;
    }

    public bool SameAs(Bm other) => Width == other.Width && Height == other.Height && Px.AsSpan().SequenceEqual(other.Px);

    /// <summary>What the filter gives for this page: packed rows with black 0.</summary>
    public byte[] Packed()
    {
        int stride = (Width + 7) / 8;
        var bytes = new byte[stride * Height];
        Array.Fill(bytes, (byte)0xff);
        for (int y = 0; y < Height; y++)
        {
            for (int x = 0; x < Width; x++)
            {
                if (Px[y * Width + x] != 0) bytes[y * stride + (x >> 3)] &= (byte)~(0x80 >> (x & 7));
            }
        }
        return bytes;
    }
}

/// <summary>The MQ encoder (E.2) and the context sets of one coded segment, the mirror of <see cref="Jbig2Arith"/>.</summary>
internal sealed class ArithEncoder
{
    private static readonly int[] Qe =
    [
        0x5601, 0x3401, 0x1801, 0x0AC1, 0x0521, 0x0221, 0x5601, 0x5401, 0x4801, 0x3801, 0x3001, 0x2401, 0x1C01, 0x1601, 0x5601,
        0x5401, 0x5101, 0x4801, 0x3801, 0x3401, 0x3001, 0x2801, 0x2401, 0x2201, 0x1C01, 0x1801, 0x1601, 0x1401, 0x1201, 0x1101,
        0x0AC1, 0x09C1, 0x08A1, 0x0521, 0x0441, 0x02A1, 0x0221, 0x0141, 0x0111, 0x0085, 0x0049, 0x0025, 0x0015, 0x0009, 0x0005,
        0x0001, 0x5601,
    ];
    private static readonly int[] Nmps =
    [
        1, 2, 3, 4, 5, 38, 7, 8, 9, 10, 11, 12, 13, 29, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32,
        33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 45, 46,
    ];
    private static readonly int[] Nlps =
    [
        1, 6, 9, 12, 29, 33, 6, 14, 14, 14, 17, 18, 20, 21, 14, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28,
        29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 46,
    ];

    public const int Iadh = 0, Iadw = 1, Iaex = 2, Iaai = 3, Iadt = 4, Iafs = 5, Iads = 6, Iait = 7, Iari = 8, Iardw = 9, Iardh = 10, Iardx = 11, Iardy = 12;

    private readonly List<byte> _out = [0];
    private uint _c;
    private int _a = 0x8000;
    private int _ct = 12;

    public byte[] Gb = new byte[1 << 16];
    public byte[] Gr = new byte[1 << 13];
    private byte[]? _iaid;
    private readonly byte[][] _ints = Enumerable.Range(0, 13).Select(_ => new byte[512]).ToArray();

    public void Bit(byte[] contexts, int pos, int d)
    {
        int index = contexts[pos] >> 1, mps = contexts[pos] & 1;
        int qe = Qe[index];
        _a -= qe;
        if (d == mps)
        {
            if ((_a & 0x8000) == 0)
            {
                if (_a < qe) _a = qe; else _c += (uint)qe;
                index = Nmps[index];
                Renorm();
            }
            else _c += (uint)qe;
        }
        else
        {
            if (_a < qe) _c += (uint)qe; else _a = qe;
            if (index is 0 or 6 or 14) mps = 1 - mps;
            index = Nlps[index];
            Renorm();
        }
        contexts[pos] = (byte)((index << 1) | mps);
    }

    private void Renorm()
    {
        do
        {
            _a <<= 1;
            _c <<= 1;
            if (--_ct == 0) ByteOut();
        } while ((_a & 0x8000) == 0);
    }

    private void ByteOut()
    {
        if (_out[^1] == 0xff)
        {
            _out.Add((byte)(_c >> 20));
            _c &= 0xfffff;
            _ct = 7;
        }
        else if (_c < 0x8000000)
        {
            _out.Add((byte)(_c >> 19));
            _c &= 0x7ffff;
            _ct = 8;
        }
        else
        {
            _out[^1]++;
            if (_out[^1] == 0xff)
            {
                _c &= 0x7ffffff;
                _out.Add((byte)(_c >> 20));
                _c &= 0xfffff;
                _ct = 7;
            }
            else
            {
                _out.Add((byte)(_c >> 19));
                _c &= 0x7ffff;
                _ct = 8;
            }
        }
    }

    /// <summary>E.2.9 FLUSH, ending the data with the marker 0xFF 0xAC.</summary>
    public byte[] Finish()
    {
        uint temp = _c + (uint)_a;
        _c |= 0xffff;
        if (_c >= temp) _c -= 0x8000;
        _c <<= _ct;
        ByteOut();
        _c <<= _ct;
        ByteOut();
        if (_out[^1] == 0xff) _out.RemoveAt(_out.Count - 1);
        _out.Add(0xff);
        _out.Add(0xac);
        return [.. _out.Skip(1)];
    }

    /// <summary>A.2: a value, or null for the out-of-band value.</summary>
    public void Integer(int procedure, long? value)
    {
        var contexts = _ints[procedure];
        int prev = 1;
        void Put(int bit)
        {
            Bit(contexts, prev, bit);
            prev = prev < 256 ? (prev << 1) | bit : (((prev << 1) | bit) & 511) | 256;
        }
        void Bits(long v, int count)
        {
            for (int i = count - 1; i >= 0; i--) Put((int)(v >> i & 1));
        }
        long magnitude = value is { } n ? Math.Abs(n) : 0;
        Put(value is null || value < 0 ? 1 : 0);
        if (magnitude < 4) { Put(0); Bits(magnitude, 2); }
        else if (magnitude < 20) { Put(1); Put(0); Bits(magnitude - 4, 4); }
        else if (magnitude < 84) { Put(1); Put(1); Put(0); Bits(magnitude - 20, 6); }
        else if (magnitude < 340) { Put(1); Put(1); Put(1); Put(0); Bits(magnitude - 84, 8); }
        else if (magnitude < 4436) { Put(1); Put(1); Put(1); Put(1); Put(0); Bits(magnitude - 340, 12); }
        else { Put(1); Put(1); Put(1); Put(1); Put(1); Bits(magnitude - 4436, 32); }
    }

    /// <summary>A.3</summary>
    public void Iaid(int codeLength, int id)
    {
        _iaid ??= new byte[1 << 22];
        int prev = 1;
        for (int i = codeLength - 1; i >= 0; i--)
        {
            int bit = id >> i & 1;
            Bit(_iaid, prev, bit);
            prev = (prev << 1) | bit;
        }
    }
}

internal static class Jbig2Encode
{
    private static readonly int[] Reused = [0x9b25, 0x0795, 0x00e5, 0x0195];

    /// <summary>The nominal adaptive pixels of Figures 3 to 6 and 7.</summary>
    public static int[] DefaultAt(int template) => template == 0 ? [3, -1, -3, -1, 2, -2, -2, -2] : template == 1 ? [3, -1] : [2, -1];

    // Offsets of the template pixels in the order of the context bits from the highest (Figures 3 to 6).
    private static (int X, int Y)[] Pixels(int template, int[] at) => template switch
    {
        0 => [(at[6], at[7]), (-1, -2), (0, -2), (1, -2), (at[4], at[5]), (at[2], at[3]), (-2, -1), (-1, -1), (0, -1), (1, -1), (2, -1), (at[0], at[1]), (-4, 0), (-3, 0), (-2, 0), (-1, 0)],
        1 => [(-1, -2), (0, -2), (1, -2), (2, -2), (-2, -1), (-1, -1), (0, -1), (1, -1), (2, -1), (at[0], at[1]), (-3, 0), (-2, 0), (-1, 0)],
        2 => [(-1, -2), (0, -2), (1, -2), (-2, -1), (-1, -1), (0, -1), (1, -1), (at[0], at[1]), (-2, 0), (-1, 0)],
        _ => [(-3, -1), (-2, -1), (-1, -1), (0, -1), (1, -1), (at[0], at[1]), (-4, 0), (-3, 0), (-2, 0), (-1, 0)],
    };

    /// <summary>6.2: codes <paramref name="bm"/> with the generic region procedure; <paramref name="skip"/> pixels are left out.</summary>
    public static void Generic(ArithEncoder e, Bm bm, int template, bool typicalPrediction, int[]? at = null, Bm? skip = null)
    {
        var pixels = Pixels(template, at ?? DefaultAt(template));
        int ltp = 0;
        for (int y = 0; y < bm.Height; y++)
        {
            if (typicalPrediction)
            {
                bool same = true;
                for (int x = 0; x < bm.Width; x++) same &= bm[x, y] == bm[x, y - 1];
                int next = same ? 1 : 0;
                e.Bit(e.Gb, Reused[template], next ^ ltp);
                ltp = next;
                if (same) continue;
            }
            for (int x = 0; x < bm.Width; x++)
            {
                if (skip is not null && skip[x, y] != 0) continue;
                int label = 0;
                foreach (var (dx, dy) in pixels) label = (label << 1) | bm[x + dx, y + dy];
                e.Bit(e.Gb, label, bm[x, y]);
            }
        }
    }

    /// <summary>6.3: codes <paramref name="bm"/> as a refinement of <paramref name="reference"/>, which sits at (dx, dy) of it.</summary>
    public static void Refinement(ArithEncoder e, Bm bm, int template, Bm reference, int dx, int dy, bool typicalPrediction, int[]? at = null)
    {
        at ??= [-1, -1, -1, -1];
        (int X, int Y)[] coding = template == 0 ? [(0, -1), (1, -1), (-1, 0), (at[0], at[1])] : [(-1, -1), (0, -1), (1, -1), (-1, 0)];
        (int X, int Y)[] refs = template == 0
            ? [(0, -1), (1, -1), (-1, 0), (0, 0), (1, 0), (-1, 1), (0, 1), (1, 1), (at[2], at[3])]
            : [(0, -1), (-1, 0), (0, 0), (1, 0), (0, 1), (1, 1)];
        int ltp = 0;
        for (int y = 0; y < bm.Height; y++)
        {
            bool Typical(int x)
            {
                int center = reference[x - dx, y - dy];
                for (int j = -1; j <= 1; j++)
                {
                    for (int i = -1; i <= 1; i++)
                    {
                        if (reference[x - dx + i, y - dy + j] != center) return false;
                    }
                }
                return true;
            }
            if (typicalPrediction)
            {
                bool row = true;
                for (int x = 0; x < bm.Width && row; x++) row = !Typical(x) || bm[x, y] == reference[x - dx, y - dy];
                int next = row ? 1 : 0;
                e.Bit(e.Gr, template == 0 ? 0x0020 : 0x0008, next ^ ltp);
                ltp = next;
            }
            for (int x = 0; x < bm.Width; x++)
            {
                if (ltp != 0 && Typical(x)) continue;
                int label = 0;
                foreach (var (px, py) in coding) label = (label << 1) | bm[x + px, y + py];
                foreach (var (px, py) in refs) label = (label << 1) | reference[x + px - dx, y + py - dy];
                e.Bit(e.Gr, label, bm[x, y]);
            }
        }
    }
}

/// <summary>Segment and field bytes (7.2 and 7.4).</summary>
internal static class Jbig2Segments
{
    public static byte[] U32(long v) => [(byte)(v >> 24), (byte)(v >> 16), (byte)(v >> 8), (byte)v];

    public static byte[] U16(int v) => [(byte)(v >> 8), (byte)v];

    public static byte[] Cat(params byte[][] parts) => [.. parts.SelectMany(p => p)];

    /// <summary>A segment: header, then data. The page association is page 1, or 0 for the globals.</summary>
    public static byte[] Segment(int number, int type, byte[] data, int[]? referred = null, int page = 1)
    {
        referred ??= [];
        var header = new List<byte>(U32(number)) { (byte)type };
        if (referred.Length <= 4) header.Add((byte)(referred.Length << 5));
        else
        {
            header.AddRange(U32(0xe0000000L | (uint)referred.Length));
            header.AddRange(new byte[(referred.Length + 8) / 8]);
        }
        foreach (int r in referred)
        {
            if (number <= 256) header.Add((byte)r);
            else if (number <= 65536) header.AddRange(U16(r));
            else header.AddRange(U32(r));
        }
        header.Add((byte)page);
        header.AddRange(U32(data.Length));
        return [.. header, .. data];
    }

    public static byte[] PageInfo(int width, int height, int flags = 0) =>
        Cat(U32(width), U32(height), U32(0), U32(0), [(byte)flags], U16(0));

    public static byte[] RegionInfo(int width, int height, int x = 0, int y = 0, int op = 0) =>
        Cat(U32(width), U32(height), U32(x), U32(y), [(byte)op]);

    public static byte[] At(int[] at) => [.. at.Select(v => (byte)(sbyte)v)];

    /// <summary>A generic region segment's data (7.4.6) around the coded bytes.</summary>
    public static byte[] GenericData(Bm bm, byte[] coded, int template, bool mmr, bool typicalPrediction, int[]? at, int x = 0, int y = 0, int op = 0) =>
        Cat(RegionInfo(bm.Width, bm.Height, x, y, op), [(byte)((mmr ? 1 : 0) | template << 1 | (typicalPrediction ? 8 : 0))],
            mmr ? [] : At(at ?? Jbig2Encode.DefaultAt(template)), coded);

    /// <summary>A whole embedded stream: page information and one immediate generic region.</summary>
    public static byte[] Generic(Bm bm, int template, bool typicalPrediction, int[]? at = null)
    {
        var e = new ArithEncoder();
        Jbig2Encode.Generic(e, bm, template, typicalPrediction, at);
        return Cat(Segment(0, 48, PageInfo(bm.Width, bm.Height)), Segment(1, 38, GenericData(bm, e.Finish(), template, false, typicalPrediction, at)));
    }
}
