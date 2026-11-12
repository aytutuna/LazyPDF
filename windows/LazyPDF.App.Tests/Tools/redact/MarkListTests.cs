using System.Windows;
using LazyPDF.App.Tools.Redact;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// The marks of the Redact tool before anything is removed: the list, and the move between page space and the file's.
public sealed class MarkListTests
{
    private static MarkItem Item(int page, double left, double bottom, string label = "x") =>
        new(RedactionMark.FromRect(page, new PdfRect(left, bottom, left + 40, bottom + 10)), label);

    [Fact]
    public void TwoHitsInOneCommentAreTwoMarks()
    {
        var list = new MarkList();
        var rect = RedactionMark.FromRect(0, new PdfRect(400, 100, 420, 120));
        MarkItem Hit(int start) => new(rect, "x", Value: new RedactionValueMatch(0, 2, RedactionValueSource.Comment, start, 3, "abc", RedactionKind.Word));

        Assert.Equal(2, list.Add([Hit(0), Hit(10)]));
        Assert.Equal(0, list.Add([Hit(10)]));
        Assert.Equal(1, list.Add([new MarkItem(rect, "Box", IsBox: true)]));
    }

    [Fact]
    public void RemovingValuesKeepsTheOtherMarks()
    {
        var list = new MarkList();
        var rect = RedactionMark.FromRect(0, new PdfRect(400, 100, 420, 120));
        var hit = new MarkItem(rect, "x", Value: new RedactionValueMatch(0, 2, RedactionValueSource.Field, 5, 3, "abc", RedactionKind.Word));
        list.Add([hit, new MarkItem(rect, "Box", IsBox: true)]);
        int changes = 0;
        list.Changed += (_, _) => changes++;

        Assert.True(list.RemoveValues());
        Assert.Equal(["Box"], list.Items.Select(m => m.Label));
        Assert.False(list.RemoveValues());
        Assert.Equal(1, changes);
    }

    [Fact]
    public void MarksComeInReadingOrder()
    {
        var list = new MarkList();

        list.Add([Item(1, 10, 100, "late"), Item(0, 10, 100, "low"), Item(0, 10, 500, "high"), Item(0, 80, 500, "right")]);

        Assert.Equal(["high", "right", "low", "late"], list.Items.Select(m => m.Label));
    }

    [Fact]
    public void AMarkOnTheSamePlaceIsNotAddedTwice()
    {
        var list = new MarkList();
        int changes = 0;
        list.Changed += (_, _) => changes++;

        Assert.Equal(1, list.Add([Item(0, 10, 100)]));
        Assert.Equal(0, list.Add([Item(0, 10.2, 100.1)]));
        Assert.Equal(1, list.Add([Item(1, 10, 100), Item(1, 10, 100)]));

        Assert.Equal(2, list.Items.Count);
        Assert.Equal(2, changes);
    }

    [Fact]
    public void RemovingAndClearingTellTheListeners()
    {
        var list = new MarkList();
        var first = Item(0, 10, 100);
        list.Add([first, Item(0, 10, 200)]);
        int changes = 0;
        list.Changed += (_, _) => changes++;

        list.Remove(first);
        list.Remove(first);
        list.Clear();
        list.Clear();

        Assert.Empty(list.Items);
        Assert.Equal(2, changes);
    }

    [Theory]
    [InlineData(0)]
    [InlineData(90)]
    [InlineData(180)]
    [InlineData(270)]
    public void ABoxDraggedOnAPageComesBackWhereItWasDrawn(int rotate)
    {
        var geometry = new PageGeometry(new PdfRect(0, 0, 200, 300), rotate);
        var from = new Point(10, 20);
        var to = new Point(60, 45);

        var mark = MarkShapes.Box(2, geometry, to, from);
        var outline = MarkShapes.Outline(geometry, mark.Quads[0]);

        Assert.Equal(2, mark.Page);
        Assert.Equal(4, outline.Count);
        Assert.Equal(10, outline.Min(p => p.X), 6);
        Assert.Equal(60, outline.Max(p => p.X), 6);
        Assert.Equal(20, outline.Min(p => p.Y), 6);
        Assert.Equal(45, outline.Max(p => p.Y), 6);
    }

    [Theory]
    [InlineData(0)]
    [InlineData(90)]
    [InlineData(180)]
    [InlineData(270)]
    public void ABoxReadsLeftToRightAsItIsShownOnATurnedPage(int rotate)
    {
        var geometry = new PageGeometry(new PdfRect(0, 0, 200, 300), rotate);

        var quad = MarkShapes.Box(0, geometry, new Point(10, 20), new Point(200, 40)).Quads[0];

        var (x0, y0) = geometry.ToDisplay(quad.X0, quad.Y0);
        var (x1, y1) = geometry.ToDisplay(quad.X1, quad.Y1);
        var (x3, y3) = geometry.ToDisplay(quad.X3, quad.Y3);
        Assert.Equal(190, x1 - x0, 6);
        Assert.Equal(0, y1 - y0, 6);
        Assert.Equal(0, x3 - x0, 6);
        Assert.Equal(-20, y3 - y0, 6);
    }

    [Fact]
    public void MarkingThousandsOfPlacesAtOnceIsQuick()
    {
        var list = new MarkList();
        var items = Enumerable.Range(0, 40_000).Select(i => Item(i % 40, i / 40 % 20 * 45, i / 800 * 12)).ToList();
        var clock = System.Diagnostics.Stopwatch.StartNew();

        int added = list.Add(items);

        Assert.Equal(40_000, added);
        Assert.True(clock.Elapsed < TimeSpan.FromSeconds(5));
    }

    [Fact]
    public void AMarkTakenOutCanBeAddedAgain()
    {
        var list = new MarkList();
        var item = Item(0, 10, 100);
        list.Add([item]);
        list.Remove(item);

        Assert.Equal(1, list.Add([item]));
        list.Clear();
        Assert.Equal(1, list.Add([item]));
    }

    [Fact]
    public void ABoxIsInUserSpaceWithTheOriginAtTheBottom()
    {
        var geometry = new PageGeometry(new PdfRect(0, 0, 200, 300), 0);

        var bounds = MarkShapes.Box(0, geometry, new Point(10, 20), new Point(60, 45)).Quads[0].Bounds;

        Assert.Equal((10, 255, 60, 280), (bounds.Left, bounds.Bottom, bounds.Right, bounds.Top));
    }

    [Theory]
    [InlineData("", new int[0])]
    [InlineData("1", new[] { 0 })]
    [InlineData("2-4, 7", new[] { 6, 1, 2, 3 })]
    [InlineData("1, 3, 5", new[] { 0, 2, 4 })]
    public void PagesAreWrittenAsRanges(string expected, int[] pages) =>
        Assert.Equal(expected, RedactSummary.PageRanges(pages));

    [Fact]
    public void UndoPutsBackARemovedMark()
    {
        var list = new MarkList();
        var a = Item(0, 10, 100, "a");
        var b = Item(0, 10, 200, "b");
        list.Add([a, b]);

        list.Remove(a);
        Assert.True(list.CanUndo);
        list.Undo();

        Assert.Equal(["b", "a"], list.Items.Select(m => m.Label));
        Assert.Equal(0, list.Add([Item(0, 10, 100)]));
    }

    [Fact]
    public void ForgettingAfterAClearLeavesNothingToUndo()
    {
        var list = new MarkList();
        list.Add([Item(4, 10, 100)]);
        list.Clear();

        list.Forget();

        Assert.False(list.CanUndo);
        Assert.Empty(list.Items);
    }

    [Fact]
    public void UndoBringsBackAClearedList()
    {
        var list = new MarkList();
        list.Add([Item(0, 10, 100), Item(0, 10, 200)]);
        list.Clear();

        list.Undo();

        Assert.Equal(2, list.Items.Count);
    }

    [Fact]
    public void UndoTakesBackAnAddOfThree()
    {
        var list = new MarkList();
        list.Add([Item(0, 10, 100)]);
        list.Add([Item(1, 10, 100), Item(1, 10, 200), Item(1, 10, 300)]);

        list.Undo();

        Assert.Single(list.Items);
        Assert.Equal(1, list.Add([Item(1, 10, 100)]));
    }

    [Fact]
    public void OnlyTwentyStepsAreKept()
    {
        var list = new MarkList();
        for (int i = 0; i < 21; i++) list.Add([Item(0, 10, 100 + i * 20)]);

        int undone = 0;
        while (list.CanUndo)
        {
            list.Undo();
            undone++;
        }

        Assert.Equal(20, undone);
        Assert.Single(list.Items);
    }

    [Fact]
    public void ForgetEmptiesTheHistory()
    {
        var list = new MarkList();
        list.Add([Item(0, 10, 100)]);

        list.Forget();

        Assert.False(list.CanUndo);
        Assert.Single(list.Items);
    }

    [Fact]
    public void UndoRaisesChangedOnce()
    {
        var list = new MarkList();
        list.Add([Item(0, 10, 100)]);
        int changes = 0;
        list.Changed += (_, _) => changes++;

        list.Undo();

        Assert.Equal(1, changes);
    }

    [Fact]
    public void EveryChangeGivesANewItemsReference()
    {
        var list = new MarkList();
        var seen = new List<object> { list.Items };
        var a = Item(0, 10, 100);

        list.Add([a]);
        seen.Add(list.Items);
        list.Add([Item(0, 10, 200)]);
        seen.Add(list.Items);
        list.Remove(a);
        seen.Add(list.Items);
        list.Clear();
        seen.Add(list.Items);
        list.Undo();
        seen.Add(list.Items);

        Assert.Equal(seen.Count, seen.Distinct(ReferenceEqualityComparer.Instance).Count());
        Assert.Single(((IReadOnlyList<MarkItem>)seen[3]));
    }

    [Fact]
    public void ReplacingAMarkKeepsTheCountSortsAndUndoesInOneStep()
    {
        var list = new MarkList();
        var low = Item(0, 10, 100, "low");
        var high = Item(0, 10, 500, "high");
        list.Add([low, high]);
        int changes = 0;
        list.Changed += (_, _) => changes++;

        list.Replace(high, Item(0, 10, 20, "moved"));

        Assert.Equal(["low", "moved"], list.Items.Select(m => m.Label));
        Assert.Equal(1, changes);
        Assert.Equal(0, list.Add([Item(0, 10, 20.1)]));

        list.Undo();

        Assert.Equal(["high", "low"], list.Items.Select(m => m.Label));
        Assert.Equal(0, list.Add([Item(0, 10, 500)]));
        Assert.Equal(1, list.Add([Item(0, 10, 20)]));
    }
}
