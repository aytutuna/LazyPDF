using System.Text;

namespace LazyPDF.Core.Tests;

/// <summary>Assembles small CFF programs by hand so the charstring interpreter is tested without a font file.</summary>
internal static class CffBuilder
{
    public static byte[] Num(int v)
    {
        if (v >= -107 && v <= 107) return [(byte)(v + 139)];
        if (v >= 108 && v <= 1131) return [(byte)((v - 108) / 256 + 247), (byte)((v - 108) % 256)];
        return [28, (byte)(v >> 8), (byte)v];
    }

    /// <summary>Numbers and operators: ints become operands, strings are operator names.</summary>
    public static byte[] Code(params object[] parts)
    {
        var bytes = new List<byte>();
        foreach (var part in parts)
        {
            switch (part)
            {
                case int v: bytes.AddRange(Num(v)); break;
                case string op: bytes.AddRange(Op(op)); break;
                case byte[] raw: bytes.AddRange(raw); break;
            }
        }
        return bytes.ToArray();
    }

    private static byte[] Op(string name) => name switch
    {
        "hstem" => [1],
        "vstem" => [3],
        "vmoveto" => [4],
        "rlineto" => [5],
        "hlineto" => [6],
        "vlineto" => [7],
        "rrcurveto" => [8],
        "callsubr" => [10],
        "return" => [11],
        "endchar" => [14],
        "hstemhm" => [18],
        "hintmask" => [19],
        "rmoveto" => [21],
        "hmoveto" => [22],
        "vstemhm" => [23],
        "rcurveline" => [24],
        "rlinecurve" => [25],
        "vvcurveto" => [26],
        "hhcurveto" => [27],
        "callgsubr" => [29],
        "vhcurveto" => [30],
        "hvcurveto" => [31],
        "flex" => [12, 35],
        "hflex" => [12, 34],
        "hflex1" => [12, 36],
        "flex1" => [12, 37],
        "add" => [12, 10],
        "sub" => [12, 11],
        "mul" => [12, 24],
        "div" => [12, 12],
        "dup" => [12, 27],
        "exch" => [12, 28],
        "drop" => [12, 18],
        _ => throw new ArgumentException(name),
    };

    public static byte[] Index(params byte[][] items)
    {
        if (items.Length == 0) return [0, 0];
        var bytes = new List<byte>(U16(items.Length)) { 2 };
        var offset = 1;
        bytes.AddRange(U16(offset));
        foreach (var item in items)
        {
            offset += item.Length;
            bytes.AddRange(U16(offset));
        }
        foreach (var item in items) bytes.AddRange(item);
        return bytes.ToArray();
    }

    private static byte[] Int(int v) => [29, (byte)(v >> 24), (byte)(v >> 16), (byte)(v >> 8), (byte)v];

    /// <summary>A DICT with every operand as a five-byte integer, so its size does not depend on the values.</summary>
    public static byte[] Dict(params (int Op, int[] Operands)[] entries)
    {
        var bytes = new List<byte>();
        foreach (var (op, operands) in entries)
        {
            foreach (var v in operands) bytes.AddRange(Int(v));
            if (op >= 1200) bytes.AddRange([12, (byte)(op - 1200)]);
            else bytes.Add((byte)op);
        }
        return bytes.ToArray();
    }

    private static byte[] Concat(params byte[][] parts) => parts.SelectMany(p => p).ToArray();

    private static byte[] Text(string s) => Encoding.ASCII.GetBytes(s);

    public static readonly byte[] Square = Code(100, 50, 0, "rmoveto", 100, 0, 0, 100, -100, 0, "rlineto", "endchar");

    public static readonly byte[] Curve = Code(10, 20, "rmoveto", -107, "callsubr", "endchar");

    public static readonly byte[] CurveSubr = Code(30, 0, 0, 30, 30, 0, "rrcurveto", "return");

    public static readonly byte[] Masked = Code(0, 10, 20, 10, "hstemhm", "hintmask", new byte[] { 0xC0 }, 100, 100, "rmoveto", 10, 20, "hlineto", "endchar");

    private const int PrivateSize = 18;

    private static byte[] U16(int v) => [(byte)(v >> 8), (byte)v];

    /// <summary>
    /// Glyphs: .notdef, A (width 100 above the nominal), B (a curve through a local subroutine), "custom" (hint mask).
    /// Name-keyed: nominal width 500, default 300.
    /// </summary>
    public static byte[] NameKeyed(byte[]? subr = null)
    {
        var charset = Concat([0], U16(34), U16(35), U16(391));
        var glyphs = Index([14], Square, Curve, Masked);
        var priv = Concat(Dict((20, [300]), (21, [500]), (19, [PrivateSize])), Index(subr ?? CurveSubr));

        byte[] Head(int charsetAt, int glyphsAt, int privAt) => Concat([1, 0, 4, 2], Index(Text("Test")),
            Index(Dict((15, [charsetAt]), (17, [glyphsAt]), (18, [PrivateSize, privAt]), (5, [0, 0, 200, 200]))),
            Index(Text("custom")), Index());

        var h = Head(0, 0, 0).Length;
        return Concat(Head(h, h + charset.Length, h + charset.Length + glyphs.Length), charset, glyphs, priv);
    }

    /// <summary>
    /// CID-keyed: glyphs .notdef, CID 10 (square, FD 0: nominal 500), CID 11 (curve, FD 1: default 350, nominal 700, local subr)
    /// and CID 500 (hint mask, FD 1).
    /// </summary>
    public static byte[] CidKeyed(int[]? topMatrix = null, int[]? fdMatrix = null)
    {
        var charset = Concat([0], U16(10), U16(11), U16(500));
        var select = Concat([3], U16(2), U16(0), [0], U16(2), [1], U16(4));
        var glyphs = Index([14], Square, Curve, Masked);
        var priv0 = Dict((20, [250]), (21, [500]));
        var priv1 = Concat(Dict((20, [350]), (21, [700]), (19, [PrivateSize])), Index(CurveSubr));

        byte[] Head(int charsetAt, int selectAt, int glyphsAt, int fdArrayAt) => Concat([1, 0, 4, 2], Index(Text("Cid")),
            Index(Dict((1230, [391, 392, 0]), (15, [charsetAt]), (17, [glyphsAt]), (1236, [fdArrayAt]), (1237, [selectAt]))
                .Concat(topMatrix is null ? [] : Dict((1207, topMatrix))).ToArray()),
            Index(Text("Adobe"), Text("Identity")), Index());

        byte[] FdArray(int at0, int at1) => Index(
            Dict((18, [priv0.Length, at0])).Concat(fdMatrix is null ? [] : Dict((1207, fdMatrix))).ToArray(), Dict((18, [PrivateSize, at1])));

        var h = Head(0, 0, 0, 0).Length;
        var selectAt = h + charset.Length;
        var glyphsAt = selectAt + select.Length;
        var priv0At = glyphsAt + glyphs.Length;
        var priv1At = priv0At + priv0.Length;
        var fdArrayAt = priv1At + priv1.Length;
        return Concat(Head(h, selectAt, glyphsAt, fdArrayAt), charset, select, glyphs, priv0, priv1, FdArray(priv0At, priv1At));
    }
}
