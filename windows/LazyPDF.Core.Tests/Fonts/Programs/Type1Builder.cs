using System.Text;

namespace LazyPDF.Core.Tests;

public enum Type1Wrapper { Binary, Hex, Pfb }

/// <summary>Writes a small Type 1 font: encrypted private part, Subrs for flex, and glyphs that exercise each charstring operator.</summary>
internal static class Type1Builder
{
    public static readonly string[] GlyphNames = [".notdef", "A", "B", "C", "D", "E", "F", "G"];

    private static byte[] Num(int v)
    {
        if (v >= -107 && v <= 107) return [(byte)(v + 139)];
        if (v >= 108 && v <= 1131) return [(byte)((v - 108) / 256 + 247), (byte)((v - 108) % 256)];
        if (v <= -108 && v >= -1131) return [(byte)((-v - 108) / 256 + 251), (byte)((-v - 108) % 256)];
        return [255, (byte)(v >> 24), (byte)(v >> 16), (byte)(v >> 8), (byte)v];
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
        "closepath" => [9],
        "callsubr" => [10],
        "return" => [11],
        "hsbw" => [13],
        "endchar" => [14],
        "rmoveto" => [21],
        "hmoveto" => [22],
        "vhcurveto" => [30],
        "hvcurveto" => [31],
        "dotsection" => [12, 0],
        "seac" => [12, 6],
        "sbw" => [12, 7],
        "div" => [12, 12],
        "callothersubr" => [12, 16],
        "pop" => [12, 17],
        "setcurrentpoint" => [12, 33],
        _ => throw new ArgumentException(name),
    };

    public static byte[] Code(params object[] parts)
    {
        var bytes = new List<byte>();
        foreach (var part in parts)
            bytes.AddRange(part is int v ? Num(v) : Op((string)part));
        return bytes.ToArray();
    }

    public static byte[] Encrypt(byte[] plain, ushort key, int prefix)
    {
        var data = new byte[prefix + plain.Length];
        plain.CopyTo(data, prefix);
        var r = key;
        for (var i = 0; i < data.Length; i++)
        {
            var c = (byte)(data[i] ^ (r >> 8));
            r = (ushort)((c + r) * 52845 + 22719);
            data[i] = c;
        }
        return data;
    }

    private static readonly byte[][] Subrs =
    [
        Code(3, 0, "callothersubr", "pop", "pop", "setcurrentpoint", "return"),
        Code(0, 1, "callothersubr", "return"),
        Code(0, 2, "callothersubr", "return"),
        Code("return"),
    ];

    private static byte[][] Glyphs()
    {
        var flex = new List<object> { 0, 500, "hsbw", 10, 10, "rmoveto", 1, "callsubr" };
        foreach (var (dx, dy) in new[] { (50, 0), (-30, 0), (10, 5), (10, 0), (10, 0), (10, -5), (10, 0) })
            flex.AddRange([dx, dy, "rmoveto", 2, "callsubr"]);
        flex.AddRange([50, 80, 10, 0, "callsubr", 0, 100, "rlineto", "closepath", "endchar"]);

        return
        [
            Code(0, 250, "hsbw", "endchar"),
            Code(50, 600, "hsbw", 0, 0, "rmoveto", 100, "hlineto", 100, "vlineto", -100, "hlineto", "closepath", "endchar"),
            Code(flex.ToArray()),
            Code(0, 700, "hsbw", 20, 30, 40, 65, 66, "seac"),
            Code(0, 400, "hsbw", 0, 0, "rmoveto", 100, 2, "div", "hlineto", "closepath", "endchar"),
            Code(0, 300, "hsbw", 0, 0, "rmoveto", 3, 1, 3, "callothersubr", "pop", "callsubr", 10, "hlineto", "closepath", "endchar"),
            Code(10, 20, 300, 0, "sbw", 0, 0, "rmoveto", 5, "vlineto", "closepath", "endchar"),
            Code(0, 400, "hsbw", 0, 0, "rmoveto", 10, 0, 0, 10, 10, 0, "rrcurveto", 5, 10, 10, 5, "vhcurveto", 3, 4, 5, 6, "hvcurveto", "closepath", "endchar"),
        ];
    }

    /// <param name="lenIV">Random bytes in front of each charstring; -1 leaves them unencrypted.</param>
    /// <param name="barNames">Use the -| |- | names of the usual font programs for RD, ND and NP.</param>
    public static byte[] Build(Type1Wrapper wrapper, int lenIV = 4, bool barNames = false)
    {
        var rd = barNames ? "-|" : "RD";
        var nd = barNames ? "|-" : "ND";
        var np = barNames ? "|" : "NP";

        var clear = Encoding.Latin1.GetBytes(
            "%!PS-AdobeFont-1.0: TestFont 001.000\n11 dict begin\n" +
            "/FontInfo 2 dict dup begin /Notice (Test /Encoding in a string) readonly def end readonly def\n" +
            "/FontName /TestFont def\n/PaintType 0 def\n/FontType 1 def\n/FontMatrix [0.001 0 0 0.001 0 0] readonly def\n" +
            "/Encoding 256 array\n0 1 255 {1 index exch /.notdef put} for\ndup 65 /A put\ndup 66 /B put\ndup 8#103 /C put\nreadonly def\n" +
            "/FontBBox {-10 -20 900 800} readonly def\ncurrentdict end\ncurrentfile eexec\n");

        var priv = new MemoryStream();
        void Text(string s) => priv.Write(Encoding.Latin1.GetBytes(s));
        byte[] Lock(byte[] cs) => lenIV < 0 ? cs : Encrypt(cs, 4330, lenIV);

        Text($"dup /Private 8 dict dup begin\n/{rd} {{string currentfile exch readstring pop}} executeonly def\n");
        Text($"/{nd} {{noaccess def}} executeonly def\n/{np} {{noaccess put}} executeonly def\n/BlueValues [] def\n/password 5839 def\n");
        if (lenIV != 4) Text($"/lenIV {lenIV} def\n");
        Text($"/Subrs {Subrs.Length} array\n");
        for (var i = 0; i < Subrs.Length; i++)
        {
            var cs = Lock(Subrs[i]);
            Text($"dup {i} {cs.Length} {rd} ");
            priv.Write(cs);
            Text($" {np}\n");
        }
        Text($"{nd}\n2 index /CharStrings {GlyphNames.Length} dict dup begin\n");
        var glyphs = Glyphs();
        for (var i = 0; i < glyphs.Length; i++)
        {
            var cs = Lock(glyphs[i]);
            Text($"/{GlyphNames[i]} {cs.Length} {rd} ");
            priv.Write(cs);
            Text($" {nd}\n");
        }
        Text("end\nend\nreadonly put\nnoaccess put\ndup /FontName get exch definefont pop\nmark currentfile closefile\n");

        var encrypted = Encrypt(priv.ToArray(), 55665, 4);
        var trailer = Encoding.Latin1.GetBytes(string.Concat(Enumerable.Repeat(new string('0', 64) + "\n", 8)) + "cleartomark\n");

        switch (wrapper)
        {
            case Type1Wrapper.Hex:
                var hex = Convert.ToHexString(encrypted);
                var lines = Enumerable.Range(0, (hex.Length + 63) / 64).Select(i => hex.Substring(i * 64, Math.Min(64, hex.Length - i * 64)));
                return [.. clear, .. Encoding.ASCII.GetBytes(string.Join("\n", lines) + "\n"), .. trailer];
            case Type1Wrapper.Pfb:
                return [.. Segment(1, clear), .. Segment(2, encrypted), .. Segment(1, trailer), 0x80, 3];
            default:
                return [.. clear, .. encrypted, .. trailer];
        }
    }

    private static byte[] Segment(byte type, byte[] data) =>
        [0x80, type, (byte)data.Length, (byte)(data.Length >> 8), (byte)(data.Length >> 16), (byte)(data.Length >> 24), .. data];
}
