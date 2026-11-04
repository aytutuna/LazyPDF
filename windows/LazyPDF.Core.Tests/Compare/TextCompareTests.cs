using LazyPDF.Core;
using Xunit;
using static LazyPDF.Core.Tests.CompareKit;

namespace LazyPDF.Core.Tests;

public class TextCompareTests
{
    private static readonly string[][] Base = [Page("one"), Page("two"), Page("three")];

    private static string[][] With(int page, int line, string text)
    {
        var copy = Base.Select(p => (string[])p.Clone()).ToArray();
        copy[page][line] = text;
        return copy;
    }

    [Fact]
    public void IdenticalFilesHaveNoChanges()
    {
        var result = Compare(Base, Base);
        Assert.True(result.IsIdentical);
        Assert.Equal(0, result.Summary.Total);
        Assert.All(result.Pages, p => Assert.Equal(1.0, p.Similarity));
        Assert.Equal(3, result.Pages.Count);
    }

    [Fact]
    public void OneChangedWordIsOneChangeWithQuadsOnBothSides()
    {
        var after = With(1, 2, "two line3 two3w1 two3w2 CHANGED two3w4 two3w5 two3w6 two3w7 two3w8");
        var change = Assert.Single(Compare(Base, after).Changes);
        Assert.Equal(ChangeKind.Changed, change.Kind);
        Assert.Equal(ChangeArea.Text, change.Area);
        Assert.Equal((1, 1), (change.OldPage, change.NewPage));
        Assert.Equal("two3w3", change.OldText);
        Assert.Equal("CHANGED", change.NewText);
        var old = Assert.Single(change.OldQuads);
        var now = Assert.Single(change.NewQuads);
        // Line 3 of a page has its baseline at y = 700.
        Assert.InRange(old.Bounds.Bottom, 695, 705);
        Assert.InRange(now.Bounds.Bottom, 695, 705);
        Assert.True(now.Bounds.Width > old.Bounds.Width);
    }

    [Fact]
    public void AddedWordsHaveAnAnchorOnTheOldSide()
    {
        var after = With(0, 0, "one line1 one1w1 one1w2 NEW WORDS one1w3 one1w4 one1w5 one1w6 one1w7 one1w8");
        var result = Compare(Base, after);
        var change = Assert.Single(result.Changes);
        Assert.Equal(ChangeKind.Added, change.Kind);
        Assert.Equal("NEW WORDS", change.NewText);
        Assert.Equal("", change.OldText);
        var anchor = Assert.Single(change.OldQuads);
        Assert.Equal(0, anchor.Bounds.Width, 6);
        Assert.True(anchor.Bounds.Height > 5);
        Assert.Equal(2, result.Summary.WordsAdded);
    }

    [Fact]
    public void RemovedWordsHaveAnAnchorOnTheNewSide()
    {
        var after = With(2, 4, "three line5 three5w1 three5w2 three5w7 three5w8");
        var change = Assert.Single(Compare(Base, after).Changes);
        Assert.Equal(ChangeKind.Removed, change.Kind);
        Assert.Equal("three5w3 three5w4 three5w5 three5w6", change.OldText);
        Assert.Equal(0, Assert.Single(change.NewQuads).Bounds.Width, 6);
        Assert.Single(change.OldQuads);
    }

    [Fact]
    public void SeparateEditsAreSeparateChanges()
    {
        var after = With(0, 0, "one line1 X one1w2 one1w3 one1w4 one1w5 one1w6 one1w7 Y");
        var result = Compare(Base, after);
        Assert.Equal(2, result.Changes.Count);
        Assert.Equal(["X", "Y"], result.Changes.Select(c => c.NewText));
    }

    [Fact]
    public void MovedParagraphIsOneMovedChange()
    {
        string[] lines = [.. Enumerable.Range(1, 8).Select(i => $"paragraph{i} " + string.Join(' ', Enumerable.Range(1, 9).Select(k => $"p{i}x{k}")))];
        string[] moved = [lines[0], lines[1], lines[5], lines[2], lines[3], lines[4], lines[6], lines[7]];
        var result = Compare([lines], [moved]);
        var change = Assert.Single(result.Changes);
        Assert.Equal(ChangeKind.Moved, change.Kind);
        Assert.Equal(lines[5], change.OldText);
        Assert.Equal(lines[5], change.NewText);
        Assert.InRange(Assert.Single(change.OldQuads).Bounds.Bottom, 635, 645);
        Assert.InRange(Assert.Single(change.NewQuads).Bounds.Bottom, 695, 705);
        Assert.Equal(1, result.Summary.Moved);
        Assert.Equal(0, result.Summary.WordsAdded);
    }

    [Fact]
    public void ParagraphMovedToAnotherPageIsMoved()
    {
        string[] first = Page("first", 7), second = Page("second", 7);
        string[][] before = [first, second];
        string[][] after = [[.. first[..3], .. first[4..]], [.. second, first[3]]];
        var change = Assert.Single(Compare(before, after).Changes);
        Assert.Equal(ChangeKind.Moved, change.Kind);
        Assert.Equal((0, 1), (change.OldPage, change.NewPage));
    }

    [Fact]
    public void ChangedBlockIsNotAMove()
    {
        string[] lines = Page("block", 6);
        string[] edited = [.. lines];
        edited[2] = "block line3 something else entirely different here now";
        var result = Compare([lines], [edited]);
        Assert.Equal(ChangeKind.Changed, Assert.Single(result.Changes).Kind);
    }

    [Fact]
    public void CaseDiffersUnlessIgnored()
    {
        var after = With(0, 1, "one line2 ONE2W1 one2w2 one2w3 one2w4 one2w5 one2w6 one2w7 one2w8");
        var change = Assert.Single(Compare(Base, after).Changes);
        Assert.Equal("one2w1", change.OldText);
        Assert.True(Compare(Base, after, new CompareOptions(IgnoreCase: true)).IsIdentical);
    }

    [Fact]
    public void SplitAndJoinedWordsAreEqualWhenWhiteSpaceIsIgnored()
    {
        string[][] before = [["the data base of the system is large enough"]];
        string[][] after = [["the database of the system is large enough"]];
        Assert.Single(Compare(before, after).Changes);
        Assert.True(Compare(before, after, new CompareOptions(IgnoreWhiteSpace: true)).IsIdentical);
    }

    [Fact]
    public void WhiteSpaceOptionStillSeesRealChanges()
    {
        string[][] before = [["the data base of the system is large enough"]];
        string[][] after = [["the database of the system is small enough"]];
        var change = Assert.Single(Compare(before, after, new CompareOptions(IgnoreWhiteSpace: true)).Changes);
        Assert.Equal("small", change.NewText);
    }

    [Fact]
    public void HeaderAndFooterZonesCanBeIgnored()
    {
        // The header sits at y = 770 and the footer at y = 20 on a 792 point page.
        static PdfDocument Make(string header, string footer)
        {
            var pdf = new TestPdf();
            pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
            pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 612 792]>>");
            pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Resources <</Font <</F1 5 0 R>>>>>>");
            pdf.Stream(4, "", $"BT /F1 12 Tf 72 770 Td ({header}) Tj ET BT /F1 12 Tf 72 400 Td (body text of the page) Tj ET BT /F1 12 Tf 72 20 Td ({footer}) Tj ET");
            pdf.Obj(5, ContentTestPdf.Helvetica);
            return Open(pdf.Finish());
        }
        using var a = Make("Report May", "Page 1");
        using var b = Make("Report June", "Page 2");
        Assert.Equal(2, Compare(a, b).Changes.Count);
        Assert.True(Compare(a, b, new CompareOptions(IgnoreHeaderFooter: true)).IsIdentical);
    }

    [Fact]
    public void BodyTextIsKeptWhenHeaderAndFooterAreIgnored()
    {
        var after = With(0, 2, "one line3 one3w1 one3w2 one3w3 BODY one3w5 one3w6 one3w7 one3w8");
        var result = Compare(Base, after, new CompareOptions(IgnoreHeaderFooter: true));
        Assert.Equal("BODY", Assert.Single(result.Changes).NewText);
    }

    [Fact]
    public void HalfTheWordsDifferingGivesTheirCount()
    {
        string[] a = [.. Page("keep", 15), .. Enumerable.Range(0, 15).Select(i => string.Join(' ', Enumerable.Range(0, 9).Select(k => $"a{i}x{k}")))];
        string[] b = [.. Page("keep", 15), .. Enumerable.Range(0, 15).Select(i => string.Join(' ', Enumerable.Range(0, 9).Select(k => $"b{i}x{k}")))];
        var result = Compare([a], [b]);
        Assert.Equal(135, result.Summary.WordsAdded);
        Assert.Equal(135, result.Summary.WordsRemoved);
        Assert.Equal(ChangeKind.Changed, Assert.Single(result.Changes).Kind);
    }

    [Fact]
    public void PagesWithNothingInCommonAreRemovedAndAdded()
    {
        var result = Compare([Page("aaa")], [Page("bbb")]);
        Assert.Equal([ChangeKind.Added, ChangeKind.Removed], result.Changes.Select(c => c.Kind).OrderBy(k => k));
        Assert.All(result.Changes, c => Assert.Equal(ChangeArea.Page, c.Area));
    }
}
