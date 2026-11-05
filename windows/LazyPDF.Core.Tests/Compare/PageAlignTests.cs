using LazyPDF.Core;
using Xunit;
using static LazyPDF.Core.Tests.CompareKit;

namespace LazyPDF.Core.Tests;

public class PageAlignTests
{
    private static string[][] Pages(params string[] topics) => [.. topics.Select(t => Page(t))];

    private static string Shape(ComparisonResult r) =>
        string.Join(' ', r.Pages.Select(p => p.IsAdded ? $"+{p.NewIndex}" : p.IsRemoved ? $"-{p.OldIndex}" : p.Moved ? $"{p.OldIndex}>{p.NewIndex}" : $"{p.OldIndex}={p.NewIndex}"));

    [Fact]
    public void InsertedPageShiftsTheRest()
    {
        var result = Compare(Pages("a", "b", "c", "d"), Pages("a", "b", "x", "c", "d"));
        Assert.Equal("0=0 1=1 +2 2=3 3=4", Shape(result));
        var change = Assert.Single(result.Changes);
        Assert.Equal((ChangeKind.Added, ChangeArea.Page, -1, 2), (change.Kind, change.Area, change.OldPage, change.NewPage));
        Assert.Empty(change.OldQuads);
        Assert.Single(change.NewQuads);
        Assert.Equal(1, result.Summary.Pages);
    }

    [Fact]
    public void RemovedPageIsReportedOnTheOldSide()
    {
        var result = Compare(Pages("a", "b", "c", "d"), Pages("a", "c", "d"));
        Assert.Equal("0=0 -1 2=1 3=2", Shape(result));
        var change = Assert.Single(result.Changes);
        Assert.Equal((ChangeKind.Removed, 1, -1), (change.Kind, change.OldPage, change.NewPage));
        Assert.Single(change.OldQuads);
    }

    [Fact]
    public void InsertionAtTheStartAndEnd()
    {
        var result = Compare(Pages("a", "b"), Pages("x", "a", "b", "y"));
        Assert.Equal("+0 0=1 1=2 +3", Shape(result));
    }

    [Fact]
    public void MovedPageIsPairedByContentNotNumber()
    {
        var result = Compare(Pages("a", "b", "c", "d", "e"), Pages("a", "c", "d", "e", "b"));
        Assert.Equal(4, result.Pages.Count(p => !p.Moved && !p.IsAdded && !p.IsRemoved));
        var moved = Assert.Single(result.Pages, p => p.Moved);
        Assert.Equal((1, 4), (moved.OldIndex, moved.NewIndex));
        var change = Assert.Single(result.Changes);
        Assert.Equal((ChangeKind.Moved, ChangeArea.Page), (change.Kind, change.Area));
    }

    [Fact]
    public void ReorderedPagesComparedWithTheirPartnersHaveNoTextChanges()
    {
        var result = Compare(Pages("a", "b", "c"), Pages("c", "a", "b"));
        Assert.DoesNotContain(result.Changes, c => c.Area == ChangeArea.Text);
        Assert.Equal(1, result.Summary.Pages);
    }

    [Fact]
    public void EditedPageStaysPairedThroughAnInsertion()
    {
        string[][] before = [Page("a"), Page("b"), Page("c")];
        string[] edited = [.. Page("b")];
        edited[1] = "b line2 only a few words survive";
        string[][] after = [Page("a"), Page("new"), edited, Page("c")];
        var result = Compare(before, after);
        Assert.Equal("0=0 +1 1=2 2=3", Shape(result));
        Assert.Contains(result.Changes, c => c.Area == ChangeArea.Text && c.NewPage == 2);
    }

    [Fact]
    public void PageWithMostlyNewTextTakesItsPlaceInAGap()
    {
        string[][] before = [Page("a"), Page("b"), Page("c")];
        string[][] after = [Page("a"), Page("zzz"), Page("c")];
        var result = Compare(before, after);
        Assert.Equal("0=0 -1 +1 2=2", Shape(result));
    }

    [Fact]
    public void RepeatedBlankPagesKeepTheirOrder()
    {
        string[][] before = [Page("a"), [], [], Page("b"), []];
        string[][] after = [Page("a"), [], Page("b"), []];
        var result = Compare(before, after);
        Assert.Equal(1, result.Pages.Count(p => p.IsRemoved));
        Assert.Equal(5, result.Pages.Count(p => p.OldIndex >= 0));
        Assert.Equal(4, result.Pages.Count(p => p.NewIndex >= 0));
    }

    [Fact]
    public void EmptyDocumentsCompare()
    {
        string[][] some = [Page("a")];
        var result = Compare(some, [[]]);
        Assert.NotNull(result);
        Assert.Equal(1, result.NewPageCount);
    }

    [Fact]
    public void LargeDocumentAlignsQuicklyWithInsertions()
    {
        string[][] before = [.. Enumerable.Range(0, 300).Select(i => Page($"t{i}", 8))];
        var after = before.ToList();
        after.Insert(10, Page("fresh1", 8));
        after.Insert(200, Page("fresh2", 8));
        after.RemoveAt(100);
        var watch = System.Diagnostics.Stopwatch.StartNew();
        var result = Compare(before, [.. after]);
        watch.Stop();
        Assert.Equal(2, result.Pages.Count(p => p.IsAdded));
        Assert.Equal(1, result.Pages.Count(p => p.IsRemoved));
        Assert.Equal(3, result.Summary.Pages);
        Assert.True(watch.Elapsed < TimeSpan.FromSeconds(90), watch.Elapsed.ToString());
    }

    [Fact]
    public void PagesEditedThroughoutStillPairInAFileTooLongForTheFullTable()
    {
        string Words(int page, bool edited) => string.Join(' ', Enumerable.Range(1, 12).Select(w => $"p{page}w{w}" + (edited && w % 3 == 0 ? "x" : "")));
        string[][] before = [.. Enumerable.Range(0, 201).Select(i => new[] { Words(i, false) })];
        string[][] after = [["fresh cover page"], .. Enumerable.Range(0, 201).Select(i => new[] { Words(i, true) })];
        var result = Compare(before, after);
        Assert.Equal(201, result.Pages.Count(p => !p.IsAdded && !p.IsRemoved));
        Assert.Equal(1, result.Pages.Count(p => p.IsAdded));
        Assert.Equal(0, result.Pages.Count(p => p.IsRemoved));
    }

    private static string Edited(int page) => string.Join(' ', Enumerable.Range(1, 12).Select(w => $"p{page}w{w}" + (w % 3 == 0 ? "x" : "")));

    private static string Original(int page) => string.Join(' ', Enumerable.Range(1, 12).Select(w => $"p{page}w{w}"));

    [Fact]
    public void EditedPagesPairWhateverTheOffsetInAGapOfEqualLength()
    {
        // 120 pages in front, 120 gone at the end: the true offset is beyond any band of 40000 cells around the diagonal.
        string[][] before = [.. Enumerable.Range(0, 201).Select(i => new[] { Original(i) })];
        string[][] after = [.. Enumerable.Range(0, 120).Select(i => new[] { $"fresh cover {i} " + string.Join(' ', Enumerable.Range(0, 12).Select(w => $"f{i}w{w}")) }), .. Enumerable.Range(0, 81).Select(i => new[] { Edited(i) })];
        var result = Compare(before, after);
        var paired = result.Pages.Where(p => !p.IsAdded && !p.IsRemoved).ToList();
        Assert.Equal(81, paired.Count);
        Assert.All(paired, p => Assert.Equal(p.OldIndex + 120, p.NewIndex));
        Assert.Equal(120, result.Pages.Count(p => p.IsAdded));
        Assert.Equal(120, result.Pages.Count(p => p.IsRemoved));
    }

    [Fact]
    public void EditedPagesPairInAGapWhoseSidesDifferByMoreThanTheTableAllows()
    {
        string[][] before = [.. Enumerable.Range(0, 150).Select(i => new[] { Original(i) })];
        string[][] after = [.. Enumerable.Range(0, 140).Select(i => new[] { $"fresh cover {i} " + string.Join(' ', Enumerable.Range(0, 12).Select(w => $"f{i}w{w}")) }), .. Enumerable.Range(0, 150).Select(i => new[] { Edited(i) })];
        var result = Compare(before, after);
        var paired = result.Pages.Where(p => !p.IsAdded && !p.IsRemoved).ToList();
        Assert.Equal(150, paired.Count);
        Assert.All(paired, p => Assert.Equal(p.OldIndex + 140, p.NewIndex));
    }

    [Fact]
    public void ScansWithNothingAlikePairByPositionInAGapTooLargeForTheFullTable()
    {
        string[][] before = [.. Enumerable.Range(0, 201).Select(i => new[] { $"alpha{i} beta{i}" })];
        string[][] after = [.. Enumerable.Range(0, 201).Select(i => new[] { $"gamma{i} delta{i}" })];
        var result = Compare(before, after);
        Assert.Equal(201, result.Pages.Count(p => !p.IsAdded && !p.IsRemoved && p.OldIndex == p.NewIndex));
    }

    [Fact]
    public void CancellationStopsTheRun()
    {
        using var a = Doc(Pages("a", "b"));
        using var cancelled = new CancellationTokenSource();
        cancelled.Cancel();
        Assert.Throws<OperationCanceledException>(() => PdfComparer.Compare(a, a, null, cancelled.Token));
    }
}
