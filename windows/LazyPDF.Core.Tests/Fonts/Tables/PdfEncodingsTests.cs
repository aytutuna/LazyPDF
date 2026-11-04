using Xunit;

namespace LazyPDF.Core.Tests;

public class PdfEncodingsTests
{
    static readonly IReadOnlyList<string?>[] All =
    [
        PdfEncodings.Standard, PdfEncodings.WinAnsi, PdfEncodings.MacRoman, PdfEncodings.MacExpert,
        PdfEncodings.PdfDoc, PdfEncodings.Symbol, PdfEncodings.ZapfDingbats,
    ];

    [Fact]
    public void TablesHave256Slots() => Assert.All(All, t => Assert.Equal(256, t.Count));

    [Fact]
    public void StandardEncodingKeepsItsQuirks()
    {
        Assert.Equal("quoteright", PdfEncodings.Standard[39]);
        Assert.Equal("quoteleft", PdfEncodings.Standard[96]);
        Assert.Equal("fi", PdfEncodings.Standard[174]);
        Assert.Null(PdfEncodings.Standard[127]);
    }

    [Fact]
    public void WinAnsiMatchesCodePage1252()
    {
        Assert.Equal("quotesingle", PdfEncodings.WinAnsi[39]);
        Assert.Equal("Euro", PdfEncodings.WinAnsi[128]);
        Assert.Equal("Zcaron", PdfEncodings.WinAnsi[142]);
        Assert.Equal("eacute", PdfEncodings.WinAnsi[233]);
        Assert.Equal("ydieresis", PdfEncodings.WinAnsi[255]);
    }

    [Fact]
    public void WinAnsiShowsBulletsForUnusedCodes()
    {
        Assert.Equal("bullet", PdfEncodings.WinAnsi[127]);
        Assert.Equal("bullet", PdfEncodings.WinAnsi[129]);
        Assert.Equal("space", PdfEncodings.WinAnsi[160]);
        Assert.Equal("hyphen", PdfEncodings.WinAnsi[173]);
    }

    [Fact]
    public void MacRomanAndExpert()
    {
        Assert.Equal("Adieresis", PdfEncodings.MacRoman[128]);
        Assert.Equal("space", PdfEncodings.MacRoman[202]);
        Assert.Equal("Asmall", PdfEncodings.MacExpert[97]);
    }

    [Fact]
    public void PdfDocHasItsAccentsBelowSpace()
    {
        Assert.Equal("breve", PdfEncodings.PdfDoc[24]);
        Assert.Equal("caron", PdfEncodings.PdfDoc[25]);
        Assert.Equal("Euro", PdfEncodings.PdfDoc[160]);
    }

    [Fact]
    public void BuiltInEncodingsOfSymbolAndZapfDingbats()
    {
        Assert.Equal("alpha", PdfEncodings.Symbol[97]);
        Assert.Equal("universal", PdfEncodings.Symbol[34]);
        Assert.Equal("a1", PdfEncodings.ZapfDingbats[33]);
        Assert.Equal("space", PdfEncodings.ZapfDingbats[32]);
    }

    [Fact]
    public void EveryNameResolvesToUnicode()
    {
        foreach (var table in All.Where(t => t != PdfEncodings.MacExpert))
            foreach (var name in table.Where(n => n != null))
                Assert.True(GlyphList.UnicodeOf(name!) != null, name);
    }

    [Fact]
    public void ByNameAndCodeOf()
    {
        Assert.Same(PdfEncodings.WinAnsi, PdfEncodings.ByName("WinAnsiEncoding"));
        Assert.Null(PdfEncodings.ByName("Identity-H"));
        Assert.Equal(65, PdfEncodings.CodeOf(PdfEncodings.WinAnsi, "A"));
        Assert.Equal(-1, PdfEncodings.CodeOf(PdfEncodings.Standard, "Euro"));
    }
}
