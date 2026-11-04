using LazyPDF.Core;
using Xunit;
using static LazyPDF.Core.Tests.CompareKit;
using PigDocument = UglyToad.PdfPig.PdfDocument;

namespace LazyPDF.Core.Tests;

public class ComparisonReportTests
{
    private static readonly DateTimeOffset Date = new(2026, 3, 4, 5, 6, 7, TimeSpan.Zero);

    private static string[][] Pages(params string[] topics) => [.. topics.Select(t => Page(t))];

    private static (byte[] Report, PdfDocument Opened, ComparisonResult Result) Report(string[][] before, string[][] after, IFontSource? fonts = null, string oldName = "old.pdf", string newName = "new.pdf")
    {
        using var a = Doc(before);
        using var b = Doc(after);
        var result = PdfComparer.Compare(a, b);
        var bytes = ComparisonReport.Write(b, result, oldName, newName, fonts, Date);
        return (bytes, PdfDocument.Open(bytes), result);
    }

    private static string Summary(byte[] report, int page = 1)
    {
        using var pig = PigDocument.Open(report);
        return pig.GetPage(page).Text;
    }

    private static IReadOnlyList<PdfAnnotation> Marks(PdfDocument document, int page) =>
        [.. PdfAnnotations.Read(document, document.Pages[page]).Where(a => a.Type == AnnotationType.Highlight)];

    [Fact]
    public void ReportHasSummaryInFrontAndHighlightsOnTheNewPages()
    {
        string[][] before = [Page("a"), Page("b")];
        string[][] after = [Page("a"), [.. Page("b")]];
        after[1][2] = "b line3 b3w1 b3w2 CHANGED b3w4 b3w5 b3w6 b3w7 b3w8";
        var (bytes, report, result) = Report(before, after);
        using var _ = report;
        Assert.Equal(3, report.Pages.Count);
        Assert.Empty(Marks(report, 0));
        Assert.Empty(Marks(report, 1));
        var mark = Assert.Single(Marks(report, 2));
        Assert.Equal("Was: b3w3", mark.Contents);
        Assert.Equal([1, 0.85, 0.35], mark.Color);
        Assert.Equal("Lazy PDF", mark.Title);
        Assert.Equal(Date, mark.Created);
        var box = mark.Quads.Single().Bounds;
        Assert.InRange(box.Bottom, 690, 705);
        Assert.Equal(1, result.Summary.Changed);
        Assert.Equal(3, PigDocument.Open(bytes).NumberOfPages);
    }

    [Fact]
    public void AddedRemovedAndChangedHaveTheirOwnColours()
    {
        string[] before = Page("x", 6), after = [.. before];
        after[0] = "x line1 ADDED x1w1 x1w2 x1w3 x1w4 x1w5 x1w6 x1w7 x1w8";
        after[2] = "x line3 x3w1 x3w2 x3w3 x3w4 x3w5 x3w6 x3w7";
        after[4] = "x line5 x5w1 x5w2 x5w3 REPLACED x5w5 x5w6 x5w7 x5w8";
        var (_, report, result) = Report([before], [after]);
        using var _ = report;
        Assert.Equal((1, 1, 1), (result.Summary.Added, result.Summary.Removed, result.Summary.Changed));
        var marks = Marks(report, 1);
        Assert.Equal(3, marks.Count);
        Assert.Equal([0.55, 0.85, 0.55], marks.Single(m => m.Subject == "Added").Color);
        Assert.Equal([1, 0.55, 0.55], marks.Single(m => m.Subject == "Removed").Color);
        Assert.Equal([1, 0.85, 0.35], marks.Single(m => m.Subject == "Changed").Color);
        Assert.Equal("Was: x3w8", marks.Single(m => m.Subject == "Removed").Contents);
        // The mark of a removal is a sliver at the place where the text was.
        Assert.InRange(marks.Single(m => m.Subject == "Removed").Rect.Width, 3, 12);
    }

    [Fact]
    public void MovedTextIsMarkedAsChangedWithItsOrigin()
    {
        string[] lines = Page("m", 8);
        string[] moved = [lines[0], lines[1], lines[5], lines[2], lines[3], lines[4], lines[6], lines[7]];
        var (_, report, _) = Report([lines], [moved]);
        using var _ = report;
        var mark = Assert.Single(Marks(report, 1));
        Assert.Equal("Moved", mark.Subject);
        Assert.Equal(CompareText.MovedFrom(0), mark.Contents);
    }

    [Fact]
    public void InsertedPageGetsANoteAndRemovedPageIsListedInTheSummary()
    {
        var (bytes, report, _) = Report(Pages("a", "b", "c"), Pages("a", "x", "c"));
        using var _ = report;
        var summary = Summary(bytes);
        Assert.Contains("Page removed: 2", summary);
        var notes = PdfAnnotations.Read(report, report.Pages[2]).Where(a => a.Type == AnnotationType.Text).ToList();
        Assert.Equal("Page added", Assert.Single(notes).Contents);
    }

    [Fact]
    public void SummaryNamesTheFilesAndCounts()
    {
        string[] after = Page("n", 6);
        after[1] = "n line2 n2w1 NEW n2w3 n2w4 n2w5 n2w6 n2w7 n2w8";
        var (bytes, report, _) = Report([Page("n", 6)], [after], oldName: "first.pdf", newName: "second.pdf");
        using var _ = report;
        string text = Summary(bytes);
        Assert.Contains("Comparison", text);
        Assert.Contains("first.pdf", text);
        Assert.Contains("second.pdf", text);
        Assert.Contains("1 difference", text);
        Assert.Contains("Changed: 1", text);
    }

    [Fact]
    public void IdenticalFilesGiveASummaryWithoutMarks()
    {
        var (bytes, report, result) = Report(Pages("a", "b"), Pages("a", "b"));
        using var _ = report;
        Assert.True(result.IsIdentical);
        Assert.Equal(3, report.Pages.Count);
        Assert.Contains("No differences found.", Summary(bytes));
        Assert.All(Enumerable.Range(1, 2), p => Assert.Empty(Marks(report, p)));
    }

    [Fact]
    public void ReportReopensInPdfPigWithEveryPage()
    {
        var (bytes, report, _) = Report(Pages("a", "b", "c"), Pages("c", "a", "q", "b"));
        using var _ = report;
        using var pig = PigDocument.Open(bytes);
        Assert.Equal(report.Pages.Count, pig.NumberOfPages);
        Assert.Contains("a line1", pig.GetPage(3).Text);
    }

    [Fact]
    public void TheDocumentPassedInIsNotChanged()
    {
        using var before = Doc(Pages("a"));
        byte[] edited = TestPdf.Latin(TestPdf.Text(Bytes([.. Pages("a").Select(p => p.Select(L).ToArray())])).Replace("a line1", "z line1"));
        using var changed = Open(edited);
        var result = PdfComparer.Compare(before, changed);
        Assert.False(result.IsIdentical);
        ComparisonReport.Write(changed, result, "a", "b");
        Assert.Single(changed.Pages);
        Assert.Empty(PdfAnnotations.Read(changed, changed.Pages[0]));
    }

    [Fact]
    public void NamesOutsideLatin1PrintAsQuestionMarksWithoutAFontAndInFullWithOne()
    {
        string name = "Rapor-şğı.pdf";
        var (plain, a, _) = Report(Pages("a"), Pages("a"), null, name, "yeni.pdf");
        a.Dispose();
        Assert.Contains("Rapor-???.pdf", Summary(plain));
        var (embedded, b, _) = Report(Pages("a"), Pages("a"), new CompareArial(), name, "yeni.pdf");
        b.Dispose();
        Assert.Contains(name, Summary(embedded));
    }

    [Fact]
    public void LongSummariesRunOverSeveralPages()
    {
        using var a = Doc(Pages("a"));
        (DocumentMetadata.Read(a) with { Custom = Enumerable.Range(0, 120).ToDictionary(i => $"Key{i}", i => $"value {i}") }).Write(a);
        using var before = Open(a.SaveRewrite());
        using var after = Doc(Pages("a"));
        var result = PdfComparer.Compare(before, after);
        Assert.Equal(120, result.Summary.Document);
        using var report = PdfDocument.Open(ComparisonReport.Write(after, result, "a", "b"));
        Assert.True(report.Pages.Count >= 3, report.Pages.Count.ToString());
    }

    [Fact]
    public void TextOutputListsChangesByPage()
    {
        string[][] before = [Page("a"), Page("b")];
        string[][] after = [Page("a"), [.. Page("b")]];
        after[1][1] = "b line2 b2w1 b2w2 b2w3 CHANGED b2w5 b2w6 b2w7 b2w8";
        using var x = Doc(before);
        using var y = Doc(after);
        string text = ComparisonReport.ToText(PdfComparer.Compare(x, y), "old.pdf", "new.pdf");
        Assert.StartsWith("Comparison\nold.pdf / new.pdf\n", text);
        Assert.Contains("1 difference: Added 0, Removed 0, Changed 1, Moved 0", text);
        Assert.Contains("Pages 2\n  Changed text: b2w4 -> CHANGED", text);
    }

    [Fact]
    public void TextOutputForIdenticalFilesSaysSo()
    {
        using var x = Doc(Pages("a"));
        Assert.EndsWith("No differences found.\n", ComparisonReport.ToText(PdfComparer.Compare(x, x), "a", "b"));
    }

    [Fact]
    public void TextOutputIncludesDocumentDifferences()
    {
        using var a = Doc(Pages("a"));
        (DocumentMetadata.Read(a) with { Title = "One" }).Write(a);
        using var x = Open(a.SaveRewrite());
        using var y = Doc(Pages("a"));
        string text = ComparisonReport.ToText(PdfComparer.Compare(x, y), "a", "b");
        Assert.Contains("Document\n  Removed document (Title): One", text);
    }

    [Fact]
    public void RemovalFromAPageWithAnotherBoxIsMarkedAtTheSamePlaceOfTheDisplayedPage()
    {
        using var a = Open(Bytes([[new("alpha beta gamma")]]));
        using var b = Open(Bytes([[]], pageKeys: "/MediaBox [100 100 406 496]"));
        var result = PdfComparer.Compare(a, b);
        using var report = PdfDocument.Open(ComparisonReport.Write(a, b, result, "old.pdf", "new.pdf", null, Date));
        // The words stood at x 72 and y about 740 of 612 by 792; the new page is half that size with its origin at 100.
        var box = Assert.Single(Marks(report, 1)).Quads.Single().Bounds;
        Assert.InRange(box.Left, 134, 138);
        Assert.InRange(box.Bottom, 462, 476);
    }
}
