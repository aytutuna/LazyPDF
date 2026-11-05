using System.Text;
using LazyPDF.Core;

namespace LazyPDF.Core.Tests;

// Mirrored by Tests/LazyPDFKitTests/Fonts/Programs/ProgramsGolden.swift. The dumps are text, one fact per line;
// numbers go through PdfNumber so that both sides print the same digits.
internal static class ProgramsGolden
{
    private static string N(double v) => new PdfNumber(v).Text;

    private static string B(bool v) => v ? "true" : "false";

    private static string S(string? v) => v ?? "null";

    private static string Box(GlyphBounds? b) => b is { } v ? $"{N(v.XMin)} {N(v.YMin)} {N(v.XMax)} {N(v.YMax)}" : "null";

    private static string Hex(byte[] d) => Convert.ToHexString(d).ToLowerInvariant();

    private static string Seg(OutlineSegment s) => s.Op switch
    {
        OutlineOp.Move => $"M {N(s.X)} {N(s.Y)}",
        OutlineOp.Line => $"L {N(s.X)} {N(s.Y)}",
        OutlineOp.Quad => $"Q {N(s.X1)} {N(s.Y1)} {N(s.X)} {N(s.Y)}",
        OutlineOp.Cubic => $"C {N(s.X1)} {N(s.Y1)} {N(s.X2)} {N(s.Y2)} {N(s.X)} {N(s.Y)}",
        _ => "Z",
    };

    private static string Outline(GlyphOutline? o) => o is null ? "null" : o.IsEmpty ? "empty" : string.Join(" ", o.Segments.Select(Seg));

    private static void HexLines(StringBuilder sb, byte[] data)
    {
        var hex = Hex(data);
        for (var i = 0; i < hex.Length; i += 128) sb.Append("  ").Append(hex, i, Math.Min(128, hex.Length - i)).Append('\n');
    }

    private static string Pairs(IEnumerable<KeyValuePair<int, int>> map) =>
        string.Join(",", map.OrderBy(p => p.Key).Select(p => $"{p.Key}:{p.Value}"));

    public static string StandardNamesDump()
    {
        var sb = new StringBuilder();
        for (var i = 0; i < StandardNames.CffStrings.Length; i++) sb.Append("cff ").Append(i).Append(' ').Append(StandardNames.CffStrings[i]).Append('\n');
        for (var i = 0; i < StandardNames.MacGlyphs.Length; i++) sb.Append("mac ").Append(i).Append(' ').Append(StandardNames.MacGlyphs[i]).Append('\n');
        for (var c = 0; c < 256; c++)
            sb.Append("std ").Append(c).Append(' ').Append(S(StandardNames.StandardEncoding[c])).Append(' ').Append(StandardNames.StandardEncodingSids[c]).Append('\n');
        return sb.ToString();
    }

    public static string TrueType(byte[] data)
    {
        var sb = new StringBuilder();
        void L(string s) => sb.Append(s).Append('\n');
        var f = TrueTypeFont.TryParse(data)!;
        L($"collection {TrueTypeFont.CollectionCount(data)}");
        L($"upem {f.UnitsPerEm} glyphs {f.GlyphCount} ascent {f.Ascent} descent {f.Descent} lineGap {f.LineGap}");
        L($"cap {f.CapHeight} x {f.XHeight} bounds {Box(f.FontBounds)} italic {N(f.ItalicAngle)} fixed {B(f.IsFixedPitch)} bold {B(f.IsBoldStyle)}");
        L($"weight {f.WeightClass} fsType {f.FsType} embedding {B(f.EmbeddingAllowed)} subsetting {B(f.SubsettingAllowed)} cff {B(f.IsCff)} outlines {B(f.HasOutlines)}");
        L($"family {S(f.FamilyName)} ps {S(f.PostScriptName)}");
        foreach (var t in new[] { "glyf", "loca", "cmap", "post", "name", "cvt ", "fpgm", "prep", "CFF ", "kern" })
            L($"table {t} {B(f.HasTable(t))}");
        foreach (var cp in new[] { 0x20, 0x41, 0x42, 0x43, 0xC0, 0x11F, 0x130, 0x131, 0x1F600, 0x4E2D, -1, 0x10FFFF })
            L($"cp {cp} {f.GlyphForCodePoint(cp)} cmap31 {f.GlyphForCmap(3, 1, cp)} cmap10 {f.GlyphForCmap(1, 0, cp)} cmap310 {f.GlyphForCmap(3, 10, cp)} cmap00 {f.GlyphForCmap(0, 0, cp)}");
        L($"hasCmap 31 {B(f.HasCmap(3, 1))} 10 {B(f.HasCmap(1, 0))} 310 {B(f.HasCmap(3, 10))} 05 {B(f.HasCmap(0, 5))} 30 {B(f.HasCmap(3, 0))}");
        foreach (var (cp, vs) in new[] { (0x41, 0xFE00), (0x42, 0xFE00), (0x43, 0xFE00), (0x11F, 0xFE00), (0x11F, 0xFE01) })
            L($"variation {cp} {vs} {f.GlyphForVariation(cp, vs)}");
        for (var g = -1; g <= f.GlyphCount; g++)
        {
            L($"glyph {g} name {S(f.GlyphName(g))} advance {f.GetAdvance(g)} lsb {f.GetLeftSideBearing(g)} box {Box(f.GetBounds(g))}");
            L($"  {Outline(f.GetOutline(g))}");
        }
        foreach (var name in new[] { ".notdef", "A", "Alt", "acutecomb", "space", "nothing" })
            L($"forName {name} {f.GlyphForName(name)}");
        return sb.ToString();
    }

    private static byte[] WithFsType(byte[] font, int fsType)
    {
        var copy = (byte[])font.Clone();
        var os2 = ProgramFonts.TableOffset(copy, "OS/2");
        copy[os2 + 8] = (byte)(fsType >> 8);
        copy[os2 + 9] = (byte)fsType;
        return copy;
    }

    public static string Subset(byte[] data)
    {
        var sb = new StringBuilder();
        void L(string s) => sb.Append(s).Append('\n');
        (string Label, byte[] Font, int[] Ids)[] cases =
        [
            ("composite", data, [3]),
            ("two", data, [2, 5]),
            ("matched", data, [6]),
            ("none", data, []),
            ("odd", data, [1, 99999, -4, 4]),
            ("forbidden", WithFsType(data, 2), [1]),
            ("whole", WithFsType(data, 0x100), [1]),
            ("garbage", [1, 2, 3], [1]),
        ];
        foreach (var (label, font, ids) in cases)
        {
            var r = TrueTypeSubsetter.Subset(font, ids);
            L($"subset {label} {r.Status} map {Pairs(r.GlyphMap)} length {r.Data.Length}");
            HexLines(sb, r.Data);
            if (r.Status == SubsetStatus.Ok)
            {
                var again = TrueTypeFont.TryParse(r.Data)!;
                L($"  parsed glyphs {again.GlyphCount} ps {S(again.PostScriptName)} family {S(again.FamilyName)} upem {again.UnitsPerEm}");
                foreach (var (_, to) in r.GlyphMap.OrderBy(p => p.Key))
                    L($"  glyph {to} advance {again.GetAdvance(to)} box {Box(again.GetBounds(to))} {Outline(again.GetOutline(to))}");
            }
        }
        return sb.ToString();
    }

    public static string Embedded(byte[] data)
    {
        var sb = new StringBuilder();
        void L(string s) => sb.Append(s).Append('\n');
        (string Label, byte[] Font, string[] Texts)[] cases =
        [
            ("latin", data, ["ABÀ ğİ"]),
            ("missing", data, ["A中\U0001F600B", "\t"]),
            ("shared", data, ["ığ"]),
            ("empty", data, []),
            ("forbidden", WithFsType(data, 2), ["A"]),
            ("whole", WithFsType(data, 0x100), ["ABÀ"]),
            ("garbage", new byte[200], ["A"]),
        ];
        foreach (var (label, font, texts) in cases)
        {
            var e = EmbeddedFontBuilder.Build(font, texts, out var status);
            L($"embed {label} {status}");
            if (e is null) continue;
            L($"  base {e.BaseFont} cff {B(e.IsCff)} subset {B(e.IsSubset)} dw {e.DefaultWidth} program {e.Program.Length}");
            HexLines(sb, e.Program);
            L($"  widths {string.Join(" ", e.Widths.Select(r => $"{r.FirstCid}[{string.Join(",", r.Widths)}]"))}");
            var d = e.Descriptor;
            L($"  descriptor flags {d.Flags} bbox {string.Join(",", d.FontBBox)} italic {N(d.ItalicAngle)} ascent {d.Ascent} descent {d.Descent} cap {d.CapHeight} stemV {d.StemV}");
            L($"  codes {Pairs(e.Codes)}");
            L($"  missing {string.Join(",", e.Missing)}");
            L($"  encode {Hex(e.Encode(string.Concat(texts)))}");
            L($"  toUnicode {Pairs(e.ToUnicode())}");
        }
        return sb.ToString();
    }

    public static string Cff(string input)
    {
        var sb = new StringBuilder();
        void L(string s) => sb.Append(s).Append('\n');
        foreach (var (label, data) in new[] { ("name", CffBuilder.NameKeyed()), ("cid", CffBuilder.CidKeyed()), ("cidMatrix", CffBuilder.CidKeyed([3, 0, 0, 3, 0, 0], [2, 0, 0, 2, 0, 0])) })
        {
            var f = CffFont.TryParse(data)!;
            L($"font {label} name {f.Name} cid {B(f.IsCid)} glyphs {f.GlyphCount} matrix {string.Join(",", f.FontMatrix.Select(N))} bounds {Box(f.FontBounds)}");
            for (var g = -1; g <= f.GlyphCount; g++)
                L($"  glyph {g} name {S(f.GlyphName(g))} width {N(f.GetWidth(g))} cid {f.CidForGlyph(g)} {Outline(f.GetOutline(g))}");
            L($"  names {string.Join(",", new[] { "A", "B", "custom", ".notdef", "nothing" }.Select(n => f.GlyphForName(n)))}");
            L($"  codes {string.Join(",", Enumerable.Range(60, 10).Select(c => f.GlyphForCode(c)))}");
            L($"  cids {string.Join(",", new[] { -1, 0, 1, 2, 3, 10, 11, 12, 500, 501 }.Select(c => f.GlyphForCid(c)))}");
        }

        var n = 0;
        foreach (var line in input.Split('\n'))
        {
            if (line.Length == 0 || line.StartsWith("# ", StringComparison.Ordinal)) continue;
            var parts = new List<object>();
            foreach (var token in line.Split(' '))
            {
                if (int.TryParse(token, out var v)) parts.Add(v);
                else if (token.StartsWith("raw:", StringComparison.Ordinal)) parts.Add(Convert.FromHexString(token[4..]));
                else parts.Add(token);
            }
            parts.Add("return");
            var f = CffFont.TryParse(CffBuilder.NameKeyed(CffBuilder.Code(parts.ToArray())))!;
            L($"subr {++n} {line}");
            L($"  width {N(f.GetWidth(2))} {Outline(f.GetOutline(2))}");
        }
        return sb.ToString();
    }

    public static string Type1()
    {
        var sb = new StringBuilder();
        void L(string s) => sb.Append(s).Append('\n');
        foreach (var (wrapper, lenIV, bar) in new[] { (Type1Wrapper.Binary, 4, false), (Type1Wrapper.Hex, 4, false), (Type1Wrapper.Pfb, 4, false), (Type1Wrapper.Binary, 4, true), (Type1Wrapper.Binary, 0, false), (Type1Wrapper.Hex, -1, true) })
        {
            var f = Type1Font.TryParse(Type1Builder.Build(wrapper, lenIV, bar))!;
            L($"font {wrapper} {lenIV} {B(bar)} name {f.FontName} matrix {string.Join(",", f.FontMatrix.Select(N))} bounds {Box(f.FontBounds)}");
            L($"  encoding {string.Join(",", Enumerable.Range(0, 256).Where(c => f.BuiltInEncoding[c] != null).Select(c => $"{c}:{f.BuiltInEncoding[c]}"))}");
            foreach (var name in f.GlyphNames.Append("missing"))
                L($"  glyph {name} has {B(f.HasGlyph(name))} width {N(f.GetWidth(name))} {Outline(f.GetOutline(name))}");
        }
        return sb.ToString();
    }

    // The damage is a fixed linear congruential sequence, so both sides break the same bytes.
    private static byte[] Damage(byte[] source, int round)
    {
        var state = 1000u + (uint)round;
        uint Next()
        {
            state = unchecked(state * 1664525u + 1013904223u);
            return state >> 8;
        }
        var data = (byte[])source.Clone();
        for (var k = 0; k < 1 + round % 6; k++)
        {
            var at = (int)(Next() % (uint)data.Length);
            data[at] = (byte)(Next() & 0xFF);
        }
        return data;
    }

    public static string Damaged(byte[] sfnt)
    {
        var sb = new StringBuilder();
        void L(string s) => sb.Append(s).Append('\n');
        for (var round = 0; round < 300; round++)
        {
            var f = TrueTypeFont.TryParse(Damage(sfnt, round));
            if (f is null)
            {
                L($"ttf {round} null");
                continue;
            }
            var segments = 0;
            var advances = 0;
            for (var g = 0; g < Math.Min(f.GlyphCount, 64); g++)
            {
                segments += f.GetOutline(g)?.Segments.Count ?? 0;
                advances += f.GetAdvance(g);
            }
            L($"ttf {round} glyphs {f.GlyphCount} upem {f.UnitsPerEm} ascent {f.Ascent} cap {f.CapHeight} segments {segments} advances {advances} ps {S(f.PostScriptName)} A {f.GlyphForCodePoint(0x41)} E {f.GlyphForCodePoint(0xC0)} name {S(f.GlyphName(3))}");
        }
        foreach (var (label, source) in new[] { ("cff", CffBuilder.NameKeyed()), ("cid", CffBuilder.CidKeyed()) })
            for (var round = 0; round < 300; round++)
            {
                var f = CffFont.TryParse(Damage(source, round));
                if (f is null)
                {
                    L($"{label} {round} null");
                    continue;
                }
                var segments = 0;
                var widths = 0.0;
                for (var g = 0; g < Math.Min(f.GlyphCount, 16); g++)
                {
                    segments += f.GetOutline(g)?.Segments.Count ?? 0;
                    widths += f.GetWidth(g);
                }
                L($"{label} {round} glyphs {f.GlyphCount} cid {B(f.IsCid)} name {f.Name} segments {segments} widths {N(widths)} matrix {string.Join(",", f.FontMatrix.Select(N))} g1 {S(f.GlyphName(1))} c500 {f.GlyphForCid(500)}");
            }
        var type1 = Type1Builder.Build(Type1Wrapper.Binary);
        for (var round = 0; round < 300; round++)
        {
            var f = Type1Font.TryParse(Damage(type1, round));
            if (f is null)
            {
                L($"type1 {round} null");
                continue;
            }
            var segments = 0;
            var widths = 0.0;
            foreach (var name in f.GlyphNames)
            {
                segments += f.GetOutline(name)?.Segments.Count ?? 0;
                widths += f.GetWidth(name);
            }
            L($"type1 {round} name {f.FontName} glyphs {f.GlyphNames.Count} segments {segments} widths {N(widths)} A {S(f.BuiltInEncoding[65])}");
        }
        return sb.ToString();
    }
}
