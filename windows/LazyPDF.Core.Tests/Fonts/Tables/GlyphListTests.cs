using Xunit;

namespace LazyPDF.Core.Tests;

public class GlyphListTests
{
    [Theory]
    [InlineData("A", "A")]
    [InlineData("space", " ")]
    [InlineData("Euro", "€")]
    [InlineData("fi", "ﬁ")]
    [InlineData("uni0041", "A")]
    [InlineData("uni00410042", "AB")]
    [InlineData("u1F600", "\U0001F600")]
    [InlineData("u0041", "A")]
    [InlineData("a.alt", "a")]
    [InlineData("A.swash.1", "A")]
    [InlineData("f_i", "fi")]
    [InlineData("f_f_uni0069", "ffi")]
    [InlineData("a1", "✁")]
    [InlineData("dalethatafpatah", "דֲ")]
    public void Maps(string name, string text) => Assert.Equal(text, GlyphList.UnicodeOf(name));

    [Theory]
    [InlineData("")]
    [InlineData(".notdef")]
    [InlineData("g123")]
    [InlineData("cid1234")]
    [InlineData("uniD800")]
    [InlineData("uni004")]
    [InlineData("uniGGGG")]
    [InlineData("u110000")]
    [InlineData("u+041")]
    [InlineData("_")]
    public void UnmappedNamesGiveNull(string name) => Assert.Null(GlyphList.UnicodeOf(name));

    [Fact]
    public void ComponentsThatDoNotMapAreLeftOut() => Assert.Equal("ab", GlyphList.UnicodeOf("a_g123_b"));

    [Fact]
    public void LongNamesGiveNull() => Assert.Null(GlyphList.UnicodeOf(new string('a', 5000)));

    [Theory]
    [InlineData(0x20, "space")]
    [InlineData(0x41, "A")]
    [InlineData(0x20AC, "Euro")]
    [InlineData(0xFB01, "fi")]
    [InlineData(0x2022, "bullet")]
    public void NameOfPrefersTheEncodingNames(int cp, string name) => Assert.Equal(name, GlyphList.NameOf(cp));

    [Fact]
    public void NameOfFallsBackToUniAndU()
    {
        Assert.Equal("uni4E2D", GlyphList.NameOf(0x4E2D));
        Assert.Equal("u1F600", GlyphList.NameOf(0x1F600));
        Assert.Equal(".notdef", GlyphList.NameOf(0xD800));
        Assert.Equal(".notdef", GlyphList.NameOf(-1));
        Assert.Equal(".notdef", GlyphList.NameOf(0x110000));
    }

    [Fact]
    public void NamesAndTextRoundTrip()
    {
        foreach (var name in PdfEncodings.WinAnsi.Concat(PdfEncodings.Standard).Concat(PdfEncodings.MacRoman).Where(n => n != null).Distinct())
        {
            string text = GlyphList.UnicodeOf(name!)!;
            Assert.Equal(text, GlyphList.UnicodeOf(GlyphList.NameOf(char.ConvertToUtf32(text, 0))));
        }
    }

    [Fact]
    public void ZapfNames()
    {
        Assert.Equal("a1", GlyphList.ZapfNameOf(0x2701));
        Assert.Null(GlyphList.ZapfNameOf(0x41));
    }
}
