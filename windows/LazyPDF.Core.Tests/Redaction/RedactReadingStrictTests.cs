using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

// Content that a viewer may place or measure differently from the scan is not redacted in place.
public class RedactReadingStrictTests
{
    private const string Word = RedactionFiles.Word;

    [Theory]
    [InlineData("[1 0 0 1 null 300]")]
    [InlineData("[1 0 0 1 0 300 0]")]
    [InlineData("[1 0 0 1 /X 300]")]
    public void FormMatrixThatIsNotSixNumbersMakesAPicture(string matrix)
    {
        using var document = RedactionFiles.Open("/Fm1 Do", "/XObject <</Fm1 6 0 R>>", pdf =>
            pdf.Stream(6, $"/Type /XObject /Subtype /Form /BBox [0 0 600 800] /Matrix {matrix} /Resources <</Font <</F1 5 0 R>>>>", Word));
        RedactionKit.AssertFlattened(document, new PdfRect(90, 390, 300, 420), "ZQXSECRET");
    }

    private static string Widths(int first, int last, int width) =>
        $"/FirstChar {first} /LastChar {last} /Widths [{string.Join(" ", Enumerable.Repeat(width, last - first + 1))}]";

    [Theory]
    [InlineData(32, 126, 50000, 95)]
    [InlineData(32, 126, -5, 95)]
    [InlineData(65, 65, 500, 60)]
    public void WidthsThatAreNotTheViewersMakeAPicture(int first, int last, int width, int count)
    {
        string widths = $"/FirstChar {first} /LastChar {last} /Widths [{string.Join(" ", Enumerable.Repeat(width, count))}]";
        using var document = RedactionFiles.Open("BT /F2 12 Tf -593 Tc 100 100 Td (ZQXSECRET) Tj ET", fonts: "/F2 6 0 R", more: pdf =>
            pdf.Obj(6, $"<</Type /Font /Subtype /Type1 /BaseFont /Helvetica {widths}>>"));
        RedactionKit.AssertFlattened(document, new PdfRect(95, 95, 185, 125), "ZQXSECRET");
    }

    [Fact]
    public void WidthsThatAgreeWithTheirRangeStayText()
    {
        using var document = RedactionFiles.Open("BT /F2 12 Tf 100 100 Td (ZQXSECRET) Tj ET", fonts: "/F2 6 0 R", more: pdf =>
            pdf.Obj(6, $"<</Type /Font /Subtype /Type1 /BaseFont /Helvetica {Widths(32, 126, 500)}>>"));
        var result = new PdfRedactor(document).Apply([RedactionMark.FromRect(0, RedactionFiles.Over)]);
        Assert.Empty(result.Report.Flattened);
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXSECRET"));
    }

    [Fact]
    public void FontWithoutWidthsThatIsNeitherStandardNorEmbeddedMakesAPicture()
    {
        using var document = RedactionFiles.Open("BT /F2 12 Tf 100 100 Td (ZQXSECRET) Tj ET", fonts: "/F2 6 0 R", more: pdf =>
            pdf.Obj(6, "<</Type /Font /Subtype /Type1 /BaseFont /Garamond>>"));
        RedactionKit.AssertFlattened(document, RedactionFiles.Over, "ZQXSECRET");
    }

    [Fact]
    public void CompositeFontWithAnAbsurdDefaultWidthMakesAPicture()
    {
        using var document = RedactionFiles.Open("BT /F2 12 Tf 100 100 Td <005A0051> Tj ET", fonts: "/F2 6 0 R", more: pdf =>
        {
            pdf.Obj(6, "<</Type /Font /Subtype /Type0 /BaseFont /Helvetica /Encoding /Identity-H /DescendantFonts [7 0 R]>>");
            pdf.Obj(7, "<</Type /Font /Subtype /CIDFontType2 /BaseFont /Helvetica /CIDSystemInfo <</Registry (Adobe) /Ordering (Identity) /Supplement 0>> /DW 50000>>");
        });
        RedactionKit.AssertFlattened(document, RedactionFiles.Over);
    }

    [Fact]
    public void ImageDataHoldingEiMakesAPicture()
    {
        string data = "x\nEI\nBT /F1 12 Tf 100 100 Td (ZQXSECRET) Tj ET\nq\n";
        data += new string('p', 1000 - data.Length);
        using var document = RedactionFiles.Open($"q 10 0 0 10 500 700 cm BI /W 1000 /H 1 /BPC 8 /CS /G ID {data}\nEI Q");
        RedactionKit.AssertFlattened(document, RedactionFiles.Over, "ZQXSECRET");
    }

    [Fact]
    public void TextOperatorsOutsideATextObjectMakeAPicture()
    {
        using var document = RedactionFiles.Open("BT /F1 12 Tf 100 100 Td ET q BT 300 300 Td ET Q (ZQXSECRET) Tj");
        RedactionKit.AssertFlattened(document, RedactionFiles.Over, "ZQXSECRET");
    }

    [Fact]
    public void NumbersAboveWhatAFloatKeepsMakeAPicture()
    {
        using var document = RedactionFiles.Open("q 1 0 0 1 1000000000 0 cm 1 0 0 1 -999999900 0 cm BT /F1 12 Tf 0 100 Td (ZQXSECRET) Tj ET Q");
        RedactionKit.AssertFlattened(document, RedactionFiles.Over, "ZQXSECRET");
    }

    [Fact]
    public void NamedPatternSpaceDoesNotFlattenAPageWhosePatternIsFarFromTheMark()
    {
        using var document = RedactionFiles.Open("/Cs1 cs 0 0 0 /P1 scn 400 600 50 50 re f 0 g " + Word, "/ColorSpace <</Cs1 [/Pattern /DeviceRGB]>> /Pattern <</P1 6 0 R>>", pdf =>
            pdf.Stream(6, "/PatternType 1 /PaintType 2 /TilingType 1 /BBox [0 0 10 10] /XStep 10 /YStep 10 /Resources <<>>", "0 0 5 5 re f"));
        var result = new PdfRedactor(document).Apply([RedactionMark.FromRect(0, RedactionFiles.Over)]);
        Assert.Empty(result.Report.Flattened);
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXSECRET"));
    }

    private static string Type3(string differences, string matrix = "[0.001 0 0 0.001 0 0]") =>
        $"<</Type /Font /Subtype /Type3 /FontBBox [0 0 1000 1000] /FontMatrix {matrix} /CharProcs <</a 7 0 R /evil 8 0 R>> /Encoding <</Type /Encoding /Differences [{differences}]>> /FirstChar 97 /LastChar 97 /Widths [1000]>>";

    [Fact]
    public void Type3FontWithMoreDifferencesThanAreReadMakesAPicture()
    {
        using var document = RedactionFiles.Open("BT /F2 10 Tf 50 50 Td (a) Tj ET", fonts: "/F2 6 0 R", more: pdf =>
        {
            pdf.Obj(6, Type3(string.Concat(Enumerable.Repeat("97 /a ", 2100)) + "97 /evil"));
            pdf.Stream(7, "", "1000 0 d0 0 0 100 100 re f");
            pdf.Stream(8, "", "1000 0 d0 20000 20000 5000 5000 re f");
        });
        RedactionKit.AssertFlattened(document, new PdfRect(240, 240, 310, 310));
    }

    [Fact]
    public void Type3FontMatrixWithSevenNumbersMakesAPicture()
    {
        using var document = RedactionFiles.Open("BT /F2 10 Tf 50 50 Td (a) Tj ET", fonts: "/F2 6 0 R", more: pdf =>
        {
            pdf.Obj(6, Type3("97 /a", "[0.001 0 0 0.001 0 0 0]"));
            pdf.Stream(7, "", "1000 0 d0 0 0 100 100 re f");
            pdf.Stream(8, "", "1000 0 d0 0 0 100 100 re f");
        });
        RedactionKit.AssertFlattened(document, new PdfRect(400, 400, 500, 500));
    }

    [Fact]
    public void Type3GlyphThatIsOnlyAHairlineIsStillInk()
    {
        using var document = RedactionFiles.Open("BT /F2 10 Tf 50 50 Td (a) Tj ET", fonts: "/F2 6 0 R", more: pdf =>
        {
            pdf.Obj(6, Type3("97 /a"));
            pdf.Stream(7, "", "1000 0 d0 0 w 20000 20000 m 25000 20000 l S");
            pdf.Stream(8, "", "1000 0 d0 0 0 1 1 re f");
        });
        RedactionKit.AssertFlattened(document, new PdfRect(200, 240, 320, 260));
    }
}
