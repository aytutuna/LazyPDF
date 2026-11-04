using Xunit;

namespace LazyPDF.Core.Tests;

public class TrueTypeFontTests
{
    [Fact]
    public void ArialMetrics()
    {
        if (ProgramFonts.Windows("arial.ttf") is not { } data) return;
        var f = TrueTypeFont.TryParse(data)!;

        Assert.Equal(2048, f.UnitsPerEm);
        Assert.True(f.Ascent > 1500 && f.Ascent < 2200);
        Assert.True(f.Descent < 0 && f.Descent > -800);
        Assert.True(f.CapHeight > 1000 && f.CapHeight < 1700);
        Assert.Equal(1366, f.GetAdvance(f.GlyphForCodePoint('A')));
        Assert.Equal(569, f.GetAdvance(f.GlyphForCodePoint(' ')));
        Assert.Equal("Arial", f.FamilyName);
        Assert.Equal("ArialMT", f.PostScriptName);
        Assert.True(f.EmbeddingAllowed);
        Assert.False(f.IsCff);
    }

    [Theory]
    [InlineData(0x011F)]
    [InlineData(0x015F)]
    [InlineData(0x0131)]
    [InlineData(0x0130)]
    [InlineData(0x011E)]
    [InlineData(0x015E)]
    public void TurkishLettersHaveGlyphs(int codePoint)
    {
        if (ProgramFonts.Windows("arial.ttf") is not { } data) return;
        var f = TrueTypeFont.TryParse(data)!;

        var gid = f.GlyphForCodePoint(codePoint);
        Assert.NotEqual(0, gid);
        Assert.NotNull(f.GetOutline(gid));
        Assert.True(f.GetAdvance(gid) > 0);
        Assert.Null(f.GlyphName(gid));
    }

    [Theory]
    [InlineData(0x011F, "gbreve")]
    [InlineData(0x015F, "scedilla")]
    [InlineData(0x0131, "dotlessi")]
    [InlineData('A', "A")]
    [InlineData(' ', "space")]
    public void GlyphNamesComeFromPost(int codePoint, string name)
    {
        if (ProgramFonts.Named() is not { } data) return;
        var f = TrueTypeFont.TryParse(data)!;

        var gid = f.GlyphForCodePoint(codePoint);
        Assert.NotEqual(0, gid);
        Assert.Equal(name, f.GlyphName(gid));
        Assert.Equal(gid, f.GlyphForName(name));
        Assert.Equal(0, f.GlyphForName("no-such-glyph"));
        Assert.Null(f.GlyphName(-1));
        Assert.Null(f.GlyphName(f.GlyphCount));
    }

    [Fact]
    public void CodePointsOutsideTheFontMapToNotdef()
    {
        if (ProgramFonts.Windows("times.ttf") is not { } data) return;
        var f = TrueTypeFont.TryParse(data)!;

        Assert.Equal(0, f.GlyphForCodePoint(0x4E2D));
        Assert.Equal(0, f.GlyphForCodePoint(-1));
        Assert.Equal(0, f.GlyphForCodePoint(0x10FFFF));
    }

    [Fact]
    public void OutlineBoundsMatchTheGlyphHeader()
    {
        if (ProgramFonts.Windows("segoeui.ttf") is not { } data) return;
        var f = TrueTypeFont.TryParse(data)!;

        foreach (var ch in "AgSs&@éÖğŞ")
        {
            var gid = f.GlyphForCodePoint(ch);
            var header = f.GetBounds(gid)!.Value;
            var outline = f.GetOutline(gid)!;
            var box = outline.Bounds()!.Value;
            Assert.Equal(header, box);
            Assert.Contains(outline.Segments, s => s.Op == OutlineOp.Quad);
        }
    }

    [Fact]
    public void BlankGlyphHasEmptyOutlineAndNoBounds()
    {
        if (ProgramFonts.Windows("arial.ttf") is not { } data) return;
        var f = TrueTypeFont.TryParse(data)!;

        var space = f.GlyphForCodePoint(' ');
        Assert.True(f.GetOutline(space)!.IsEmpty);
        Assert.Null(f.GetBounds(space));
        Assert.Null(f.GetOutline(f.GlyphCount));
        Assert.Null(f.GetOutline(-1));
        Assert.Equal(0, f.GetAdvance(f.GlyphCount + 5));
    }

    [Fact]
    public void AccentedGlyphIsComposedFromItsParts()
    {
        if (ProgramFonts.Windows("arial.ttf") is not { } data) return;
        var f = TrueTypeFont.TryParse(data)!;

        var e = f.GetOutline(f.GlyphForCodePoint('e'))!;
        var eacute = f.GetOutline(f.GlyphForCodePoint('é'))!;
        Assert.True(eacute.Segments.Count > e.Segments.Count);
        Assert.Equal(e.Bounds()!.Value.XMin, eacute.Bounds()!.Value.XMin);
        Assert.True(eacute.Bounds()!.Value.YMax > e.Bounds()!.Value.YMax);
    }

    [Fact]
    public void CollectionOpensEachFontByIndex()
    {
        if (ProgramFonts.Windows("msgothic.ttc") is not { } data) return;

        var count = TrueTypeFont.CollectionCount(data);
        Assert.True(count >= 2);
        var first = TrueTypeFont.TryParse(data, 0)!;
        var second = TrueTypeFont.TryParse(data, 1)!;
        Assert.NotEqual(first.PostScriptName, second.PostScriptName);
        Assert.NotEqual(0, first.GlyphForCodePoint(0x3042));
        Assert.NotNull(first.GetOutline(first.GlyphForCodePoint(0x3042)));
        Assert.Null(TrueTypeFont.TryParse(data, count));
        Assert.Null(TrueTypeFont.TryParse(data, -1));
    }

    [Fact]
    public void OpenTypeCffExposesTheCffOutlines()
    {
        if (ProgramFonts.Otf() is not { } data) return;
        var f = TrueTypeFont.TryParse(data)!;

        Assert.True(f.IsCff);
        var gid = f.GlyphForCodePoint('g');
        Assert.NotEqual(0, gid);
        Assert.Contains(f.GetOutline(gid)!.Segments, s => s.Op == OutlineOp.Cubic);
        Assert.True(f.GetAdvance(gid) > 0);
    }

    [Fact]
    public void NotAFontGivesNull()
    {
        Assert.Null(TrueTypeFont.TryParse([]));
        Assert.Null(TrueTypeFont.TryParse(new byte[100]));
        Assert.Null(TrueTypeFont.TryParse("%PDF-1.7 not a font at all"u8.ToArray()));
        Assert.Equal(0, TrueTypeFont.CollectionCount([1, 2, 3]));
    }

    [Fact]
    public void TruncatedAndDamagedFontsNeverThrow()
    {
        if (ProgramFonts.Windows("arial.ttf") is not { } data) return;
        var rng = new Random(7);

        for (var cut = 0; cut < data.Length; cut += data.Length / 97 + 1)
            Exercise(data[..cut]);

        for (var round = 0; round < 60; round++)
        {
            var copy = (byte[])data.Clone();
            for (var k = 0; k < 40; k++) copy[rng.Next(copy.Length < 40000 ? copy.Length : 40000)] = (byte)rng.Next(256);
            Exercise(copy);
        }

        // Damage inside glyf, loca and cmap specifically.
        foreach (var tag in new[] { "glyf", "loca", "cmap", "hmtx", "post", "head" })
        {
            var at = ProgramFonts.TableOffset(data, tag);
            for (var round = 0; round < 20; round++)
            {
                var copy = (byte[])data.Clone();
                for (var k = 0; k < 60; k++) copy[at + rng.Next(Math.Min(4000, copy.Length - at))] = (byte)rng.Next(256);
                Exercise(copy);
            }
        }
    }

    private static void Exercise(byte[] data)
    {
        var f = TrueTypeFont.TryParse(data);
        if (f == null) return;
        _ = f.PostScriptName;
        _ = f.GlyphForCodePoint(0x11F);
        _ = f.GlyphForVariation(0x11F, 0xFE00);
        _ = f.GlyphForName("gbreve");
        for (var g = 0; g < f.GlyphCount; g += 7)
        {
            _ = f.GetAdvance(g);
            _ = f.GetBounds(g);
            _ = f.GetOutline(g);
            _ = f.GlyphName(g);
        }
        var subset = TrueTypeSubsetter.Subset(data, [1, 5, 100, 20000]);
        if (subset.Status == SubsetStatus.Ok) Assert.NotNull(TrueTypeFont.TryParse(subset.Data));
    }

    [Fact]
    public void FsTypeBitsDecideEmbedding()
    {
        if (ProgramFonts.Windows("arial.ttf") is not { } data) return;
        var os2 = ProgramFonts.TableOffset(data, "OS/2");

        foreach (var (fsType, embed, subset) in new[] { (0, true, true), (4, true, true), (8, true, true), (2, false, true), (0x200, false, true), (0x100, true, false), (0x108, true, false) })
        {
            var copy = (byte[])data.Clone();
            copy[os2 + 8] = (byte)(fsType >> 8);
            copy[os2 + 9] = (byte)fsType;
            var f = TrueTypeFont.TryParse(copy)!;
            Assert.Equal(embed, f.EmbeddingAllowed);
            Assert.Equal(subset, f.SubsettingAllowed);
        }
    }
}
