using Xunit;

namespace LazyPDF.Core.Tests;

public class TrueTypeSubsetterTests
{
    private static int[] GlyphsOf(TrueTypeFont f, string text) => text.Select(c => f.GlyphForCodePoint(c)).Distinct().ToArray();

    private static void AssertSameGlyphs(TrueTypeFont source, TrueTypeFont subset, IReadOnlyDictionary<int, int> map)
    {
        foreach (var (old, @new) in map)
        {
            Assert.Equal(source.GetAdvance(old), subset.GetAdvance(@new));
            Assert.Equal(source.GetBounds(old), subset.GetBounds(@new));
            var a = source.GetOutline(old)!;
            var b = subset.GetOutline(@new)!;
            Assert.Equal(a.Segments, b.Segments);
        }
    }

    [Fact]
    public void KeptGlyphsKeepOutlineAndAdvance()
    {
        if (ProgramFonts.Windows("arial.ttf") is not { } data) return;
        var source = TrueTypeFont.TryParse(data)!;
        var ids = GlyphsOf(source, "Hello, World! Şğıİ çöü ÇÖÜ 0123456789");

        var result = TrueTypeSubsetter.Subset(data, ids);

        Assert.Equal(SubsetStatus.Ok, result.Status);
        var subset = TrueTypeFont.TryParse(result.Data)!;
        Assert.Equal(result.GlyphMap.Count, subset.GlyphCount);
        Assert.Equal(0, result.GlyphMap[0]);
        Assert.All(ids, g => Assert.True(result.GlyphMap.ContainsKey(g)));
        Assert.Equal(source.UnitsPerEm, subset.UnitsPerEm);
        Assert.Equal(source.Ascent, subset.Ascent);
        Assert.Equal(source.Descent, subset.Descent);
        Assert.Equal(source.PostScriptName, subset.PostScriptName);
        Assert.True(subset.HasOutlines);
        AssertSameGlyphs(source, subset, result.GlyphMap);
        Assert.True(result.Data.Length < data.Length / 10);
    }

    [Fact]
    public void NewIdsFollowTheOrderOfTheOldOnes()
    {
        if (ProgramFonts.Windows("arial.ttf") is not { } data) return;
        var map = TrueTypeSubsetter.Subset(data, [500, 20, 300, 20]).GlyphMap;

        Assert.Equal(4, map.Count);
        Assert.Equal(0, map[0]);
        Assert.Equal(1, map[20]);
        Assert.Equal(2, map[300]);
        Assert.Equal(3, map[500]);
    }

    [Fact]
    public void CompositeGlyphsPullInTheirComponents()
    {
        if (ProgramFonts.Windows("arial.ttf") is not { } data) return;
        var source = TrueTypeFont.TryParse(data)!;
        var eacute = source.GlyphForCodePoint('é');

        var result = TrueTypeSubsetter.Subset(data, [eacute]);

        Assert.True(result.GlyphMap.Count >= 3, "a composite keeps its parts");
        var subset = TrueTypeFont.TryParse(result.Data)!;
        AssertSameGlyphs(source, subset, result.GlyphMap);
        Assert.False(subset.GetOutline(result.GlyphMap[eacute])!.IsEmpty);
    }

    [Fact]
    public void UnknownGlyphIdsAreIgnored()
    {
        if (ProgramFonts.Windows("arial.ttf") is not { } data) return;

        var result = TrueTypeSubsetter.Subset(data, [-5, 99999, 70000]);

        Assert.Equal(SubsetStatus.Ok, result.Status);
        Assert.Equal([0], result.GlyphMap.Keys);
        Assert.Equal(1, TrueTypeFont.TryParse(result.Data)!.GlyphCount);
    }

    [Fact]
    public void ChecksumsAndDirectoryAreValid()
    {
        if (ProgramFonts.Windows("times.ttf") is not { } data) return;
        var result = TrueTypeSubsetter.Subset(data, GlyphsOf(TrueTypeFont.TryParse(data)!, "Merhaba dünya ğşı"));
        var font = result.Data;

        Assert.Equal(0xB1B0AFBAu, Sum(font));

        var count = (font[4] << 8) | font[5];
        var previous = "";
        for (var i = 0; i < count; i++)
        {
            var at = 12 + 16 * i;
            var tag = System.Text.Encoding.ASCII.GetString(font, at, 4);
            Assert.True(string.CompareOrdinal(previous, tag) < 0, "tags ascend");
            previous = tag;
            var stored = ReadU32(font, at + 4);
            var offset = (int)ReadU32(font, at + 8);
            var length = (int)ReadU32(font, at + 12);
            Assert.Equal(0, offset % 4);
            var table = font.AsSpan(offset, length).ToArray();
            if (tag == "head") Array.Clear(table, 8, 4);
            Assert.Equal(stored, Sum(table));
        }
        Assert.Equal(1 << ((font[8] << 8) | font[9]), ((font[6] << 8) | font[7]) / 16);
        foreach (var tag in new[] { "head", "hhea", "maxp", "hmtx", "loca", "glyf" })
            Assert.True(ProgramFonts.DirectoryEntry(font, tag) > 0, tag);
    }

    private static uint ReadU32(byte[] d, int o) => (uint)((d[o] << 24) | (d[o + 1] << 16) | (d[o + 2] << 8) | d[o + 3]);

    private static uint Sum(byte[] d)
    {
        uint sum = 0;
        for (var i = 0; i < d.Length; i += 4)
        {
            uint w = 0;
            for (var k = 0; k < 4; k++) w = (w << 8) | (i + k < d.Length ? d[i + k] : (uint)0);
            sum += w;
        }
        return sum;
    }

    [Fact]
    public void WholeFontKeepsLongLocaWorking()
    {
        if (ProgramFonts.Windows("segoeui.ttf") is not { } data) return;
        var source = TrueTypeFont.TryParse(data)!;

        var result = TrueTypeSubsetter.Subset(data, Enumerable.Range(0, source.GlyphCount).ToArray());

        Assert.Equal(SubsetStatus.Ok, result.Status);
        var subset = TrueTypeFont.TryParse(result.Data)!;
        Assert.Equal(source.GlyphCount, subset.GlyphCount);
        for (var g = 0; g < source.GlyphCount; g += 17)
        {
            Assert.Equal(source.GetOutline(g)!.Segments, subset.GetOutline(result.GlyphMap[g])!.Segments);
            Assert.Equal(source.GetAdvance(g), subset.GetAdvance(g));
        }
    }

    [Fact]
    public void FontsThatForbidEmbeddingAreReported()
    {
        if (ProgramFonts.Windows("arial.ttf") is not { } data) return;
        var os2 = ProgramFonts.TableOffset(data, "OS/2");

        foreach (var (fsType, expected) in new[] { (2, SubsetStatus.EmbeddingForbidden), (0x200, SubsetStatus.EmbeddingForbidden), (0x100, SubsetStatus.SubsettingForbidden) })
        {
            var copy = (byte[])data.Clone();
            copy[os2 + 8] = (byte)(fsType >> 8);
            copy[os2 + 9] = (byte)fsType;
            var result = TrueTypeSubsetter.Subset(copy, [36, 37]);
            Assert.Equal(expected, result.Status);
            Assert.Empty(result.Data);
            Assert.Empty(result.GlyphMap);
        }
    }

    [Fact]
    public void CffAndGarbageAreNotSubset()
    {
        if (ProgramFonts.Otf() is { } otf)
            Assert.Equal(SubsetStatus.NotTrueType, TrueTypeSubsetter.Subset(otf, [1, 2]).Status);
        Assert.Equal(SubsetStatus.Unreadable, TrueTypeSubsetter.Subset([1, 2, 3], [1]).Status);
        Assert.Equal(SubsetStatus.Unreadable, TrueTypeSubsetter.Subset(new byte[500], [1]).Status);
    }

    [Fact]
    public void CollectionMemberIsSubsetByIndex()
    {
        if (ProgramFonts.Windows("msgothic.ttc") is not { } data) return;
        var source = TrueTypeFont.TryParse(data, 0)!;
        var ids = GlyphsOf(source, "あいう漢字ABC");

        var result = TrueTypeSubsetter.Subset(data, ids, 0);

        if (!source.EmbeddingAllowed)
        {
            Assert.Equal(SubsetStatus.EmbeddingForbidden, result.Status);
            return;
        }
        Assert.Equal(SubsetStatus.Ok, result.Status);
        var subset = TrueTypeFont.TryParse(result.Data)!;
        AssertSameGlyphs(source, subset, result.GlyphMap);
        Assert.Equal(SubsetStatus.Unreadable, TrueTypeSubsetter.Subset(data, ids, 99).Status);
    }

    [Fact]
    public void PdfPigReadsTheSubset()
    {
        if (ProgramFonts.Windows("arial.ttf") is not { } data) return;
        var source = TrueTypeFont.TryParse(data)!;
        var result = TrueTypeSubsetter.Subset(data, GlyphsOf(source, "Şğıİ abc"));

        var parsed = UglyToad.PdfPig.Fonts.TrueType.Parser.TrueTypeFontParser.Parse(
            new UglyToad.PdfPig.Fonts.TrueType.TrueTypeDataBytes(new UglyToad.PdfPig.Core.MemoryInputBytes(result.Data)));

        Assert.True(parsed.TryGetPath(result.GlyphMap[source.GlyphForCodePoint('ğ')], c => c, out var path) && path.Count > 0);
        Assert.Equal(source.UnitsPerEm, parsed.GetUnitsPerEm());
    }
}
