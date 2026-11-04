using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

// Content that two viewers may split differently is not understood: the page becomes a picture instead of being cut by the parser's reading.
public class RedactStrictContentTests
{
    private const string Word = "BT /F1 12 Tf 100 100 Td (ZQXSECRET) Tj ET";
    private static readonly RedactionMark Near = RedactionMark.FromRect(0, new PdfRect(90, 90, 300, 120));

    private static void AssertFlat(string content, string resources = "") =>
        RedactionKit.AssertFlattened(RedactionKit.Page(content, resources), [Near], "ZQXSECRET");

    [Theory]
    [InlineData("BT /F1 12 Tf 100 100 Td 300 300 ] Td (ZQXSECRET) Tj ET")]
    [InlineData("BT /F1 12 Tf 100 100 Td 300 300 } Td (ZQXSECRET) Tj ET")]
    [InlineData("BT /F1 12 Tf 100 100 Td 300 300 > Td (ZQXSECRET) Tj ET")]
    [InlineData("BT /F1 12 Tf 100 100 Td 300 300 ) Td (ZQXSECRET) Tj ET")]
    [InlineData("BT /F1 12 Tf 100 100 Td 300 300 { Td (ZQXSECRET) Tj ET")]
    [InlineData("BT /F1 12 Tf 100 100 Td 300-300 Td (ZQXSECRET) Tj ET")]
    [InlineData("BT /F1 12 Tf 100 100 Td 300 300Td (ZQXSECRET) Tj ET")]
    [InlineData("BT /F1 12 Tf 100 100 Td 1.2.3 0 Td (ZQXSECRET) Tj ET")]
    [InlineData("BT /F1 12 Tf 4294967296 0 Td 100 100 Td (ZQXSECRET) Tj ET")]
    [InlineData("BT /F1 12 Tf 1E3 0 Td 100 100 Td (ZQXSECRET) Tj ET")]
    public void StrayDelimitersAndOddNumbersMakeThePagePicture(string content) => AssertFlat(content);

    [Theory]
    [InlineData(Word + "\n% ZQXSECRET is here\nq Q")]
    [InlineData(Word + " (ZQXSECRET)")]
    [InlineData(Word + " [(ZQXSECRET) 1")]
    [InlineData(Word + " <</Note (ZQXSECRET)")]
    [InlineData("BT /F1 12 Tf 1 0 0 1 100 100 Tm q 1 0 0 1 400 400 Tm Q (ZQXSECRET) Tj ET")]
    [InlineData("BT /F1 12 Tf 100 100 Td 1 0 0 1 300 0 cm (ZQXSECRET) Tj ET")]
    public void CommentsLeftOperandsAndPaintingInsideATextObjectMakeThePagePicture(string content) => AssertFlat(content);

    [Fact]
    public void FormEndingInAnOperandMakesThePagePicture()
    {
        using var document = RedactionKit.Page(Word + " /Fm Do", "/XObject <</Fm 6 0 R>>",
            pdf => pdf.Stream(6, "/Type /XObject /Subtype /Form /BBox [0 0 600 800]", "q Q (ZQXSECRET)"));
        RedactionKit.AssertFlattened(document, [Near], "ZQXSECRET");
    }

    [Theory]
    [InlineData("% tail", "1 0 0 1 300 0 cm\n" + Word)]
    [InlineData("BT /F1 12 Tf 100 100 Td (ZQX", "SECRET) Tj ET")]
    [InlineData("BT /F1 12 Tf 100 100 Td (ZQXSECRET) T", "j ET")]
    public void TokenOpenAtTheEndOfAContentStreamMakesThePagePicture(string first, string second)
    {
        using var document = RedactionKit.Page("");
        document.Pages[0].Dictionary["Contents"] = new PdfArray([Stream(document, first), Stream(document, second)]);
        RedactionKit.AssertFlattened(document, [Near], "ZQXSECRET");
    }

    [Fact]
    public void ContentStreamThatDoesNotReadMakesThePagePicture()
    {
        using var document = RedactionKit.Page("");
        var broken = document.Add(new PdfStream(new PdfDictionary { ["Filter"] = new PdfName("BogusDecode") }, "OTHERTEXT"u8.ToArray()));
        document.Pages[0].Dictionary["Contents"] = new PdfArray([Stream(document, Word), broken]);
        RedactionKit.AssertFlattened(document, [Near], "ZQXSECRET");
    }

    [Fact]
    public void ContentStreamsThatEndOnWholeTokensAreStillCut()
    {
        using var document = RedactionKit.Page("");
        document.Pages[0].Dictionary["Contents"] = new PdfArray([Stream(document, "BT /F1 12 Tf 100 100 Td [(ZQX)"), Stream(document, "(SECRET)] TJ ET")]);
        var result = new PdfRedactor(document).Apply([Near]);
        Assert.Empty(result.Report.Flattened);
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXSECRET"));
    }

    [Fact]
    public void PatternNameOutsideAPatternSpaceMakesThePagePicture()
    {
        using var document = RedactionKit.Page("/P1 scn 100 100 200 200 re f " + Word, "/Pattern <</P1 6 0 R>>",
            pdf => pdf.Stream(6, "/Type /Pattern /PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 10 10] /XStep 10 /YStep 10 /Resources <<>>", "0 0 5 5 re f"));
        RedactionKit.AssertFlattened(document, [Near], "ZQXSECRET");
    }

    [Fact]
    public void SetColourWithAPatternNameMakesThePagePicture()
    {
        using var document = RedactionKit.Page("/Pattern cs /P1 sc 100 100 200 200 re f " + Word, "/Pattern <</P1 6 0 R>>",
            pdf => pdf.Obj(6, "<</PatternType 2 /Shading <</ShadingType 2 /ColorSpace /DeviceGray /Coords [0 0 600 0] /Function <</FunctionType 2 /Domain [0 1] /N 1>>>>>>"));
        RedactionKit.AssertFlattened(document, [Near], "ZQXSECRET");
    }

    [Fact]
    public void FontOfAnUnknownKindMakesThePagePicture()
    {
        using var document = RedactionKit.Page("BT /F2 12 Tf 100 100 Td (ZQXSECRET) Tj ET", "/Font <</F2 6 0 R>>", pdf =>
        {
            pdf.Obj(6, "<</Type /Font /Subtype /Foo /BaseFont /Helvetica /Encoding /Identity-H /DescendantFonts [7 0 R]>>");
            pdf.Obj(7, "<</Type /Font /Subtype /CIDFontType2 /BaseFont /Helvetica /DW 100>>");
        });
        RedactionKit.AssertFlattened(document, [Near], "ZQXSECRET");
    }

    [Fact]
    public void TextAndTextObjectsInOrderStayText()
    {
        using var document = RedactionKit.Page("q 1 0 0 1 0 0 cm " + Word + " Q BT /F1 12 Tf 300 300 Td (kept) Tj ET");
        var result = new PdfRedactor(document).Apply([Near]);
        Assert.Empty(result.Report.Flattened);
        using var output = RedactionKit.Open(result);
        Assert.Equal("kept", RedactionKit.Text(output));
    }

    private static PdfReference Stream(PdfDocument document, string content) =>
        document.Add(new PdfStream(new PdfDictionary(), System.Text.Encoding.Latin1.GetBytes(content)));
}
