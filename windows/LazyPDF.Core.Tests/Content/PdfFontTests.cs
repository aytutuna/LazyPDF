using System.Text;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class PdfFontTests
{
    private static PdfDocument Document(params string[] objects) =>
        ContentTestPdf.Page("", "", [.. objects]);

    private static PdfDocument Fonts(Action<TestPdf> more) => ContentTestPdf.Page("", "", more);

    private static PdfFont Font(PdfDocument d, int number) => PdfFont.Get(d, (PdfDictionary)d.Get(number)!);

    private static byte[] B(string s) => Encoding.Latin1.GetBytes(s);

    [Fact]
    public void StandardFontWidthsAndTextWithoutAWidthsArray()
    {
        var d = Document("<</Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold>>");
        var font = Font(d, 5);
        var chars = font.Decode(B("A b"));
        Assert.Equal([722.0, 278, 611], chars.Select(c => c.Width));
        Assert.Equal("A b", font.ToText(B("A b")));
        Assert.True(font.IsBold);
        Assert.True(chars[1].IsSpace);
        Assert.False(font.IsEmbedded);
    }

    [Fact]
    public void WindowsNamesMapToTheStandardFonts()
    {
        var d = Document("<</Type /Font /Subtype /TrueType /BaseFont /ABCDEF+TimesNewRomanPS-BoldMT /Encoding /WinAnsiEncoding>>");
        var font = Font(d, 5);
        Assert.Equal("TimesNewRomanPS-BoldMT", font.Name);
        Assert.Equal(722, font.Decode(B("A"))[0].Width);
    }

    [Fact]
    public void WidthsArrayMissingWidthAndOutOfRangeCodes()
    {
        var d = Document("<</Type /Font /Subtype /Type1 /BaseFont /Foo /FirstChar 65 /LastChar 66 /Widths [500 600] /FontDescriptor 6 0 R>>",
            "<</Type /FontDescriptor /FontName /Foo /Flags 32 /MissingWidth 300 /Ascent 900 /Descent 250 /CapHeight 700>>");
        var font = Font(d, 5);
        Assert.Equal([500.0, 600, 300, 300], font.Decode(B("ABCa")).Select(c => c.Width));
        Assert.Equal(900, font.Ascent);
        Assert.Equal(-250, font.Descent);
    }

    [Fact]
    public void AnUnknownFontWithoutWidthsBorrowsHelveticaMetrics()
    {
        var d = Document("<</Type /Font /Subtype /Type1 /BaseFont /Foo>>");
        Assert.Equal(667, Font(d, 5).Decode(B("A"))[0].Width);
    }

    [Fact]
    public void DifferencesRenameCodes()
    {
        var d = Document("<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding <</Type /Encoding /BaseEncoding /WinAnsiEncoding /Differences [65 /Euro /ccedilla 200 /uni011F]>>>>");
        var font = Font(d, 5);
        Assert.Equal("€ç", font.ToText(B("AB")));
        Assert.Equal("ğ", font.ToText([200]));
        Assert.Equal("C", font.ToText(B("C")));
    }

    [Fact]
    public void WinAnsiAndMacRomanDifferInTheUpperHalf()
    {
        var d = Document("<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding>>",
            "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /MacRomanEncoding>>");
        Assert.Equal("é", Font(d, 5).ToText([0xE9]));
        Assert.Equal("é", Font(d, 6).ToText([0x8E]));
    }

    [Fact]
    public void ToUnicodeWinsOverTheEncoding()
    {
        string cmap = "/CIDInit /ProcSet findresource begin 12 dict begin begincmap 1 begincodespacerange <00> <FF> endcodespacerange " +
                      "2 beginbfchar <41> <005A> <42> <00660069> endbfchar endcmap";
        var d = Fonts(pdf =>
        {
            pdf.Obj(5, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /ToUnicode 6 0 R>>");
            pdf.Stream(6, "", cmap);
        });
        var font = Font(d, 5);
        Assert.True(font.HasToUnicode);
        Assert.Equal("Zfi", font.ToText(B("AB")));
        Assert.Equal("C", font.ToText(B("C")));
    }

    [Fact]
    public void Type0WithIdentityHReadsWidthsFromW()
    {
        var d = Document("<</Type /Font /Subtype /Type0 /BaseFont /X /Encoding /Identity-H /DescendantFonts [6 0 R]>>",
            "<</Type /Font /Subtype /CIDFontType2 /BaseFont /X /CIDSystemInfo <</Registry (Adobe) /Ordering (Identity) /Supplement 0>> /DW 800 /W [1 [500 600] 10 20 700]>>");
        var font = Font(d, 5);
        var chars = font.Decode([0, 1, 0, 2, 0, 15, 0, 50]);
        Assert.Equal([500.0, 600, 700, 800], chars.Select(c => c.Width));
        Assert.Equal([1, 2, 15, 50], chars.Select(c => c.Cid));
        Assert.All(chars, c => Assert.Equal(2, c.Length));
        Assert.True(font.IsComposite);
        Assert.False(font.IsVertical);
    }

    [Fact]
    public void VerticalMetricsFromDw2AndW2()
    {
        var d = Document("<</Type /Font /Subtype /Type0 /BaseFont /X /Encoding /Identity-V /DescendantFonts [6 0 R]>>",
            "<</Type /Font /Subtype /CIDFontType0 /BaseFont /X /CIDSystemInfo <</Registry (Adobe) /Ordering (Identity) /Supplement 0>> /DW 1000 /DW2 [900 -950] /W2 [5 [-500 100 800] 7 8 -600 200 700]>>");
        var font = Font(d, 5);
        Assert.True(font.IsVertical);
        var c = font.Decode([0, 1, 0, 5, 0, 8]);
        Assert.Equal((-950.0, 500.0, 900.0), (c[0].VerticalAdvance, c[0].OriginX, c[0].OriginY));
        Assert.Equal((-500.0, 100.0, 800.0), (c[1].VerticalAdvance, c[1].OriginX, c[1].OriginY));
        Assert.Equal((-600.0, 200.0, 700.0), (c[2].VerticalAdvance, c[2].OriginX, c[2].OriginY));
    }

    [Fact]
    public void MixedLengthCMapsCutTheStringByCodespace()
    {
        var d = Document("<</Type /Font /Subtype /Type0 /BaseFont /X /Encoding /90ms-RKSJ-H /DescendantFonts [6 0 R]>>",
            "<</Type /Font /Subtype /CIDFontType2 /BaseFont /X /CIDSystemInfo <</Registry (Adobe) /Ordering (Japan1) /Supplement 2>> /DW 1000>>");
        var chars = Font(d, 5).Decode([0x41, 0x82, 0xA0, 0x42]);
        Assert.Equal([1, 2, 1], chars.Select(c => c.Length));
        Assert.Equal("A", chars[0].Unicode);
        Assert.Equal("あ", chars[1].Unicode);
    }

    [Fact]
    public void AnAdobeCollectionGivesUnicodeWithoutAToUnicodeMap()
    {
        var d = Document("<</Type /Font /Subtype /Type0 /BaseFont /X /Encoding /Identity-H /DescendantFonts [6 0 R]>>",
            "<</Type /Font /Subtype /CIDFontType0 /BaseFont /X /CIDSystemInfo <</Registry (Adobe) /Ordering (Japan1) /Supplement 2>>>>");
        Assert.Equal("A", Font(d, 5).ToText([0, 34]));
    }

    [Fact]
    public void AnEmbeddedCMapStreamIsRead()
    {
        string cmap = "/CIDInit /ProcSet findresource begin 12 dict begin begincmap /CMapName /Custom def /WMode 0 def " +
                      "1 begincodespacerange <00> <FF> endcodespacerange 1 begincidrange <20> <7E> 100 endcidrange endcmap";
        var d = Fonts(pdf =>
        {
            pdf.Obj(5, "<</Type /Font /Subtype /Type0 /BaseFont /X /Encoding 7 0 R /DescendantFonts [6 0 R]>>");
            pdf.Obj(6, "<</Type /Font /Subtype /CIDFontType2 /BaseFont /X /DW 500 /W [100 [250]]>>");
            pdf.Stream(7, "/Type /CMap /CMapName /Custom", cmap);
        });
        var c = Font(d, 5).Decode(B("  "));
        Assert.Equal([1, 1], c.Select(x => x.Length));
        Assert.Equal(100, c[0].Cid);
        Assert.Equal(250, c[0].Width);
    }

    [Fact]
    public void BrokenFontsNeverThrow()
    {
        var d = Document("<<>>", "<</Type /Font /Subtype /Type0>>", "<</Type /Font /Subtype /Type0 /DescendantFonts [<<>>] /Encoding /NoSuchCMap>>",
            "<</Type /Font /Subtype /TrueType /Widths [/a (b) 3 [4]] /FirstChar -5 /Encoding 3>>",
            "<</Type /Font /Subtype /Type3 /FontMatrix [0 0 0 0 0 0] /Widths 5>>",
            "<</Type /Font /Subtype /Type1 /Encoding <</Differences [/a 99999 /b -4 (x)]>> /ToUnicode 5 0 R>>",
            "<</Type /Font /Subtype /Type0 /DescendantFonts [<</W [1 2 3 [4] 70000 80000 5 -3 /x]>>]>>");
        foreach (int n in new[] { 5, 6, 7, 8, 9, 10, 11 })
        {
            var font = Font(d, n);
            var chars = font.Decode([0, 1, 2, 65, 200, 255, 0, 3]);
            Assert.NotEmpty(chars);
            Assert.All(chars, c => Assert.True(c.Length >= 1 && double.IsFinite(c.Width)));
        }
    }

    [Fact]
    public void ReadAlwaysMakesProgress()
    {
        var d = Document("<</Type /Font /Subtype /Type0 /BaseFont /X /Encoding /UniJIS-UTF16-H /DescendantFonts [<<>>]>>");
        var font = Font(d, 5);
        ReadOnlySpan<byte> bytes = [0xD8, 0x00, 0xFF];
        int total = 0;
        while (!bytes.IsEmpty)
        {
            int used = font.Read(bytes, out _);
            Assert.True(used > 0);
            bytes = bytes[used..];
            total++;
        }
        Assert.True(total >= 1);
        Assert.Equal(0, font.Read([], out _));
    }

    [Fact]
    public void ADictionaryGivesTheSameFontEachTime()
    {
        var d = Document(ContentTestPdf.Helvetica);
        Assert.Same(Font(d, 5), Font(d, 5));
    }

    [Fact]
    public void SubtypeIsGuessedWhenMissing()
    {
        var d = Document("<</BaseFont /Helvetica>>", "<</DescendantFonts [<<>>]>>");
        Assert.Equal("Type1", Font(d, 5).Subtype);
        Assert.Equal("Type0", Font(d, 6).Subtype);
    }

    [Fact]
    public void WholeTrueTypeFileGivesUnicodeFromItsCmap()
    {
        string path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Fonts), "arial.ttf");
        Assert.True(File.Exists(path), "arial.ttf is not installed; these tests need it");
        var bytes = File.ReadAllBytes(path);
        var tt = TrueTypeFont.TryParse(bytes)!;
        int gid = tt.GlyphForCodePoint('ğ');
        var d = Fonts(pdf =>
        {
            pdf.Obj(5, "<</Type /Font /Subtype /Type0 /BaseFont /Arial /Encoding /Identity-H /DescendantFonts [6 0 R]>>");
            pdf.Obj(6, "<</Type /Font /Subtype /CIDFontType2 /BaseFont /Arial /CIDSystemInfo <</Registry (Adobe) /Ordering (Identity) /Supplement 0>> /FontDescriptor 7 0 R /CIDToGIDMap /Identity>>");
            pdf.Obj(7, "<</Type /FontDescriptor /FontName /Arial /Flags 32 /FontFile2 8 0 R>>");
            pdf.Stream(8, "", bytes);
        });
        var font = Font(d, 5);
        Assert.True(font.IsEmbedded);
        Assert.Equal("ğ", font.ToText([(byte)(gid >> 8), (byte)gid]));
    }

    [Fact]
    public void EmbeddedSimpleTrueTypeWithoutEncodingReadsItsCmapBack()
    {
        string path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Fonts), "arial.ttf");
        Assert.True(File.Exists(path), "arial.ttf is not installed; these tests need it");
        var d = Fonts(pdf =>
        {
            pdf.Obj(5, "<</Type /Font /Subtype /TrueType /BaseFont /Arial /FontDescriptor 6 0 R>>");
            pdf.Obj(6, "<</Type /FontDescriptor /FontName /Arial /Flags 4 /FontFile2 7 0 R>>");
            pdf.Stream(7, "", File.ReadAllBytes(path));
        });
        var font = Font(d, 5);
        Assert.Equal("Hello", font.ToText(B("Hello")));
        Assert.True(font.Decode(B("H"))[0].Width > 0);
    }
}
