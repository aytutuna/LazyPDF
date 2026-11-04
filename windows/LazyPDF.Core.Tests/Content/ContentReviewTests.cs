using System.Diagnostics;
using System.Text;
using Xunit;

namespace LazyPDF.Core.Tests;

public class ContentReviewTests
{
    private const string FormEntries = "/Type /XObject /Subtype /Form /BBox [0 0 100 100]";

    private static PdfFont Font(PdfDocument d, int number) => PdfFont.Get(d, (PdfDictionary)d.Get(number)!);

    [Fact]
    public void ADamagedToUnicodeKeepsTheMetricsAndTheEncoding()
    {
        var d = ContentTestPdf.Page("", "", pdf =>
        {
            pdf.Obj(5, "<</Type /Font /Subtype /Type0 /BaseFont /X /Encoding /UniJIS-UCS2-V /DescendantFonts [6 0 R] /ToUnicode 7 0 R>>");
            pdf.Obj(6, "<</Type /Font /Subtype /CIDFontType2 /BaseFont /X /CIDSystemInfo <</Registry (Adobe) /Ordering (Japan1) /Supplement 2>> /DW 900 /W [34 [500]]>>");
            pdf.Stream(7, "/Filter /FlateDecode", "not a zlib stream");
        });
        var font = Font(d, 5);
        Assert.True(font.IsVertical);
        Assert.Equal(500, font.Decode([0, 0x41])[0].Width);
    }

    [Fact]
    public void ADamagedToUnicodeOfASimpleFontKeepsItsWidths()
    {
        var d = ContentTestPdf.Page("", "", pdf =>
        {
            pdf.Obj(5, "<</Type /Font /Subtype /Type1 /BaseFont /Foo /FirstChar 65 /LastChar 65 /Widths [333] /ToUnicode 6 0 R>>");
            pdf.Stream(6, "/Filter /FlateDecode", "garbage");
        });
        Assert.Equal(333, Font(d, 5).Decode("A"u8)[0].Width);
    }

    [Fact]
    public void AToUnicodeAtAnotherCodeWidthStillApplies()
    {
        string cmap = "/CIDInit /ProcSet findresource begin 12 dict begin begincmap 1 begincodespacerange <0000> <FFFF> endcodespacerange " +
                      "1 beginbfchar <0041> <015F> endbfchar endcmap";
        var d = ContentTestPdf.Page("", "", pdf =>
        {
            pdf.Obj(5, "<</Type /Font /Subtype /TrueType /BaseFont /Foo /Encoding /WinAnsiEncoding /ToUnicode 6 0 R>>");
            pdf.Stream(6, "", cmap);
            pdf.Obj(7, "<</Type /Font /Subtype /Type0 /BaseFont /X /Encoding /Identity-H /DescendantFonts [8 0 R] /ToUnicode 9 0 R>>");
            pdf.Obj(8, "<</Type /Font /Subtype /CIDFontType2 /BaseFont /X /DW 500>>");
            pdf.Stream(9, "", cmap.Replace("<0000> <FFFF>", "<00> <FF>").Replace("<0041>", "<41>"));
        });
        Assert.Equal("\u015F", Font(d, 5).ToText("A"u8));
        Assert.Equal("\u015F", Font(d, 7).ToText([0, 0x41]));
    }

    [Fact]
    public void RepeatedWidthRangesAreBoundedByTheWork()
    {
        var w = new StringBuilder("[");
        for (int i = 0; i < 4000; i++) w.Append("0 65535 0 ");
        w.Append(']');
        var d = ContentTestPdf.Page("", "", $"<</Type /Font /Subtype /Type0 /BaseFont /X /Encoding /Identity-H /DescendantFonts [6 0 R]>>",
            $"<</Type /Font /Subtype /CIDFontType2 /BaseFont /X /DW 500 /W {w} /W2 {w}>>");
        var watch = Stopwatch.StartNew();
        Font(d, 5);
        Assert.True(watch.Elapsed < TimeSpan.FromSeconds(2), watch.Elapsed.ToString());
    }

    [Fact]
    public void KerningNumbersCostBudget()
    {
        string form = "BT [" + string.Concat(Enumerable.Repeat("1 ", 1_000_000)) + "] TJ ET";
        string page = string.Concat(Enumerable.Repeat("/Fm Do ", 15));
        var d = ContentTestPdf.Page(page, "/XObject <</Fm 5 0 R>>", pdf => pdf.Stream(5, FormEntries, form));
        var interpreter = new ContentInterpreter(d);
        interpreter.Run(d.Pages[0], new Recorder());
        Assert.True(interpreter.IsTruncated);
    }

    [Fact]
    public void AFormWithTooManyOperationsIsSkipped()
    {
        string form = string.Concat(Enumerable.Repeat("q ", 1_200_000));
        var d = ContentTestPdf.Page("/Fm Do 0 0 1 1 re f", "/XObject <</Fm 5 0 R>>", pdf => pdf.Stream(5, FormEntries, form));
        Assert.Single(ContentTestPdf.Run(d).Paths);
    }

    [Fact]
    public void ThePathSurvivesAFormDrawnInTheMiddleOfIt()
    {
        var d = ContentTestPdf.Page("0 0 m 10 10 l /Fm Do 20 20 l S", "/XObject <</Fm 5 0 R>>", pdf => pdf.Stream(5, FormEntries, "q Q"));
        Assert.Equal(3, ContentTestPdf.Run(d).Paths[0].Path.Segments.Count);
    }

    [Fact]
    public void InlineImageLengthThatOverflowsDoesNotThrow()
    {
        const string header = "BI /W 72057594037927928 /H 1024 /IM true ID ";
        int length = 1100;
        var prefix = new StringBuilder("%".PadRight(length - 1, ' ') + "\n");
        int at = length + header.Length - 1024;
        prefix[at] = 'E';
        prefix[at + 1] = 'I';
        var ops = ContentParser.Parse(ContentTestPdf.Latin(prefix + header + "abc\nEI Q"));
        Assert.Contains(ops, o => o.Operator == "BI");
    }
}
