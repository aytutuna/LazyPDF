using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class RedactShiftTests
{
    private static List<PdfNumber> Shifts(PdfDocument document) =>
        [.. ContentParser.Parse(document.Pages[0].Contents()).Where(o => o.Operator == "TJ")
            .SelectMany(o => ((PdfArray)o.Operands[^1]).Items.OfType<PdfNumber>())];

    private static (PdfDocument Output, List<DrawnGlyph> Before, List<DrawnGlyph> After) Redact(string content, string word)
    {
        using var document = RedactionKit.Page(content);
        var before = RedactionKit.Glyphs(document);
        var result = new PdfRedactor(document).Apply([RedactionKit.MarkOf(document, 0, word)]);
        var output = RedactionKit.Open(result);
        return (output, before, RedactionKit.Glyphs(output));
    }

    private static void AssertStayedPut(List<DrawnGlyph> before, List<DrawnGlyph> after, int first, int length)
    {
        var kept = before.Where((_, i) => i < first || i >= first + length).ToList();
        Assert.Equal(kept.Count, after.Count);
        for (int i = 0; i < kept.Count; i++)
        {
            Assert.Equal(kept[i].Text, after[i].Text);
            Assert.Equal(kept[i].X, after[i].X, 0.01);
        }
    }

    [Fact]
    public void RemovedRunLeavesOneShiftNotOnePerCharacter()
    {
        var (output, before, after) = Redact("BT /F1 12 Tf 50 700 Td (Name: John Smith and more) Tj ET", "John Smith");
        using (output)
        {
            Assert.Single(Shifts(output));
            AssertStayedPut(before, after, 6, 10);
        }
    }

    [Fact]
    public void ShiftsAroundOriginalKerningBecomeOne()
    {
        var (output, before, after) = Redact("BT /F1 12 Tf 50 700 Td [(Name: Jo) -30 (hn) 120 ( Smith) -40 ( and more)] TJ ET", "John Smith");
        using (output)
        {
            Assert.Single(Shifts(output));
            AssertStayedPut(before, after, 6, 10);
        }
    }

    [Fact]
    public void NoShiftIsKeptWhenTheLineEndsWithTheRemovedRun()
    {
        var (output, before, after) = Redact("BT /F1 12 Tf 50 700 Td (Name: John Smith) Tj 0 -20 Td (next) Tj ET", "John Smith");
        using (output)
        {
            Assert.Empty(Shifts(output));
            AssertStayedPut(before, after, 6, 10);
        }
    }

    [Fact]
    public void ShiftIsKeptWhenAnotherShowContinuesTheLine()
    {
        var (output, before, after) = Redact("BT /F1 12 Tf 50 700 Td (Name: John Smith) Tj ( tail) Tj ET", "John Smith");
        using (output)
        {
            Assert.Single(Shifts(output));
            AssertStayedPut(before, after, 6, 10);
        }
    }

    [Fact]
    public void PaintStateBetweenPathAndPaintDoesNotKeepTheSegments()
    {
        using var document = RedactionKit.Page("230 210 m 270 210 l 257.5 233.5 l 1 0 0 rg f");
        var result = new PdfRedactor(document).Apply([RedactionMark.FromRect(0, new PdfRect(200, 200, 300, 300))]);
        using var output = RedactionKit.Open(result);
        string content = RedactionKit.Latin(output);
        Assert.DoesNotContain("257.5 233.5", content);
        Assert.DoesNotContain("270 210", content);
        Assert.Contains("1 0 0 rg", content);
        Assert.Equal(1, result.Report.Paths);
    }
    private static int Shows(PdfDocument document) =>
        ContentParser.Parse(document.Pages[0].Contents()).Count(o => o.Operator is "Tj" or "TJ");

    [Fact]
    public void RunSpreadOverSeveralShowsLeavesNoWidthPerShow()
    {
        var (output, before, after) = Redact("BT /F1 12 Tf 50 700 Td (J) Tj (o) Tj (h) Tj (n) Tj ( ) Tj (S) Tj (m) Tj (i) Tj (t) Tj (h) Tj ET", "John Smith");
        using (output)
        {
            Assert.Empty(Shifts(output));
            Assert.Equal(0, Shows(output));
        }
    }

    [Fact]
    public void RunSpreadOverSeveralShowsMovesTheTotalToTheNextShow()
    {
        var (output, before, after) = Redact("BT /F1 12 Tf 50 700 Td (Name: J) Tj (o) Tj (h) Tj (n) Tj ( after) Tj ET", "John");
        using (output)
        {
            Assert.Single(Shifts(output));
            AssertStayedPut(before, after, 6, 4);
        }
    }

    [Fact]
    public void PositionsBetweenRemovedShowsDoNotKeepTheirAdvance()
    {
        var (output, before, after) = Redact("BT /F1 12 Tf 50 700 Td (J) Tj 6 0 Td (o) Tj 6.672 0 Td (h) Tj 6.672 0 Td (n) Tj 6.672 0 Td ( tail) Tj ET", "John");
        using (output)
        {
            string content = RedactionKit.Latin(output);
            Assert.DoesNotContain("6 0 Td", content);
            Assert.DoesNotContain("6.672 0 Td", content);
            AssertStayedPut(before, after, 0, 4);
        }
    }

    [Fact]
    public void MatricesBetweenRemovedShowsDoNotKeepTheirPlace()
    {
        var (output, before, after) = Redact("BT /F1 12 Tf 1 0 0 1 56 700 Tm (J) Tj 1 0 0 1 62 700 Tm (o) Tj 1 0 0 1 68.672 700 Tm (h) Tj 1 0 0 1 75.344 700 Tm (n) Tj 1 0 0 1 100 700 Tm (tail) Tj ET", "John");
        using (output)
        {
            string content = RedactionKit.Latin(output);
            Assert.DoesNotContain("62 700", content);
            Assert.DoesNotContain("68.672", content);
            Assert.DoesNotContain("75.344", content);
            AssertStayedPut(before, after, 0, 4);
        }
    }
}
