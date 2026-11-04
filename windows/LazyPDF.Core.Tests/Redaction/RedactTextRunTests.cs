using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

// A producer that writes a state or position operator for every run still gets one shift for what was removed, and no position of a removed run.
public class RedactTextRunTests
{
    private static (string Content, List<DrawnGlyph> Before, List<DrawnGlyph> After) Redact(string content, PdfRect mark)
    {
        using var document = RedactionKit.Page(content);
        var before = RedactionKit.Glyphs(document);
        var result = new PdfRedactor(document).Apply([RedactionMark.FromRect(0, mark)]);
        using var output = RedactionKit.Open(result);
        return (RedactionKit.Latin(output), before, RedactionKit.Glyphs(output));
    }

    private static void AssertStayedPut(List<DrawnGlyph> before, List<DrawnGlyph> after, params int[] removed)
    {
        var kept = before.Where((_, i) => !removed.Contains(i)).ToList();
        Assert.Equal(kept.Count, after.Count);
        for (int i = 0; i < kept.Count; i++)
        {
            Assert.Equal(kept[i].Text, after[i].Text);
            Assert.Equal(kept[i].X, after[i].X, 0.01);
        }
    }

    [Fact]
    public void RepeatedFontOperatorBetweenShowsDoesNotKeepEachWidth()
    {
        var (content, before, after) = Redact("BT /F1 12 Tf 100 700 Td (J) Tj /F1 12 Tf (o) Tj /F1 12 Tf (h) Tj /F1 12 Tf (n) Tj /F1 12 Tf ( Smith) Tj ET", new PdfRect(95, 690, 124, 715));
        Assert.DoesNotContain("556", content);
        Assert.DoesNotContain("-500", content);
        Assert.Contains("-2168", content);
        AssertStayedPut(before, after, 0, 1, 2, 3);
    }

    [Fact]
    public void RelativeMovesWithLeadingBetweenShowsAreSummed()
    {
        var (content, before, after) = Redact("BT /F1 12 Tf 100 700 Td (J) Tj 10 0 TD (o) Tj 10 0 TD (h) Tj 10 0 TD (n) Tj ET", new PdfRect(108, 690, 125, 715));
        Assert.DoesNotContain("10 0 TD", content);
        Assert.Contains("30 0 TD", content);
        AssertStayedPut(before, after, 1, 2);
    }

    [Fact]
    public void PositionOfARemovedRunSetInAMatrixPerShowDoesNotStay()
    {
        string content = string.Concat(new[] { ("J", 100), ("o", 120), ("h", 140), ("n", 160) }.Select(g => $"q 1 0 0 1 {g.Item2} 700 cm BT /F1 12 Tf ({g.Item1}) Tj ET Q "));
        var (written, before, after) = Redact(content, new PdfRect(115, 690, 150, 715));
        Assert.DoesNotContain("120 700 cm", written);
        Assert.DoesNotContain("140 700 cm", written);
        Assert.Contains("100 700 cm", written);
        Assert.Contains("160 700 cm", written);
        AssertStayedPut(before, after, 1, 2);
    }
}
