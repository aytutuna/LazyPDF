using System.Text;

namespace LazyPDF.Core.Tests;

/// <summary>
/// Assembles a small TrueType font by hand so the parser, the subsetter and the embedder are tested without an
/// installed font. Glyphs: 0 .notdef, 1 A (two contours), 2 B (off-curve starts), 3 a composite of A and the accent
/// with offsets and a scale, 4 the accent, 5 space (empty), 6 a composite by point matching with a 2x2 matrix.
/// The file is Tests/Fixtures/golden/programs/synthetic.ttf; ProgramsGoldenTests checks it against this builder.
/// </summary>
internal static class TrueTypeBuilder
{
    private static byte[] U16(int v) => [(byte)(v >> 8), (byte)v];

    private static byte[] U24(int v) => [(byte)(v >> 16), (byte)(v >> 8), (byte)v];

    private static byte[] U32(uint v) => [(byte)(v >> 24), (byte)(v >> 16), (byte)(v >> 8), (byte)v];

    private static byte[] Cat(params byte[][] parts) => parts.SelectMany(p => p).ToArray();

    private static byte[] Pad(byte[] data, int to)
    {
        var padded = new byte[(data.Length + to - 1) / to * to];
        data.CopyTo(padded, 0);
        return padded;
    }

    private static byte[] Simple(params (int X, int Y, bool On)[][] contours)
    {
        var points = contours.SelectMany(c => c).ToArray();
        var raw = new List<byte>();
        var xd = new List<byte>();
        var yd = new List<byte>();
        int px = 0, py = 0;
        foreach (var p in points)
        {
            var f = (byte)(p.On ? 1 : 0);
            Delta(p.X - px, 0x02, 0x10, ref f, xd);
            Delta(p.Y - py, 0x04, 0x20, ref f, yd);
            raw.Add(f);
            px = p.X;
            py = p.Y;
        }

        var flags = new List<byte>();
        for (var i = 0; i < raw.Count;)
        {
            var run = 1;
            while (i + run < raw.Count && raw[i + run] == raw[i] && run < 256) run++;
            if (run > 1)
            {
                flags.Add((byte)(raw[i] | 8));
                flags.Add((byte)(run - 1));
            }
            else flags.Add(raw[i]);
            i += run;
        }

        var ends = new List<byte>();
        var count = 0;
        foreach (var c in contours)
        {
            count += c.Length;
            ends.AddRange(U16(count - 1));
        }
        return Pad(Cat(U16(contours.Length), U16(points.Min(p => p.X)), U16(points.Min(p => p.Y)), U16(points.Max(p => p.X)), U16(points.Max(p => p.Y)),
            ends.ToArray(), U16(0), flags.ToArray(), xd.ToArray(), yd.ToArray()), 4);
    }

    private static void Delta(int d, int shortBit, int sameBit, ref byte flag, List<byte> data)
    {
        if (d == 0) flag |= (byte)sameBit;
        else if (Math.Abs(d) < 256)
        {
            flag |= (byte)shortBit;
            if (d > 0) flag |= (byte)sameBit;
            data.Add((byte)Math.Abs(d));
        }
        else data.AddRange(U16(d));
    }

    private static byte[] Composite(int xMin, int yMin, int xMax, int yMax, params (int Flags, int Glyph, byte[] Args, byte[] Transform)[] parts) =>
        Pad(Cat(U16(-1), U16(xMin), U16(yMin), U16(xMax), U16(yMax),
            Cat(parts.Select(p => Cat(U16(p.Flags), U16(p.Glyph), p.Args, p.Transform)).ToArray())), 4);

    private static byte[] Glyphs(out int[] offsets)
    {
        var none = Array.Empty<byte>();
        var glyphs = new byte[][]
        {
            Simple([(50, 0, true), (450, 0, true), (450, 700, true), (50, 700, true)]),
            Simple([(0, 0, true), (250, 700, true), (500, 0, true)], [(200, 100, true), (300, 100, true), (250, 400, false)]),
            Simple([(0, 0, false), (400, 0, true), (400, 300, false), (400, 600, true), (0, 600, false)], [(100, 100, false), (300, 100, true), (300, 500, true), (100, 500, true)]),
            Composite(0, 0, 500, 800,
                (0x0001 | 0x0002 | 0x0020, 1, Cat(U16(0), U16(0)), none),
                (0x0001 | 0x0002 | 0x0008, 4, Cat(U16(100), U16(750)), U16(0x2000))),
            Simple([(0, 0, true), (80, 0, true), (80, 80, true), (0, 80, true)]),
            none,
            Composite(0, 0, 500, 800,
                (0x0020 | 0x0080, 1, new byte[] { 0, 0 }, Cat(U16(0x4000), U16(0), U16(0x1000), U16(0x4000))),
                (0x0020, 4, new byte[] { 1, 0 }, none),
                (0x0002, 4, new byte[] { 0xFB, 20 }, none)),
        };
        offsets = new int[glyphs.Length + 1];
        var data = new List<byte>();
        for (var i = 0; i < glyphs.Length; i++)
        {
            offsets[i] = data.Count;
            data.AddRange(glyphs[i]);
        }
        offsets[glyphs.Length] = data.Count;
        return data.ToArray();
    }

    private static byte[] Cmap()
    {
        // (3,1): format 4 with a delta segment and a segment that goes through the glyph ID array.
        int[] ends = [0x20, 0x42, 0xC0, 0x11F, 0x131, 0xFFFF];
        int[] starts = [0x20, 0x41, 0xC0, 0x11F, 0x130, 0xFFFF];
        int[] deltas = [5 - 0x20, 1 - 0x41, 3 - 0xC0, 4 - 0x11F, 0, 1];
        int[] ranges = [0, 0, 0, 0, 4, 0];
        var f4 = Cat(U16(4), U16(16 + 8 * 6 + 4), U16(0), U16(12), U16(8), U16(2), U16(4),
            Cat(ends.Select(v => U16(v)).ToArray()), U16(0), Cat(starts.Select(v => U16(v)).ToArray()),
            Cat(deltas.Select(v => U16(v)).ToArray()), Cat(ranges.Select(v => U16(v)).ToArray()), U16(6), U16(4));

        // (1,0): format 0.
        var map = new byte[256];
        map[0x20] = 5;
        map[0x41] = 1;
        map[0x42] = 2;
        var f0 = Cat(U16(0), U16(262), U16(0), map);

        // (3,10): format 12.
        (uint Start, uint End, uint Glyph)[] groups =
            [(0x20, 0x20, 5), (0x41, 0x42, 1), (0xC0, 0xC0, 3), (0x11F, 0x11F, 4), (0x130, 0x130, 6), (0x131, 0x131, 4), (0x1F600, 0x1F600, 2)];
        var f12 = Cat(U16(12), U16(0), U32(16 + 12 * (uint)groups.Length), U32(0), U32((uint)groups.Length),
            Cat(groups.Select(g => Cat(U32(g.Start), U32(g.End), U32(g.Glyph))).ToArray()));

        // (0,5): format 14, one selector with a default range (A and B) and one non-default mapping.
        var defaults = Cat(U32(1), U24(0x41), [1]);
        var nonDefaults = Cat(U32(1), U24(0x11F), U16(6));
        var f14 = Cat(U16(14), U32(10 + 11 + (uint)defaults.Length + (uint)nonDefaults.Length), U32(1),
            U24(0xFE00), U32(10 + 11), U32(10 + 11 + (uint)defaults.Length), defaults, nonDefaults);

        var subtables = new[] { f14, f0, f4, f12 };
        var ids = new[] { (0, 5), (1, 0), (3, 1), (3, 10) };
        var offset = 4 + 8 * subtables.Length;
        var directory = new List<byte>();
        for (var i = 0; i < subtables.Length; i++)
        {
            directory.AddRange(Cat(U16(ids[i].Item1), U16(ids[i].Item2), U32((uint)offset)));
            offset += subtables[i].Length;
        }
        return Cat(U16(0), U16(subtables.Length), directory.ToArray(), Cat(subtables));
    }

    private static byte[] Post()
    {
        string[] custom = ["Alt", "acutecomb", "Amatched"];
        // ".notdef", A, B from the Macintosh order, three custom names, space.
        int[] index = [0, 36, 37, 258, 259, 3, 260];
        var names = Cat(custom.Select(n => Cat([(byte)n.Length], Encoding.ASCII.GetBytes(n))).ToArray());
        return Cat(U32(0x00020000), U16(-12), U16(0x8000), U16(-100), U16(50), U32(0), U32(0), U32(0), U32(0), U32(0),
            U16(index.Length), Cat(index.Select(i => U16(i)).ToArray()), names);
    }

    private static byte[] Name()
    {
        (int Platform, int Encoding, int Language, int Id, byte[] Text)[] records =
        [
            (1, 0, 0, 1, Encoding.Latin1.GetBytes("Mac Family")),
            (3, 1, 0x409, 1, Encoding.BigEndianUnicode.GetBytes("Test Sans")),
            (3, 1, 0x409, 6, Encoding.BigEndianUnicode.GetBytes("TestSans-Regular")),
        ];
        var storage = new List<byte>();
        var directory = new List<byte>();
        foreach (var r in records)
        {
            directory.AddRange(Cat(U16(r.Platform), U16(r.Encoding), U16(r.Language), U16(r.Id), U16(r.Text.Length), U16(storage.Count)));
            storage.AddRange(r.Text);
        }
        return Cat(U16(0), U16(records.Length), U16(6 + 12 * records.Length), directory.ToArray(), storage.ToArray());
    }

    /// <summary>The font: 1000 units per em, ascent 800, descent -200, weight 700, italic angle -11.5.</summary>
    public static byte[] Build()
    {
        var glyphs = Glyphs(out var offsets);
        var loca = Cat(offsets.Select(o => U16(o / 2)).ToArray());
        var head = Cat(U32(0x00010000), U32(0x00010000), U32(0), U32(0x5F0F3CF5), U16(3), U16(1000), new byte[16],
            U16(0), U16(-100), U16(500), U16(800), U16(1), U16(8), U16(2), U16(0), U16(0));
        var hhea = Cat(U32(0x00010000), U16(800), U16(-200), U16(100), U16(600), new byte[22], U16(5));
        var maxp = Cat(U32(0x00010000), U16(7), new byte[26]);
        var advances = new[] { 500, 600, 550, 600, 250 };
        var hmtx = Cat(Cat(advances.Select(a => Cat(U16(a), U16(10))).ToArray()), U16(20), U16(30));
        var os2 = Cat(U16(2), U16(520), U16(700), U16(5), U16(0), new byte[58], U16(800), U16(-200), U16(100), U16(850), U16(250), new byte[8],
            U16(500), U16(700), new byte[6]);

        var tables = new SortedDictionary<string, byte[]>(StringComparer.Ordinal)
        {
            ["OS/2"] = os2,
            ["cmap"] = Cmap(),
            ["cvt "] = Cat(U16(10), U16(20), U16(30)),
            ["fpgm"] = [0xB0, 0x00, 0x2C],
            ["glyf"] = glyphs,
            ["head"] = head,
            ["hhea"] = hhea,
            ["hmtx"] = hmtx,
            ["loca"] = loca,
            ["maxp"] = maxp,
            ["name"] = Name(),
            ["post"] = Post(),
            ["prep"] = [0xB8, 0x01, 0xFF],
        };

        return File(tables);
    }

    private static byte[] File(SortedDictionary<string, byte[]> tables)
    {
        var file = new List<byte>(Cat(U32(0x00010000), U16(tables.Count), U16(128), U16(3), U16(tables.Count * 16 - 128)));
        var at = 12 + 16 * tables.Count;
        var body = new List<byte>();
        foreach (var (tag, data) in tables)
        {
            file.AddRange(Cat(Encoding.ASCII.GetBytes(tag), U32(0), U32((uint)(at + body.Count)), U32((uint)data.Length)));
            body.AddRange(Pad(data, 4));
        }
        file.AddRange(body);
        return file.ToArray();
    }

    /// <summary>
    /// A font for the shaping tests: a box glyph for each character of <see cref="ScriptCodePoints"/> (glyph IDs from 1 in that
    /// order), Hebrew points and the Arabic fatha with no advance, and three glyphs no cmap entry reaches: the lam-alef
    /// ligature, beh in its initial form and beh in its final form (<see cref="LamAlef"/>, <see cref="BehInitial"/>, <see cref="BehFinal"/>).
    /// 1000 units per em; the family is "Script Sans".
    /// </summary>
    public static byte[] BuildScript()
    {
        var cps = ScriptCodePoints;
        int count = 1 + cps.Length + 3;
        var glyphs = new List<byte[]> { Array.Empty<byte>() };
        var advances = new List<int> { 500 };
        var lsb = new List<int> { 0 };
        foreach (int cp in cps)
        {
            int advance = ScriptAdvance(cp);
            advances.Add(advance);
            if (cp == 0x20)
            {
                glyphs.Add(Array.Empty<byte>());
                lsb.Add(0);
            }
            else if (advance == 0)
            {
                glyphs.Add(Simple([(-300, 800, true), (-100, 800, true), (-100, 900, true), (-300, 900, true)]));
                lsb.Add(-300);
            }
            else
            {
                glyphs.Add(Simple([(50, 0, true), (advance - 50, 0, true), (advance - 50, 700, true), (50, 700, true)]));
                lsb.Add(50);
            }
        }
        foreach (int advance in new[] { 900, 600, 640 })
        {
            advances.Add(advance);
            glyphs.Add(Simple([(50, 0, true), (advance - 50, 0, true), (advance - 50, 700, true), (50, 700, true)]));
            lsb.Add(50);
        }

        var offsets = new List<int>();
        var glyf = new List<byte>();
        foreach (var g in glyphs)
        {
            offsets.Add(glyf.Count);
            glyf.AddRange(g);
        }
        offsets.Add(glyf.Count);

        var groups = Cat(cps.Select((cp, i) => Cat(U32((uint)cp), U32((uint)cp), U32((uint)(i + 1)))).ToArray());
        var cmap = Cat(U16(0), U16(1), U16(3), U16(10), U32(12), U16(12), U16(0), U32((uint)(16 + groups.Length)), U32(0), U32((uint)cps.Length), groups);

        var tables = new SortedDictionary<string, byte[]>(StringComparer.Ordinal)
        {
            ["OS/2"] = Cat(U16(2), U16(520), U16(400), U16(5), U16(0), new byte[58], U16(800), U16(-200), U16(100), U16(850), U16(250), new byte[8],
                U16(500), U16(700), new byte[6]),
            ["cmap"] = cmap,
            ["glyf"] = glyf.ToArray(),
            ["head"] = Cat(U32(0x00010000), U32(0x00010000), U32(0), U32(0x5F0F3CF5), U16(3), U16(1000), new byte[16],
                U16(-300), U16(-100), U16(900), U16(900), U16(0), U16(8), U16(2), U16(0), U16(0)),
            ["hhea"] = Cat(U32(0x00010000), U16(800), U16(-200), U16(100), U16(900), new byte[22], U16(count)),
            ["hmtx"] = Cat(Enumerable.Range(0, count).Select(i => Cat(U16(advances[i]), U16(lsb[i]))).ToArray()),
            ["loca"] = Cat(offsets.Select(o => U16(o / 2)).ToArray()),
            ["maxp"] = Cat(U32(0x00010000), U16(count), new byte[26]),
            ["name"] = Cat(U16(0), U16(2), U16(6 + 24),
                Cat(U16(3), U16(1), U16(0x409), U16(1), U16(22), U16(0)), Cat(U16(3), U16(1), U16(0x409), U16(6), U16(36), U16(22)),
                Encoding.BigEndianUnicode.GetBytes("Script Sans"), Encoding.BigEndianUnicode.GetBytes("ScriptSans-Regular")),
            ["post"] = Cat(U32(0x00030000), U32(0), U16(-100), U16(50), new byte[20]),
        };
        return File(tables);
    }

    /// <summary>Space, punctuation, digits, Latin letters, Hebrew letters and points, and a few Arabic letters, in code point order.</summary>
    public static readonly int[] ScriptCodePoints = new[] { 0x20, 0x21, 0x28, 0x29, 0x2C, 0x2D, 0x2E, 0x3A, 0x3C, 0x3E, 0x5B, 0x5D, 0x627, 0x628, 0x644, 0x645, 0x64E }
        .Concat(Enumerable.Range('0', 10)).Concat(Enumerable.Range('A', 26)).Concat(Enumerable.Range('a', 26))
        .Concat(Enumerable.Range(0x5B0, 13)).Concat(Enumerable.Range(0x5D0, 27)).Order().ToArray();

    public static int Gid(int codePoint) => Array.IndexOf(ScriptCodePoints, codePoint) + 1;

    public static int LamAlef => 1 + ScriptCodePoints.Length;

    public static int BehInitial => LamAlef + 1;

    public static int BehFinal => LamAlef + 2;

    public static int ScriptAdvance(int cp) => cp switch
    {
        0x20 => 250,
        >= 0x30 and <= 0x39 => 550,
        0x21 or 0x28 or 0x29 or 0x2C or 0x2D or 0x2E or 0x3A or 0x5B or 0x5D => 300,
        0x3C or 0x3E => 500,
        >= 0x5B0 and <= 0x5BC or 0x64E => 0,
        _ => 400 + cp * 37 % 9 * 40,
    };
}
