using Xunit;

namespace LazyPDF.Core.Tests;

public class CffFontTests
{
    private static OutlineSegment[] Segments(GlyphOutline? o) => o!.Segments.ToArray();

    [Fact]
    public void CidFontMatrixComesFromTheFontDictsAndMultipliesWithTheTop()
    {
        Assert.Equal(0.001, CffFont.TryParse(CffBuilder.CidKeyed())!.FontMatrix[0]);
        Assert.Equal([2.0, 0, 0, 2.0, 0, 0], CffFont.TryParse(CffBuilder.CidKeyed(fdMatrix: [2, 0, 0, 2, 0, 0]))!.FontMatrix);
        Assert.Equal([6.0, 0, 0, 6.0, 0, 0], CffFont.TryParse(CffBuilder.CidKeyed([3, 0, 0, 3, 0, 0], [2, 0, 0, 2, 0, 0]))!.FontMatrix);
    }

    [Fact]
    public void NameKeyedFontReadsNamesAndEncoding()
    {
        var f = CffFont.TryParse(CffBuilder.NameKeyed())!;

        Assert.Equal("Test", f.Name);
        Assert.False(f.IsCid);
        Assert.Equal(4, f.GlyphCount);
        Assert.Equal("A", f.GlyphName(1));
        Assert.Equal("B", f.GlyphName(2));
        Assert.Equal("custom", f.GlyphName(3));
        Assert.Equal(".notdef", f.GlyphName(0));
        Assert.Equal(3, f.GlyphForName("custom"));
        Assert.Equal(0, f.GlyphForName("nothing"));
        Assert.Equal(1, f.GlyphForCode('A'));
        Assert.Equal(2, f.GlyphForCode('B'));
        Assert.Equal(0, f.GlyphForCode('C'));
        Assert.Equal(new GlyphBounds(0, 0, 200, 200), f.FontBounds);
        Assert.Equal(0.001, f.FontMatrix[0]);
    }

    [Fact]
    public void WidthIsNominalPlusDeltaOrTheDefault()
    {
        var f = CffFont.TryParse(CffBuilder.NameKeyed())!;

        Assert.Equal(600, f.GetWidth(1));
        Assert.Equal(300, f.GetWidth(2));
        Assert.Equal(300, f.GetWidth(3));
        Assert.Equal(300, f.GetWidth(0));
        Assert.Equal(0, f.GetWidth(4));
        Assert.Equal(0, f.GetWidth(-1));
    }

    [Fact]
    public void LinesCurvesAndSubroutinesBecomeAnOutline()
    {
        var f = CffFont.TryParse(CffBuilder.NameKeyed())!;

        Assert.Equal(
        [
            new(OutlineOp.Move, 50, 0), new(OutlineOp.Line, 150, 0), new(OutlineOp.Line, 150, 100), new(OutlineOp.Line, 50, 100),
            new(OutlineOp.Close, 0, 0),
        ], Segments(f.GetOutline(1)));

        Assert.Equal(
        [
            new(OutlineOp.Move, 10, 20), new(OutlineOp.Cubic, 70, 50, 40, 20, 40, 50), new(OutlineOp.Close, 0, 0),
        ], Segments(f.GetOutline(2)));
    }

    [Fact]
    public void HintMaskBytesAreSkipped()
    {
        var f = CffFont.TryParse(CffBuilder.NameKeyed())!;

        Assert.Equal(
        [
            new(OutlineOp.Move, 100, 100), new(OutlineOp.Line, 110, 100), new(OutlineOp.Line, 110, 120), new(OutlineOp.Close, 0, 0),
        ], Segments(f.GetOutline(3)));
    }

    [Fact]
    public void CidKeyedFontUsesPerGlyphPrivateDicts()
    {
        var f = CffFont.TryParse(CffBuilder.CidKeyed())!;

        Assert.True(f.IsCid);
        Assert.Equal(4, f.GlyphCount);
        Assert.Null(f.GlyphName(1));
        Assert.Equal(1, f.GlyphForCid(10));
        Assert.Equal(2, f.GlyphForCid(11));
        Assert.Equal(3, f.GlyphForCid(500));
        Assert.Equal(0, f.GlyphForCid(12));
        Assert.Equal(500, f.CidForGlyph(3));
        Assert.Equal(600, f.GetWidth(1));
        Assert.Equal(350, f.GetWidth(2));
        Assert.Equal(350, f.GetWidth(3));
        Assert.Equal(250, f.GetWidth(0));
        Assert.Equal(OutlineOp.Cubic, f.GetOutline(2)!.Segments[1].Op);
    }

    [Fact]
    public void NameKeyedFontUsesCidAsGlyphIndex()
    {
        var f = CffFont.TryParse(CffBuilder.NameKeyed())!;

        Assert.Equal(2, f.GlyphForCid(2));
        Assert.Equal(0, f.GlyphForCid(40));
    }

    [Theory]
    [InlineData(0)]
    [InlineData(3)]
    [InlineData(10)]
    [InlineData(40)]
    [InlineData(100)]
    public void TruncatedFontIsRefusedOrReadsSafely(int cut)
    {
        var data = CffBuilder.NameKeyed();
        var f = CffFont.TryParse(data[..cut]);
        if (f == null) return;
        for (var g = 0; g < f.GlyphCount; g++)
        {
            _ = f.GetOutline(g);
            _ = f.GetWidth(g);
        }
    }

    [Fact]
    public void DamagedFontsNeverThrow()
    {
        var rng = new Random(3);
        foreach (var source in new[] { CffBuilder.NameKeyed(), CffBuilder.CidKeyed() })
            for (var round = 0; round < 3000; round++)
            {
                var data = (byte[])source.Clone();
                for (var k = 0; k < 1 + round % 6; k++) data[rng.Next(data.Length)] = (byte)rng.Next(256);
                var f = CffFont.TryParse(data);
                if (f == null) continue;
                for (var g = 0; g < Math.Min(f.GlyphCount, 50); g++)
                {
                    _ = f.GetOutline(g);
                    _ = f.GetWidth(g);
                    _ = f.GlyphName(g);
                }
                _ = f.GlyphForName("A");
                _ = f.GlyphForCid(10);
            }
    }

    [Fact]
    public void RunawaySubroutineRecursionStops()
    {
        // Local subr 0 calls itself, once and twice: depth and operator limits end both.
        foreach (var subr in new[] { CffBuilder.Code(-107, "callsubr", "return"), CffBuilder.Code(-107, "callsubr", -107, "callsubr", "return") })
        {
            var f = CffFont.TryParse(CffBuilder.NameKeyed(subr))!;
            Assert.NotNull(f.GetOutline(2));
            Assert.Equal(300, f.GetWidth(2));
        }
    }

    [Theory]
    [InlineData(new object[] { 10, 20, "add", "dup", "rlineto" }, 40, 50)]
    [InlineData(new object[] { 20, 4, "div", 5, 3, "mul", "rlineto" }, 15, 35)]
    [InlineData(new object[] { 1, 2, "exch", "rlineto" }, 12, 21)]
    [InlineData(new object[] { 9, 8, 7, "drop", "rlineto" }, 19, 28)]
    [InlineData(new object[] { 10, 3, "sub", 0, "rlineto" }, 17, 20)]
    public void ArithmeticAndStackOperators(object[] code, double x, double y)
    {
        var subr = CffBuilder.Code([.. code, "return"]);
        var f = CffFont.TryParse(CffBuilder.NameKeyed(subr))!;

        var segments = f.GetOutline(2)!.Segments;
        Assert.Equal(new OutlineSegment(OutlineOp.Line, x, y), segments[1]);
    }

    [Fact]
    public void InterOpenTypeMatchesItsMetrics()
    {
        if (ProgramFonts.Otf() is not { } data) return;
        var sfnt = TrueTypeFont.TryParse(data)!;
        var cff = sfnt.Cff!;

        Assert.Equal(sfnt.GlyphCount, cff.GlyphCount);
        Assert.Equal(sfnt.UnitsPerEm, (int)Math.Round(1 / cff.FontMatrix[0]));
        var checkedGlyphs = 0;
        for (var g = 0; g < cff.GlyphCount; g += 11)
        {
            Assert.Equal(sfnt.GetAdvance(g), cff.GetWidth(g));
            var outline = cff.GetOutline(g)!;
            if (!outline.IsEmpty)
            {
                var box = outline.Bounds()!.Value;
                Assert.True(box.XMin >= sfnt.FontBounds.XMin - 1 && box.XMax <= sfnt.FontBounds.XMax + 1);
                Assert.True(box.YMin >= sfnt.FontBounds.YMin - 1 && box.YMax <= sfnt.FontBounds.YMax + 1);
            }
            checkedGlyphs++;
        }
        Assert.True(checkedGlyphs > 50);
    }

    [Fact]
    public void InterNamesAndOutlines()
    {
        if (ProgramFonts.Otf() is not { } data) return;
        var sfnt = TrueTypeFont.TryParse(data)!;
        var cff = sfnt.Cff!;

        var a = sfnt.GlyphForCodePoint('A');
        Assert.Equal("uni0041", cff.GlyphName(a));
        Assert.Equal(a, cff.GlyphForName("uni0041"));
        Assert.Equal("uni0041", sfnt.GlyphName(a));
        var outline = cff.GetOutline(a)!;
        Assert.Equal(outline.Segments.Count(s => s.Op == OutlineOp.Move), outline.Segments.Count(s => s.Op == OutlineOp.Close));
        Assert.NotEqual(0, sfnt.GlyphForCodePoint(0x011F));
        Assert.NotEqual(0, sfnt.GlyphForCodePoint(0x0131));
    }

    [Fact]
    public void BareCffTableParsesLikeTheOpenTypeFont()
    {
        if (ProgramFonts.Otf() is not { } data) return;
        var at = ProgramFonts.TableOffset(data, "CFF ");
        var e = ProgramFonts.DirectoryEntry(data, "CFF ");
        var length = (data[e + 12] << 24) | (data[e + 13] << 16) | (data[e + 14] << 8) | data[e + 15];

        var bare = CffFont.TryParse(data, at, length)!;
        var viaSfnt = TrueTypeFont.TryParse(data)!.Cff!;
        Assert.Equal(viaSfnt.GlyphCount, bare.GlyphCount);
        Assert.Equal(viaSfnt.GetWidth(5), bare.GetWidth(5));
    }

    [Fact]
    public void NotCffGivesNull()
    {
        Assert.Null(CffFont.TryParse([]));
        Assert.Null(CffFont.TryParse(new byte[64]));
        Assert.Null(CffFont.TryParse("hello world, not a font"u8.ToArray()));
        Assert.Null(CffFont.TryParse(new byte[10], 8, 10));
    }
}
