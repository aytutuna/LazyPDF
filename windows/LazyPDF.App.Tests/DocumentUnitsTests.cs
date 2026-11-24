using System.Windows.Automation.Text;
using LazyPDF.App.Viewer;
using Xunit;
using static LazyPDF.App.Tests.TextPdf;

namespace LazyPDF.App.Tests;

public sealed class DocumentUnitsTests
{
    // "ab cd\nef\n", "\n", "g<smiley>h\n"
    private static readonly PageUiaText[] Sample = [.. Pages(Line(100, 700, "ab cd") + Line(100, 688, "ef"), "", Line(100, 700, "g\U0001F600h")).Select(PageUiaText.Of)];

    private static DocumentUnits Whole() => new(3, p => Sample[p]);

    // Only the pages in the set are loaded; the document has 2000 pages and every loaded page is the first sample page.
    private static DocumentUnits Large(params int[] loaded) => new(2000, p => loaded.Contains(p) ? Sample[0] : null);

    [Fact]
    public void ThePagesAreWhatTheSampleSays()
    {
        Assert.Equal(["ab cd\nef\n", "\n", "g\U0001F600h\n"], Sample.Select(s => s.Text));
    }

    [Fact]
    public void PlacesAreNormalizedFromTheLoadedPageAlone()
    {
        var u = new DocumentUnits(3, p => p == 0 ? Sample[0] : null);
        Assert.Equal(new DocPos(1, 0), u.Normalize(new DocPos(0, 9)));
        Assert.Equal(new DocPos(1, 0), u.Normalize(new DocPos(0, int.MaxValue)));
        Assert.Equal(new DocPos(0, 8), u.Normalize(new DocPos(0, 8)));
        Assert.Equal(u.End, u.Normalize(new DocPos(3, 0)));
        Assert.Equal(u.End, u.Normalize(new DocPos(7, 3)));
        Assert.Equal(u.Start, u.Normalize(new DocPos(-1, 3)));
        Assert.Equal(new DocPos(1, 5), u.Normalize(new DocPos(1, 5)));
    }

    [Fact]
    public void ACaretAtTheEndOfAPageIsTheStartOfTheNext()
    {
        var u = Whole();
        Assert.Equal(new DocPos(1, 0), u.FromCaret(new Caret(0, int.MaxValue)).Pos);
        Assert.Equal(new DocPos(1, 0), u.FromCaret(new Caret(0, 8)).Pos);
        Assert.Equal(new DocPos(0, 6), u.FromCaret(new Caret(0, 5)).Pos);
        Assert.Equal(u.End, u.FromCaret(new Caret(2, int.MaxValue)).Pos);
        var partial = new DocumentUnits(3, p => p == 0 ? Sample[0] : null);
        Assert.Equal(new DocPos(2, 0), partial.FromCaret(new Caret(1, int.MaxValue)).Pos);
        Assert.Equal(new DocPos(1, 0), partial.FromCaret(new Caret(1, 4)).Pos);
    }

    [Fact]
    public void ACaretInsideAPageThatIsNotLoadedIsNotCollapsedSilently()
    {
        var u = new DocumentUnits(3, p => p == 1 ? null : Sample[p]);
        Assert.Equal((new DocPos(1, 0), -1), u.FromCaret(new Caret(1, 0)));
        Assert.Equal((new DocPos(1, 0), 1), u.FromCaret(new Caret(1, 4)));
        Assert.Equal((new DocPos(2, 0), -1), u.FromCaret(new Caret(1, int.MaxValue)));
    }

    [Fact]
    public void ASelectionSnapsOutwardsToWholeCharacters()
    {
        var u = Whole();
        Assert.Equal((new Caret(0, 1), new Caret(0, 4)), u.Selection(new DocPos(0, 1), new DocPos(0, 4)));
        // Page 2 is "g<smiley>h": the pair is one character however its units are cut.
        Assert.Equal((new Caret(2, 1), new Caret(2, 2)), u.Selection(new DocPos(2, 2), new DocPos(2, 2 + 1)));
        Assert.Equal((new Caret(0, 0), new Caret(2, int.MaxValue)), u.Selection(u.Start, u.End));
        Assert.Equal((new Caret(0, 5), new Caret(1, int.MaxValue)), u.Selection(new DocPos(0, 6), new DocPos(2, 0)));
        // The last line of page 0 takes its page break: the selection ends on page 0.
        Assert.Equal((new Caret(0, 5), new Caret(0, int.MaxValue)), u.Selection(new DocPos(0, 6), new DocPos(1, 0)));
        Assert.Null(u.Selection(new DocPos(0, 3), new DocPos(0, 3)));
        Assert.Null(u.Selection(new DocPos(0, 5), new DocPos(0, 6)));
    }

    [Fact]
    public void ASelectionOnAPageThatIsNotLoadedNeedsItsStartOrEnd()
    {
        var u = Large(0);
        Assert.Equal((new Caret(0, 0), new Caret(4, int.MaxValue)), u.Selection(new DocPos(0, 0), new DocPos(5, 0)));
        Assert.Null(u.Selection(new DocPos(0, 0), new DocPos(5, 3)));
        Assert.Null(u.Selection(new DocPos(5, 3), new DocPos(6, 0)));
    }

    [Fact]
    public void TheDocumentAtItsEndIsTheWholeDocument()
    {
        var u = Whole();
        var all = u.Enclosing(u.End, TextUnit.Document);
        Assert.Equal((u.Start, u.End, -1), (all.Start, all.End, all.Unloaded));
        var big = Large(1998, 1999);
        var tail = big.Enclosing(big.End, TextUnit.Document);
        Assert.Equal((new DocPos(1998, 0), new DocPos(2000, 0)), (tail.Start, tail.End));
        Assert.Equal(1997, tail.Unloaded);
        var line = u.Enclosing(u.End, TextUnit.Line);
        Assert.Equal((u.End, u.End), (line.Start, line.End));
    }

    [Fact]
    public void CharactersStepOverASurrogatePairAndALigatureUnitByUnit()
    {
        var u = Whole();
        Assert.Equal(new DocPos(2, 3), u.Move(new DocPos(2, 0), TextUnit.Character, 2).Pos);
        Assert.Equal(new DocPos(2, 1), u.Move(new DocPos(2, 3), TextUnit.Character, -1).Pos);
        Assert.Equal(new DocPos(2, 0), u.Move(new DocPos(2, 3), TextUnit.Character, -2).Pos);
        var pages = Pages(Line(100, 700, "aﬁb"));
        var one = new DocumentUnits(1, _ => PageUiaText.Of(pages[0]));
        Assert.Equal(new DocPos(0, 2), one.Move(new DocPos(0, 0), TextUnit.Character, 2).Pos);
    }

    [Fact]
    public void CharactersCrossThePageBorderThroughTheLineFeed()
    {
        var u = Whole();
        Assert.Equal(new DocPos(0, 8), u.Move(new DocPos(0, 7), TextUnit.Character, 1).Pos);
        Assert.Equal(new DocPos(1, 0), u.Move(new DocPos(0, 8), TextUnit.Character, 1).Pos);
        Assert.Equal(new DocPos(2, 0), u.Move(new DocPos(1, 0), TextUnit.Character, 1).Pos);
        Assert.Equal(new DocPos(0, 8), u.Move(new DocPos(1, 0), TextUnit.Character, -1).Pos);
        Assert.Equal(new DocPos(2, 4), u.Move(u.End, TextUnit.Character, -1).Pos);
    }

    [Fact]
    public void AnEmptyPageIsOneUnitOfEachKind()
    {
        var u = Whole();
        foreach (var unit in new[] { TextUnit.Word, TextUnit.Line, TextUnit.Paragraph, TextUnit.Format, TextUnit.Page })
        {
            var span = u.Enclosing(new DocPos(1, 0), unit);
            Assert.Equal((new DocPos(1, 0), new DocPos(2, 0)), (span.Start, span.End));
        }
    }

    [Fact]
    public void MovesStopAtTheRealEnds()
    {
        var u = Whole();
        var forward = u.Move(new DocPos(2, 0), TextUnit.Line, 5);
        Assert.Equal((u.End, 1, -1), (forward.Pos, forward.Moved, forward.Unloaded));
        var back = u.Move(new DocPos(0, 3), TextUnit.Line, -4);
        Assert.Equal((u.Start, -1, -1), (back.Pos, back.Moved, back.Unloaded));
        Assert.Equal(0, u.Move(u.End, TextUnit.Word, 3).Moved);
        Assert.Equal(0, u.Move(u.Start, TextUnit.Word, -3).Moved);
    }

    [Fact]
    public void WordsAndLinesMoveByTheirStarts()
    {
        var u = Whole();
        Assert.Equal(new DocPos(0, 3), u.Move(new DocPos(0, 0), TextUnit.Word, 1).Pos);
        Assert.Equal(new DocPos(0, 6), u.Move(new DocPos(0, 0), TextUnit.Word, 2).Pos);
        Assert.Equal(new DocPos(0, 3), u.Move(new DocPos(0, 5), TextUnit.Word, -1).Pos);
        Assert.Equal(new DocPos(0, 0), u.Move(new DocPos(0, 3), TextUnit.Word, -1).Pos);
        Assert.Equal(new DocPos(1, 0), u.Move(new DocPos(0, 6), TextUnit.Line, 1).Pos);
        var span = u.Enclosing(new DocPos(0, 4), TextUnit.Word);
        Assert.Equal((new DocPos(0, 3), new DocPos(0, 6)), (span.Start, span.End));
        span = u.Enclosing(new DocPos(0, 7), TextUnit.Line);
        Assert.Equal((new DocPos(0, 6), new DocPos(1, 0)), (span.Start, span.End));
        span = u.Enclosing(new DocPos(0, 7), TextUnit.Character);
        Assert.Equal((new DocPos(0, 7), new DocPos(0, 8)), (span.Start, span.End));
    }

    [Fact]
    public void ThePageAndTheDocumentAreUnits()
    {
        var u = Whole();
        Assert.Equal(new DocPos(2, 0), u.Move(new DocPos(0, 4), TextUnit.Page, 2).Pos);
        Assert.Equal(new DocPos(0, 0), u.Move(new DocPos(0, 4), TextUnit.Page, -1).Pos);
        var all = u.Enclosing(new DocPos(1, 0), TextUnit.Document);
        Assert.Equal((u.Start, u.End, -1), (all.Start, all.End, all.Unloaded));
        Assert.Equal(u.End, u.Move(new DocPos(1, 0), TextUnit.Document, 1).Pos);
        Assert.Equal(u.Start, u.Move(new DocPos(1, 0), TextUnit.Document, -1).Pos);
    }

    [Fact]
    public void AWalkStopsAtTheStartOfAnUnloadedPage()
    {
        var u = Large(0, 1, 2);
        var walk = u.Move(new DocPos(0, 0), TextUnit.Page, 500);
        Assert.Equal((new DocPos(3, 0), 3, 3), (walk.Pos, walk.Moved, walk.Unloaded));
        walk = u.Move(new DocPos(0, 0), TextUnit.Line, 1000);
        Assert.Equal((new DocPos(3, 0), 6, 3), (walk.Pos, walk.Moved, walk.Unloaded));
    }

    [Fact]
    public void ABackwardWalkStaysInsideThePageItCameFrom()
    {
        var u = Large(5, 6);
        var walk = u.Move(new DocPos(6, 0), TextUnit.Character, -100);
        Assert.Equal((new DocPos(5, 0), -9, 4), (walk.Pos, walk.Moved, walk.Unloaded));
        walk = u.Move(new DocPos(5, 0), TextUnit.Word, -1);
        Assert.Equal((new DocPos(5, 0), 0, 4), (walk.Pos, walk.Moved, walk.Unloaded));
    }

    [Fact]
    public void NothingMovesWhenTheFirstPageIsNotLoaded()
    {
        var u = Large(0);
        var walk = u.Move(new DocPos(9, 2), TextUnit.Word, 3);
        Assert.Equal((new DocPos(9, 2), 0, 9), (walk.Pos, walk.Moved, walk.Unloaded));
        var span = u.Enclosing(new DocPos(9, 2), TextUnit.Line);
        Assert.Equal((new DocPos(9, 2), new DocPos(9, 2), 9), (span.Start, span.End, span.Unloaded));
    }

    [Fact]
    public void TheEndOfTheDocumentIsReportedOnlyThroughLoadedPages()
    {
        var all = new DocumentUnits(3, p => Sample[p]);
        Assert.Equal(-1, all.Move(new DocPos(0, 0), TextUnit.Page, 9).Unloaded);
        var gap = new DocumentUnits(3, p => p == 1 ? null : Sample[p]);
        var walk = gap.Move(new DocPos(0, 0), TextUnit.Page, 9);
        Assert.Equal((new DocPos(1, 0), 1, 1), (walk.Pos, walk.Moved, walk.Unloaded));
    }

    [Fact]
    public void TheDocumentIsOnlyAsLongAsTheLoadedPagesInARow()
    {
        var u = Large(4, 5, 6);
        var span = u.Enclosing(new DocPos(5, 1), TextUnit.Document);
        Assert.Equal((new DocPos(4, 0), new DocPos(7, 0)), (span.Start, span.End));
        Assert.True(span.Unloaded >= 0);
        var walk = u.Move(new DocPos(5, 1), TextUnit.Document, 1);
        Assert.Equal((new DocPos(7, 0), 1, 7), (walk.Pos, walk.Moved, walk.Unloaded));
    }

    [Fact]
    public void FormatRunsAreUnits()
    {
        var content = "BT /F1 10 Tf 100 700 Td (plain ) Tj /F1 14 Tf (big) Tj ET\n";
        var pages = Pages(content);
        var u = new DocumentUnits(1, _ => PageUiaText.Of(pages[0]));
        Assert.Equal(new DocPos(0, 6), u.Move(new DocPos(0, 0), TextUnit.Format, 1).Pos);
        var span = u.Enclosing(new DocPos(0, 8), TextUnit.Format);
        Assert.Equal((new DocPos(0, 6), new DocPos(1, 0)), (span.Start, span.End));
        Assert.Equal(new DocPos(0, 0), u.Move(new DocPos(0, 8), TextUnit.Format, -2).Pos);
    }
}
