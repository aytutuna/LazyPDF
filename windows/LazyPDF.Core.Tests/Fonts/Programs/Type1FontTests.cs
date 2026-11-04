using Xunit;

namespace LazyPDF.Core.Tests;

public class Type1FontTests
{
    public static TheoryData<Type1Wrapper, int, bool> Variants => new()
    {
        { Type1Wrapper.Binary, 4, false },
        { Type1Wrapper.Hex, 4, false },
        { Type1Wrapper.Pfb, 4, false },
        { Type1Wrapper.Binary, 4, true },
        { Type1Wrapper.Binary, 0, false },
        { Type1Wrapper.Hex, -1, true },
    };

    private static Type1Font Font(Type1Wrapper w = Type1Wrapper.Binary, int lenIV = 4, bool bar = false) =>
        Type1Font.TryParse(Type1Builder.Build(w, lenIV, bar))!;

    private static OutlineSegment[] Segments(GlyphOutline? o) => o!.Segments.ToArray();

    [Theory]
    [MemberData(nameof(Variants))]
    public void HeaderAndGlyphsAreRead(Type1Wrapper wrapper, int lenIV, bool bar)
    {
        var f = Font(wrapper, lenIV, bar);

        Assert.Equal("TestFont", f.FontName);
        Assert.Equal(Type1Builder.GlyphNames, f.GlyphNames);
        Assert.Equal(new GlyphBounds(-10, -20, 900, 800), f.FontBounds);
        Assert.Equal(0.001, f.FontMatrix[0]);
        Assert.Equal("A", f.BuiltInEncoding[65]);
        Assert.Equal("B", f.BuiltInEncoding[66]);
        Assert.Equal("C", f.BuiltInEncoding[67]);
        Assert.Null(f.BuiltInEncoding[0]);
        Assert.Null(f.BuiltInEncoding[200]);
        Assert.True(f.HasGlyph("G"));
        Assert.False(f.HasGlyph("Z"));
    }

    [Theory]
    [MemberData(nameof(Variants))]
    public void WidthsComeFromHsbwAndSbw(Type1Wrapper wrapper, int lenIV, bool bar)
    {
        var f = Font(wrapper, lenIV, bar);

        Assert.Equal(250, f.GetWidth(".notdef"));
        Assert.Equal(600, f.GetWidth("A"));
        Assert.Equal(500, f.GetWidth("B"));
        Assert.Equal(700, f.GetWidth("C"));
        Assert.Equal(300, f.GetWidth("F"));
        Assert.Equal(0, f.GetWidth("missing"));
    }

    [Fact]
    public void LinesStartAtTheSideBearing()
    {
        Assert.Equal(
        [
            new(OutlineOp.Move, 50, 0), new(OutlineOp.Line, 150, 0), new(OutlineOp.Line, 150, 100), new(OutlineOp.Line, 50, 100),
            new(OutlineOp.Close, 0, 0),
        ], Segments(Font().GetOutline("A")));
    }

    [Theory]
    [MemberData(nameof(Variants))]
    public void FlexBecomesTwoCurves(Type1Wrapper wrapper, int lenIV, bool bar)
    {
        Assert.Equal(
        [
            new(OutlineOp.Move, 10, 10),
            new(OutlineOp.Cubic, 50, 15, 30, 10, 40, 15),
            new(OutlineOp.Cubic, 80, 10, 60, 15, 70, 10),
            new(OutlineOp.Line, 80, 110),
            new(OutlineOp.Close, 0, 0),
        ], Segments(Font(wrapper, lenIV, bar).GetOutline("B")));
    }

    [Fact]
    public void SeacComposesBaseAndAccent()
    {
        var f = Font();
        var a = f.GetOutline("A")!.Segments;
        var b = f.GetOutline("B")!.Segments;

        // asb 20, adx 30, ady 40 and sbx 0 put the accent at (10, 40).
        var expected = a.Concat(b.Select(s => s.Op == OutlineOp.Close ? s : s with
        {
            X = s.X + 10, Y = s.Y + 40, X1 = s.X1 + 10, Y1 = s.Y1 + 40, X2 = s.X2 + 10, Y2 = s.Y2 + 40,
        })).ToArray();
        Assert.Equal(expected, Segments(f.GetOutline("C")));
    }

    [Fact]
    public void DivHintReplacementAndCurves()
    {
        var f = Font();

        Assert.Equal([new(OutlineOp.Move, 0, 0), new(OutlineOp.Line, 50, 0), new(OutlineOp.Close, 0, 0)], Segments(f.GetOutline("D")));
        Assert.Equal([new(OutlineOp.Move, 0, 0), new(OutlineOp.Line, 10, 0), new(OutlineOp.Close, 0, 0)], Segments(f.GetOutline("E")));
        Assert.Equal([new(OutlineOp.Move, 10, 20), new(OutlineOp.Line, 10, 25), new(OutlineOp.Close, 0, 0)], Segments(f.GetOutline("F")));
        Assert.Equal(
        [
            new(OutlineOp.Move, 0, 0),
            new(OutlineOp.Cubic, 20, 10, 10, 0, 10, 10),
            new(OutlineOp.Cubic, 35, 25, 20, 15, 30, 25),
            new(OutlineOp.Cubic, 42, 36, 38, 25, 42, 30),
            new(OutlineOp.Close, 0, 0),
        ], Segments(f.GetOutline("G")));
    }

    [Fact]
    public void MissingGlyphHasNoOutline()
    {
        Assert.Null(Font().GetOutline("Q"));
    }

    [Fact]
    public void StandardEncodingIsExpanded()
    {
        var text = System.Text.Encoding.Latin1.GetString(Type1Builder.Build(Type1Wrapper.Binary))
            .Replace("/Encoding 256 array\n0 1 255 {1 index exch /.notdef put} for\ndup 65 /A put\ndup 66 /B put\ndup 8#103 /C put\nreadonly def", "/Encoding StandardEncoding def");
        var f = Type1Font.TryParse(System.Text.Encoding.Latin1.GetBytes(text))!;

        Assert.Equal("A", f.BuiltInEncoding[65]);
        Assert.Equal("fi", f.BuiltInEncoding[174]);
        Assert.Equal("germandbls", f.BuiltInEncoding[251]);
        Assert.Null(f.BuiltInEncoding[0]);
    }

    [Fact]
    public void NotAType1FontGivesNull()
    {
        Assert.Null(Type1Font.TryParse([]));
        Assert.Null(Type1Font.TryParse(new byte[300]));
        Assert.Null(Type1Font.TryParse("%!PS-AdobeFont-1.0\n/FontName /X def\ncurrentfile eexec\n"u8.ToArray()));
        Assert.Null(Type1Font.TryParse([0x80, 1, 255, 255, 255, 127, 1, 2, 3]));
    }

    [Fact]
    public void TruncatedAndDamagedFontsNeverThrow()
    {
        var rng = new Random(11);
        foreach (var wrapper in new[] { Type1Wrapper.Binary, Type1Wrapper.Hex, Type1Wrapper.Pfb })
        {
            var data = Type1Builder.Build(wrapper);
            for (var cut = 0; cut < data.Length; cut += 13) Exercise(data[..cut]);
            for (var round = 0; round < 400; round++)
            {
                var copy = (byte[])data.Clone();
                for (var k = 0; k < 1 + round % 8; k++) copy[rng.Next(copy.Length)] = (byte)rng.Next(256);
                Exercise(copy);
            }
        }
    }

    private static void Exercise(byte[] data)
    {
        var f = Type1Font.TryParse(data);
        if (f == null) return;
        foreach (var name in f.GlyphNames)
        {
            _ = f.GetOutline(name);
            _ = f.GetWidth(name);
        }
    }

    [Fact]
    public void CharstringLengthNearTheIntegerLimitGivesNoFontNotAnException()
    {
        var clear = System.Text.Encoding.Latin1.GetBytes(
            "%!PS-AdobeFont-1.0: T 001\n/FontName /T def\n/FontMatrix [0.001 0 0 0.001 0 0] readonly def\n" +
            "/FontBBox {0 0 1 1} readonly def\ncurrentdict end\ncurrentfile eexec\n");
        var secret = System.Text.Encoding.Latin1.GetBytes(
            "dup /Private 8 dict dup begin\n/RD {string currentfile exch readstring pop} executeonly def\n" +
            "/CharStrings 1 dict dup begin\n/A 2147483647 RD abcdef ND\nend\nend\n");
        var trailer = System.Text.Encoding.Latin1.GetBytes(new string('0', 64) + "\ncleartomark\n");
        byte[] font = [.. clear, .. Type1Builder.Encrypt(secret, 55665, 4), .. trailer];
        Assert.Null(Record.Exception(() => Type1Font.TryParse(font)));
    }
}
