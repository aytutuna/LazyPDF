using System.Text;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class GlyphlessFontTests
{
    [Fact]
    public void ProgramIsATrueTypeFontWithOneEmptyHalfEmGlyph()
    {
        var font = TrueTypeFont.TryParse(GlyphlessFont.Program);
        Assert.NotNull(font);
        Assert.Equal(2, font.GlyphCount);
        Assert.Equal(1000, font.UnitsPerEm);
        Assert.Equal(500, font.GetAdvance(1));
        Assert.Null(font.GetBounds(1));
        Assert.Equal(GlyphlessFont.Program, GlyphlessFont.Build());
    }

    [Fact]
    public void CidToGidMapSendsEveryCodeToGlyphOne()
    {
        byte[] map = PdfFilters.Inflate(GlyphlessFont.CidToGidMap);
        Assert.Equal(GlyphlessFont.CodeCount * 2, map.Length);
        for (int i = 0; i < map.Length; i += 2) Assert.Equal((0, 1), (map[i], map[i + 1]));
    }

    [Fact]
    public void CodesAreUtf16UnitsAndWideCharactersGetSurrogateCodes()
    {
        string wide = char.ConvertFromUtf32(0x1F600), cjk = char.ConvertFromUtf32(0x20000);
        var codes = GlyphlessCodes.For(["a" + wide, cjk + wide + "\ud800"]);
        Assert.Equal([0x61, 0xD800], codes.Codes("a" + wide));
        Assert.Equal([0xD801, 0xD800, GlyphlessCodes.ReplacementCode], codes.Codes(cjk + wide + "\ud800"));
        Assert.Equal(new byte[] { 0x00, 0x61, 0xD8, 0x00 }, codes.Bytes("a" + wide));
        Assert.True(codes.Covers("a" + cjk));
        Assert.False(codes.Covers(char.ConvertFromUtf32(0x1F601)));
        Assert.False(codes.Covers("\ud800"));
    }

    [Fact]
    public void MoreWideCharactersThanCodesBecomeReplacements()
    {
        var texts = Enumerable.Range(0, GlyphlessCodes.SupplementaryCapacity + 10).Select(i => char.ConvertFromUtf32(0x20000 + i)).ToList();
        var codes = GlyphlessCodes.For(texts);
        Assert.Equal(GlyphlessCodes.SupplementaryCapacity, codes.Supplementary.Count);
        Assert.Equal([GlyphlessCodes.ReplacementCode], codes.Codes(texts[^1]));
    }

    [Fact]
    public void ToUnicodeMapGivesTextBackAndTheFontReadsBackItsCodes()
    {
        string wide = char.ConvertFromUtf32(0x1F600);
        var codes = GlyphlessCodes.For([wide, char.ConvertFromUtf32(0x20000)]);
        var map = CMap.Parse(Encoding.ASCII.GetBytes(codes.ToUnicodeCMap()));
        Assert.Equal("A", map.UnicodeOf(0x41));
        Assert.Equal("ğ", map.UnicodeOf(0x11F));
        Assert.Equal(wide, map.UnicodeOf(0xD800));
        Assert.Equal(char.ConvertFromUtf32(0x20000), map.UnicodeOf(0xD801));
        Assert.Null(map.UnicodeOf(0xD802));

        var document = OcrKit.Scan();
        PdfOcrLayer.Add(document, [new OcrPageWords(0, [OcrKit.Word(wide + "x" + char.ConvertFromUtf32(0x20000), 10, 10, 90, 20)], 400, 600)], "en");
        var font = OcrLayerContent.FontOf(document, document.Pages[0], OcrLayerContent.FontName)!;
        var read = GlyphlessCodes.From(font);
        Assert.Equal([0x1F600, 0x20000], read.Supplementary);
        Assert.Equal(codes.Codes(wide + "x"), read.Codes(wide + "x"));
    }
}
