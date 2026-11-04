using LazyPDF.Core;
using Xunit;
using PigDocument = UglyToad.PdfPig.PdfDocument;

namespace LazyPDF.Core.Tests;

public class PdfAFontConversionTests
{
    private static PdfAConversion Convert(byte[] file, PdfALevel level = PdfALevel.A2b, IFontSource? fonts = null) =>
        new PdfAConverter(fonts ?? new SystemFonts()).Convert(file, level, StandardsKit.Date);

    private static byte[] Clean(PdfAConversion result)
    {
        Assert.Null(result.Refusal);
        Assert.True(result.Remaining.Count == 0, string.Join("\n", result.Remaining.Select(i => $"{i.Clause} {i.Where}: {i.Message}")));
        return result.Bytes!;
    }

    private static string PigText(byte[] file)
    {
        using var pig = PigDocument.Open(file);
        return pig.GetPage(1).Text;
    }

    private static byte[] Page(string fontObject, string content, Action<TestPdf>? extra = null)
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 300]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Resources <</Font <</F1 5 0 R>>>>>>");
        pdf.Stream(4, "", content);
        pdf.Obj(5, fontObject);
        extra?.Invoke(pdf);
        return pdf.Finish("/Root 1 0 R");
    }

    private static PdfFont FontOf(PdfDocument document) =>
        PdfFont.Get(document, (PdfDictionary)document.Resolve(((PdfDictionary)document.Resolve(document.Pages[0].Resources!["Font"])!)["F1"])!);

    [Theory]
    [InlineData("Times-BoldItalic", "Times")]
    [InlineData("Courier", "Cour")]
    [InlineData("Helvetica-Oblique", "Arial")]
    public void TheStandardFontsAreReplacedByTheirMetricTwins(string baseFont, string expectedInName)
    {
        SystemFonts.RequireArial();
        byte[] file = Page($"<</Type /Font /Subtype /Type1 /BaseFont /{baseFont} /Encoding /WinAnsiEncoding>>", "BT /F1 12 Tf 20 100 Td (Quick fox) Tj ET");
        byte[] bytes = Clean(Convert(file));
        Assert.Contains("Quick fox", PigText(bytes));
        using var document = PdfDocument.Open(bytes);
        var font = FontOf(document);
        Assert.True(font.IsEmbedded);
        Assert.Contains(expectedInName, font.BaseFont, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void TheWidthsOfTheOldFontSurviveBecauseTheTwinHasTheSameMetrics()
    {
        SystemFonts.RequireArial();
        byte[] file = Page("<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>", "BT /F1 12 Tf 20 100 Td (Wide WWW) Tj ET");
        using var before = PdfDocument.Open(file);
        double expected = FontOf(before).Decode("Wide WWW"u8).Sum(c => c.Width);
        using var after = PdfDocument.Open(Clean(Convert(file)));
        Assert.Equal(expected, FontOf(after).Decode("Wide WWW"u8).Sum(c => c.Width), 0);
    }

    [Fact]
    public void ALatinFontNotInTheStandardSetIsReplacedByTheSourcesClosestFamily()
    {
        SystemFonts.RequireArial();
        byte[] file = Page("<</Type /Font /Subtype /TrueType /BaseFont /Calibri-Bold /Encoding /WinAnsiEncoding /FirstChar 32 /LastChar 33 /Widths [226 326] /FontDescriptor 6 0 R>>",
            "BT /F1 12 Tf 20 100 Td (Hi!) Tj ET",
            pdf => pdf.Obj(6, "<</Type /FontDescriptor /FontName /Calibri-Bold /Flags 32 /FontBBox [0 -200 1000 900] /ItalicAngle 0 /Ascent 750 /Descent -250 /CapHeight 640 /StemV 100>>"));
        byte[] bytes = Clean(Convert(file));
        Assert.Contains("Hi!", PigText(bytes));
    }

    [Fact]
    public void TheSymbolFontIsReplacedByTheSourcesSymbolFont()
    {
        Assert.True(File.Exists(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Fonts), "symbol.ttf")), "symbol.ttf is not installed; this test needs it");
        byte[] file = Page("<</Type /Font /Subtype /Type1 /BaseFont /Symbol>>", "BT /F1 12 Tf 20 100 Td (abg) Tj ET");
        byte[] bytes = Clean(Convert(file));
        using var document = PdfDocument.Open(bytes);
        Assert.Equal("αβγ", FontOf(document).ToText("abg"u8));
    }

    [Fact]
    public void ACompositeFontNotEmbeddedKeepsItsCodesAndGetsGlyphsFromTheSource()
    {
        SystemFonts.RequireArial();
        string toUnicode = "/CIDInit /ProcSet findresource begin 12 dict begin begincmap /CMapName /X def 1 begincodespacerange <0000> <FFFF> endcodespacerange " +
                           "2 beginbfchar <0001> <0048> <0002> <0069> endbfchar endcmap CMapName currentdict /CMap defineresource pop end end";
        byte[] file = Page("<</Type /Font /Subtype /Type0 /BaseFont /ArialMT /Encoding /Identity-H /DescendantFonts [6 0 R] /ToUnicode 8 0 R>>", "BT /F1 12 Tf 20 100 Td <00010002> Tj ET", pdf =>
        {
            pdf.Obj(6, "<</Type /Font /Subtype /CIDFontType2 /BaseFont /ArialMT /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> /FontDescriptor 7 0 R /DW 600>>");
            pdf.Obj(7, "<</Type /FontDescriptor /FontName /ArialMT /Flags 32 /FontBBox [0 -200 1000 900] /ItalicAngle 0 /Ascent 900 /Descent -200 /CapHeight 700 /StemV 80>>");
            pdf.Stream(8, "", toUnicode);
        });
        byte[] bytes = Clean(Convert(file));
        Assert.Contains("Hi", PigText(bytes));
        using var document = PdfDocument.Open(bytes);
        Assert.True(FontOf(document).IsEmbedded);
        Assert.Equal("Hi", FontOf(document).ToText([0, 1, 0, 2]));
    }

    [Fact]
    public void WithoutAFontSourceTheFontStaysAndIsReported()
    {
        byte[] file = Page("<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>", "BT /F1 12 Tf 20 100 Td (Hi) Tj ET");
        var result = new PdfAConverter().Convert(file, PdfALevel.A2b, StandardsKit.Date);
        Assert.NotNull(result.Bytes);
        Assert.Contains(result.Remaining, i => i.Clause == "6.2.11.4.1" && i.Where == "Font Helvetica");
    }

    [Fact]
    public void WrongWidthsOfAnEmbeddedFontAreSetFromItsProgram()
    {
        byte[] simple = PdfAFontTests.Simple(hWidth: 600);
        var result = Convert(simple);
        byte[] bytes = Clean(result);
        Assert.Contains(result.Changes, c => c.Contains("fonts were corrected"));
        using var document = PdfDocument.Open(bytes);
        Assert.Equal(722, FontOf(document).Decode("H"u8)[0].Width, 0);

        using var cid = PdfDocument.Open(Clean(Convert(PdfAFontTests.Composite(hWidth: 500))));
        int h = TrueTypeFont.TryParse(File.ReadAllBytes(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Fonts), "arial.ttf")))!.GlyphForCodePoint('H');
        Assert.Equal(722, FontOf(cid).Decode([(byte)(h >> 8), (byte)h])[0].Width, 0);
    }

    [Fact]
    public void AWrongCidSetAndASymbolicEncodingAreCorrected()
    {
        byte[] withSet = StandardsKit.Edited(PdfAFontTests.Composite(), d => ((PdfDictionary)d.Get(11)!)["CIDSet"] = d.Add(new PdfStream(new PdfDictionary(), new byte[16])));
        Assert.Contains("6.2.11.4.2", StandardsKit.Clauses(withSet));
        Clean(Convert(withSet));

        Clean(Convert(PdfAFontTests.Simple("/Encoding /WinAnsiEncoding", flags: "4")));
        Clean(Convert(PdfAFontTests.Simple("")));
        Clean(Convert(PdfAFontTests.Composite(cidFontEntries: "")));
    }

    [Fact]
    public void AnEmbeddedFontMissingItsToUnicodeGetsOneAtLevelU()
    {
        byte[] bytes = Clean(Convert(PdfAFontTests.Composite(level: PdfALevel.A2u), PdfALevel.A2u));
        using var document = PdfDocument.Open(bytes);
        var font = FontOf(document);
        Assert.True(font.HasToUnicode);
        int h = TrueTypeFont.TryParse(File.ReadAllBytes(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Fonts), "arial.ttf")))!.GlyphForCodePoint('H');
        Assert.Equal("H", font.ToText([(byte)(h >> 8), (byte)h]));
    }
}
