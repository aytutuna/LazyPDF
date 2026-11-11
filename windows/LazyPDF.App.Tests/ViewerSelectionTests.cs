using System.Reflection;
using System.Windows;
using System.Windows.Input;
using LazyPDF.App.Documents;
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

// Caret browsing: F7 puts a caret on the text and the arrow keys move it, with Shift they select.
[Collection("Application")]
public sealed class CaretBrowsingTests
{
    private static async Task<(PageViewer Viewer, ViewerSelection Selection, DocumentTab Tab)> OpenAsync(string text)
    {
        var tab = new DocumentTab(PdfEditSession.Open(Pdfs.Text(1, text)), new FakeRenderer(), null, "a.pdf");
        var viewer = new PageViewer(null);
        viewer.Show(tab);
        viewer.Measure(new Size(800, 600));
        viewer.Arrange(new Rect(0, 0, 800, 600));
        viewer.UpdateLayout();
        await viewer.ToggleCaret();
        var selection = (ViewerSelection)typeof(PageViewer).GetField("_selection", BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(viewer)!;
        return (viewer, selection, tab);
    }

    [Fact]
    public Task TheArrowKeysMoveTheCaretAndLeaveNothingSelected() => Sta.Run(async () =>
    {
        var (viewer, selection, tab) = await OpenAsync("Hello from the tests.");
        using var _ = tab;

        for (int i = 0; i < 3; i++) Assert.True(viewer.MoveCaret(Key.Right, false, false));

        Assert.Equal(3, selection.Focus.Index);
        Assert.True(selection.IsEmpty);
    });

    [Fact]
    public Task ShiftTakesTheCharactersItPassesOver() => Sta.Run(async () =>
    {
        var (viewer, selection, tab) = await OpenAsync("Hello from the tests.");
        using var _ = tab;

        for (int i = 0; i < 3; i++) viewer.MoveCaret(Key.Right, false, true);

        Assert.Equal(new TextRange(0, 3), selection.On(0, 100));
    });

    [Fact]
    public Task ControlRightLandsOnTheStartOfTheNextWord() => Sta.Run(async () =>
    {
        var (viewer, selection, tab) = await OpenAsync("Hello from the tests.");
        using var _ = tab;

        viewer.MoveCaret(Key.Right, true, false);

        Assert.Equal(6, selection.Focus.Index);
    });

    [Fact]
    public Task DownMovesToTheNextLine() => Sta.Run(async () =>
    {
        var (viewer, selection, tab) = await OpenAsync("Hello there\nand again");
        using var _ = tab;

        viewer.MoveCaret(Key.Down, false, false);

        Assert.InRange(selection.Focus.Index, 12, 21);
    });

    [Fact]
    public Task ToggleTwiceTurnsCaretBrowsingOff() => Sta.Run(async () =>
    {
        var (viewer, selection, tab) = await OpenAsync("Hello from the tests.");
        using var _ = tab;

        await viewer.ToggleCaret();

        Assert.True(selection.IsEmpty);
    });
}
