using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

// A removed run keeps no trace of the width of single characters, whatever sits between the shows; the small cases around it.
public class RedactShiftRunTests
{
    private static PdfDocument Redact(PdfDocument document, string word, out RedactionResult result)
    {
        result = new PdfRedactor(document).Apply([RedactionKit.MarkOf(document, 0, word)]);
        return RedactionKit.Open(result);
    }

    private static int Shifts(PdfDocument document) =>
        ContentParser.Parse(document.Pages[0].Contents()).Where(o => o.Operator == "TJ").SelectMany(o => ((PdfArray)o.Operands[^1]).Items.OfType<PdfNumber>()).Count();

    private static int Count(PdfDocument document, string name) => ContentParser.Parse(document.Pages[0].Contents()).Count(o => o.Operator == name);

    private static void AssertOneShift(string content, string resources = "")
    {
        using var document = RedactionKit.Page(content, resources, "<</Type /ExtGState /CA 1>>");
        using var output = Redact(document, "John", out _);
        Assert.Equal(1, Shifts(output));
        Assert.Equal("tail", RedactionKit.Text(output).Trim());
    }

    [Fact]
    public void RepeatedGraphicsStateBetweenShowsKeepsNoWidthPerShow() =>
        AssertOneShift("BT /F1 12 Tf 50 700 Td (J) Tj /G0 gs (o) Tj /G0 gs (h) Tj /G0 gs (n) Tj ( tail) Tj ET", "/ExtGState <</G0 6 0 R>>");

    [Fact]
    public void SaveAndRestoreInsideATextObjectMakesThePagePicture()
    {
        using var document = RedactionKit.Page("BT /F1 12 Tf 50 700 Td q (J) Tj Q q (o) Tj Q q (h) Tj Q q (n) Tj Q ( tail) Tj ET");
        RedactionKit.AssertFlattened(document, [RedactionKit.MarkOf(document, 0, "John")], "John");
    }

    [Fact]
    public void UnchangedHorizontalScaleBetweenShowsKeepsNoWidthPerShow() =>
        AssertOneShift("BT /F1 12 Tf 50 700 Td 100 Tz (J) Tj 100 Tz (o) Tj 100 Tz (h) Tj 100 Tz (n) Tj ( tail) Tj ET");

    [Fact]
    public void OtherFontAtTheSameSizeBetweenShowsKeepsNoWidthPerShow()
    {
        using var document = ContentTestPdf.Page("BT /F1 12 Tf 50 700 Td (J) Tj /F2 12 Tf (o) Tj /F1 12 Tf (h) Tj /F2 12 Tf (n) Tj ( tail) Tj ET",
            "/Font <</F1 5 0 R /F2 5 0 R>>", RedactionKit.Helvetica);
        using var output = Redact(document, "John", out _);
        Assert.Equal(1, Shifts(output));
    }

    [Fact]
    public void ChangedHorizontalScaleStopsTheShift()
    {
        using var document = RedactionKit.Page("BT /F1 12 Tf 50 700 Td (J) Tj (o) Tj (h) Tj (n) Tj 50 Tz ( tail) Tj ET");
        using var output = Redact(document, "John", out _);
        Assert.Equal(1, Shifts(output));
    }

    [Fact]
    public void MatrixUndoneByItsInverseAroundARemovedShowIsDropped()
    {
        double x = 106;
        var content = new System.Text.StringBuilder();
        foreach (var (letter, width) in new[] { ('J', 500), ('o', 556), ('h', 556), ('n', 556) })
        {
            content.Append($"1 0 0 1 {x} 700 cm BT /F1 12 Tf ({letter}) Tj ET 1 0 0 1 -{x} -700 cm ");
            x += width * 12 / 1000.0;
        }
        content.Append("BT /F1 12 Tf 300 300 Td (tail) Tj ET");
        using var document = RedactionKit.Page(content.ToString());
        using var output = Redact(document, "John", out _);
        Assert.Equal(0, Count(output, "cm"));
    }

    [Fact]
    public void MoveWithALeadingBeforeAMoveWithoutOneIsMerged()
    {
        using var document = RedactionKit.Page("BT /F1 12 Tf 50 700 Td (J) Tj 6 0 TD (o) Tj 6.672 0 Td (h) Tj 6.672 0 Td (n) Tj ET");
        using var output = Redact(document, "John", out _);
        Assert.Equal(0, Count(output, "TD"));
    }

    [Fact]
    public void LeadingOfAMoveThatGoesIsKept()
    {
        using var document = RedactionKit.Page("BT /F1 12 Tf 50 700 Td (Name: ) Tj 0 -14 TD (John) Tj ET");
        using var output = Redact(document, "John", out _);
        Assert.Equal(0, Count(output, "TD"));
        Assert.Contains(ContentParser.Parse(output.Pages[0].Contents()), o => o.Operator == "TL" && o.Number(0) == 14);
    }

    [Fact]
    public void PropertyListOfTheEnclosingStreamSeenFromAFormWithResourcesOfItsOwnMakesThePagePicture()
    {
        using var document = RedactionKit.Page("/Fm Do", "/Properties <</P0 <</Alt (ZQXDESCR)>>>> /XObject <</Fm 6 0 R>>", pdf =>
            pdf.Stream(6, "/Type /XObject /Subtype /Form /BBox [0 0 600 800] /Resources <</Font <</F1 5 0 R>>>>", "/Span /P0 BDC BT /F1 12 Tf 100 100 Td (xyzw) Tj ET EMC"));
        RedactionKit.AssertFlattened(document, new PdfRect(90, 90, 200, 120), "ZQXDESCR");
    }

    [Fact]
    public void GlyphTooSmallForTheOldThresholdsStillMeetsTheMark()
    {
        using var document = RedactionKit.Page("BT /F1 0.0002 Tf 100 100 Td (ZQXTINY) Tj ET");
        var result = new PdfRedactor(document).Apply([RedactionMark.FromRect(0, new PdfRect(50, 50, 150, 150))]);
        Assert.Equal(7, result.Report.Glyphs);
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXTINY"));
    }
}
