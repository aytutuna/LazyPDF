using LazyPDF.App.Viewer;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// The selected text as carets, across pages.
public sealed class ViewerSelectionTests
{
    private static int Chars(int page) => 10 * (page + 1);

    [Fact]
    public void CaretsAreOrderedByPageThenIndex()
    {
        Assert.True(new Caret(0, 50) < new Caret(1, 0));
        Assert.True(new Caret(2, 5) > new Caret(2, 4));
        Assert.Equal(0, new Caret(1, 1).CompareTo(new Caret(1, 1)));
    }

    [Fact]
    public void ANewSelectionIsEmpty()
    {
        var selection = new ViewerSelection();

        Assert.True(selection.IsEmpty);
        Assert.Empty(selection.Ranges(Chars));
    }

    [Fact]
    public void ASelectionOnOnePageIsTheStretchBetweenTheCarets()
    {
        var selection = new ViewerSelection();
        selection.Set(new Caret(1, 12), new Caret(1, 3));

        var ranges = selection.Ranges(Chars).ToList();

        Assert.Equal([(1, new TextRange(3, 12))], ranges);
        Assert.Equal(new Caret(1, 3), selection.Start);
        Assert.Equal(new Caret(1, 12), selection.End);
    }

    [Fact]
    public void ASelectionAcrossPagesTakesTheEndOfTheFirstAllOfTheMiddleAndTheStartOfTheLast()
    {
        var selection = new ViewerSelection();
        selection.Set(new Caret(0, 4), new Caret(3, 7));

        var ranges = selection.Ranges(Chars).ToList();

        Assert.Equal(
            [(0, new TextRange(4, 10)), (1, new TextRange(0, 20)), (2, new TextRange(0, 30)), (3, new TextRange(0, 7))],
            ranges);
    }

    [Fact]
    public void AnIndexPastTheTextMeansItsEnd()
    {
        var selection = new ViewerSelection();
        selection.SelectAll(3);

        var ranges = selection.Ranges(Chars).ToList();

        Assert.Equal([(0, new TextRange(0, 10)), (1, new TextRange(0, 20)), (2, new TextRange(0, 30))], ranges);
    }

    [Fact]
    public void APageWithNoTextAddsNothing()
    {
        var selection = new ViewerSelection();
        selection.Set(new Caret(0, 0), new Caret(2, 5));

        var ranges = selection.Ranges(page => page == 1 ? 0 : 10).ToList();

        Assert.Equal([0, 2], ranges.Select(r => r.Page));
    }

    [Fact]
    public void OnGivesTheStretchOfOnePageOrNothing()
    {
        var selection = new ViewerSelection();
        selection.Set(new Caret(1, 5), new Caret(2, 8));

        Assert.Equal(new TextRange(5, 20), selection.On(1, 20));
        Assert.Equal(new TextRange(0, 8), selection.On(2, 30));
        Assert.Null(selection.On(0, 10));
        Assert.Null(selection.On(3, 10));
        Assert.True(selection.Covers(2));
        Assert.False(selection.Covers(0));
    }

    [Fact]
    public void ExtendingKeepsTheAnchorAndMovesTheFocus()
    {
        var selection = new ViewerSelection();
        selection.Set(new Caret(0, 5), new Caret(0, 5));

        selection.Extend(new Caret(0, 2));

        Assert.Equal(new Caret(0, 5), selection.Anchor);
        Assert.Equal(new Caret(0, 2), selection.Focus);
        Assert.Equal(new Caret(0, 2), selection.Start);
    }

    [Fact]
    public void ChangesAreAnnouncedOnceAndOnlyWhenTheyChangeSomething()
    {
        var selection = new ViewerSelection();
        int raised = 0;
        selection.Changed += (_, _) => raised++;

        selection.Set(new Caret(0, 1), new Caret(0, 4));
        selection.Set(new Caret(0, 1), new Caret(0, 4));
        selection.Clear();
        selection.Clear();

        Assert.Equal(2, raised);
        Assert.True(selection.IsEmpty);
    }
}
