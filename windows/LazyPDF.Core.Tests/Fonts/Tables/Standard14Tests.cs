using Xunit;

namespace LazyPDF.Core.Tests;

public class Standard14Tests
{
    [Fact]
    public void HasFourteenFonts()
    {
        Assert.Equal(14, Standard14.All.Count);
        Assert.Equal(14, Standard14.All.Select(f => f.Name).Distinct().Count());
    }

    [Fact]
    public void HelveticaMetrics()
    {
        var f = Standard14.Find("Helvetica")!;
        Assert.Equal(278, f.WidthOf("space"));
        Assert.Equal(667, f.WidthOf("A"));
        Assert.Equal(718, f.Ascent);
        Assert.Equal(-207, f.Descent);
        Assert.Equal(new FontBox(-166, -225, 1000, 931), f.BBox);
        Assert.Null(f.WidthOf("a1"));
    }

    [Fact]
    public void TimesAndCourier()
    {
        Assert.Equal(722, Standard14.Find("Times-Roman")!.WidthOf("A"));
        Assert.Equal(722, Standard14.Find("Times-Bold")!.WidthOf("A"));
        var courier = Standard14.Find("Courier")!;
        Assert.True(courier.IsFixedPitch);
        Assert.All(new[] { "A", "i", "W", "space" }, g => Assert.Equal(600, courier.WidthOf(g)));
    }

    [Fact]
    public void SymbolAndZapfDingbatsUseTheirOwnNames()
    {
        var symbol = Standard14.Find("Symbol")!;
        Assert.Equal(631, symbol.WidthOf("alpha"));
        Assert.True(symbol.IsSymbolic);
        Assert.Equal(1010, symbol.Ascent);
        Assert.Same(PdfEncodings.Symbol, symbol.BuiltInEncoding);
        var zapf = Standard14.Find("ZapfDingbats")!;
        Assert.Equal(974, zapf.WidthOf("a1"));
        Assert.Same(PdfEncodings.ZapfDingbats, zapf.BuiltInEncoding);
        Assert.Same(PdfEncodings.Standard, Standard14.Find("Helvetica")!.BuiltInEncoding);
    }

    [Theory]
    [InlineData("Arial", "Helvetica")]
    [InlineData("ArialMT", "Helvetica")]
    [InlineData("Arial,Bold", "Helvetica-Bold")]
    [InlineData("Arial-BoldMT", "Helvetica-Bold")]
    [InlineData("Arial-ItalicMT", "Helvetica-Oblique")]
    [InlineData("Arial-BoldItalicMT", "Helvetica-BoldOblique")]
    [InlineData("Helvetica-Oblique", "Helvetica-Oblique")]
    [InlineData("TimesNewRoman", "Times-Roman")]
    [InlineData("TimesNewRomanPSMT", "Times-Roman")]
    [InlineData("TimesNewRomanPS-BoldMT", "Times-Bold")]
    [InlineData("Times New Roman,Italic", "Times-Italic")]
    [InlineData("TimesNewRomanPS-BoldItalicMT", "Times-BoldItalic")]
    [InlineData("Times-Roman", "Times-Roman")]
    [InlineData("CourierNew", "Courier")]
    [InlineData("CourierNewPS-BoldMT", "Courier-Bold")]
    [InlineData("Courier New,BoldItalic", "Courier-BoldOblique")]
    [InlineData("SymbolMT", "Symbol")]
    [InlineData("ZapfDingbats", "ZapfDingbats")]
    [InlineData("ABCDEF+Arial", "Helvetica")]
    [InlineData("arial", "Helvetica")]
    public void Aliases(string alias, string name) => Assert.Equal(name, Standard14.Find(alias)?.Name);

    [Theory]
    [InlineData("")]
    [InlineData("Arial Narrow")]
    [InlineData("Arial Black")]
    [InlineData("Calibri")]
    [InlineData("Symbolic")]
    [InlineData("Times-Bogus")]
    public void OtherFontsAreNotStandard(string name) => Assert.Null(Standard14.Find(name));

    [Fact]
    public void FlagsFollowTheDescriptorBits()
    {
        Assert.Equal(1 | 32, Standard14.Find("Courier")!.Flags);
        Assert.Equal(2 | 32 | 64, Standard14.Find("Times-Italic")!.Flags);
        Assert.Equal(4, Standard14.Find("Symbol")!.Flags);
        Assert.NotEqual(0, Standard14.Find("Helvetica-Bold")!.Flags & (1 << 18));
    }

    [Fact]
    public void EveryGlyphOfStandardEncodingHasAWidth()
    {
        foreach (var f in Standard14.All.Where(f => !f.IsSymbolic))
            foreach (var name in PdfEncodings.Standard.Where(n => n != null))
                Assert.NotNull(f.WidthOf(name!));
    }
}
