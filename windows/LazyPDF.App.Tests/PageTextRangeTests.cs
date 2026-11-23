using System.Runtime.CompilerServices;
using System.Windows.Automation;
using System.Windows.Automation.Text;
using LazyPDF.App.Documents;
using LazyPDF.App.Viewer;
using LazyPDF.Core;
using Xunit;
using static LazyPDF.App.Tests.TextPdf;

namespace LazyPDF.App.Tests;

public sealed class PageTextRangeTests
{
    // "ab cd\nef\n", "\n", "g<smiley>h\n"
    private static readonly TextPage[] Sample = Pages(Line(100, 700, "ab cd") + Line(100, 688, "ef"), "", Line(100, 700, "g\U0001F600h"));

    private static PageTextRange Range(FakeTextHost host, int page = 0, int offset = 0, int endPage = -1, int endOffset = 0) =>
        PageTextRange.Create(host, new DocPos(page, offset), new DocPos(endPage < 0 ? page : endPage, endPage < 0 ? offset : endOffset))!;

    private static FakeTextHost Whole(DocumentTab tab) => new(tab, 3, p => Sample[p]);

    [Fact]
    public void ACloneIsEqualAndMovesOnItsOwn()
    {
        using var tab = FakeTextHost.NewTab();
        var host = Whole(tab);
        var range = Range(host, 0, 1, 0, 4);

        var clone = range.Clone();
        clone.MoveEndpointByUnit(TextPatternRangeEndpoint.End, TextUnit.Character, 1);

        Assert.False(range.Compare(clone));
        Assert.Equal(new DocPos(0, 4), range.Places.End);
        Assert.Equal(new DocPos(0, 5), clone.Places.End);
        Assert.True(range.Compare(range.Clone()));
    }

    [Fact]
    public void EndpointsAreComparedByPlace()
    {
        using var tab = FakeTextHost.NewTab();
        var host = Whole(tab);
        var a = Range(host, 0, 1, 0, 4);
        var b = Range(host, 0, 4, 2, 0);

        Assert.Equal(0, a.CompareEndpoints(TextPatternRangeEndpoint.End, b, TextPatternRangeEndpoint.Start));
        Assert.True(a.CompareEndpoints(TextPatternRangeEndpoint.Start, b, TextPatternRangeEndpoint.Start) < 0);
        Assert.True(b.CompareEndpoints(TextPatternRangeEndpoint.End, a, TextPatternRangeEndpoint.End) > 0);
    }

    [Fact]
    public void ARangeStartingAtTheEndOfAPageIsTheStartOfTheNext()
    {
        using var tab = FakeTextHost.NewTab();
        var host = Whole(tab);

        var range = Range(host, 0, 9);

        Assert.Equal(new DocPos(1, 0), range.Places.Start);
        Assert.Equal(new DocPos(1, 0), range.Places.End);
    }

    [Theory]
    [InlineData(TextUnit.Character, 0, 1, "a")]
    [InlineData(TextUnit.Word, 1, 1, "ab ")]
    [InlineData(TextUnit.Line, 8, 8, "ef\n")]
    [InlineData(TextUnit.Paragraph, 1, 1, "ab cd\nef\n")]
    [InlineData(TextUnit.Page, 4, 4, "ab cd\nef\n")]
    public void ARangeExpandsToTheUnitAroundItsStart(TextUnit unit, int start, int end, string expected)
    {
        using var tab = FakeTextHost.NewTab();
        var host = Whole(tab);
        var range = Range(host, 0, start, 0, end);

        range.ExpandToEnclosingUnit(unit);

        Assert.Equal(expected, range.GetText(-1));
    }

    [Fact]
    public void TheDocumentIsTheWholeOfIt()
    {
        using var tab = FakeTextHost.NewTab();
        var host = Whole(tab);
        var range = Range(host, 2, 1);

        range.ExpandToEnclosingUnit(TextUnit.Document);

        Assert.Equal("ab cd\nef\n\ng\U0001F600h\n", range.GetText(-1));
        Assert.Equal(new DocPos(3, 0), range.Places.End);
    }

    [Fact]
    public void ADegenerateRangeMovesAsAPoint()
    {
        using var tab = FakeTextHost.NewTab();
        var host = Whole(tab);
        var range = Range(host, 0, 0);

        Assert.Equal(2, range.Move(TextUnit.Line, 2));

        Assert.Equal(new DocPos(1, 0), range.Places.Start);
        Assert.Equal(range.Places.Start, range.Places.End);
        Assert.Equal(-2, range.Move(TextUnit.Line, -5));
        Assert.Equal(new DocPos(0, 0), range.Places.Start);
    }

    [Fact]
    public void ARangeMovesAUnitAtATime()
    {
        using var tab = FakeTextHost.NewTab();
        var host = Whole(tab);
        var range = Range(host, 0, 1, 0, 2);

        Assert.Equal(1, range.Move(TextUnit.Word, 1));
        Assert.Equal("cd", range.GetText(-1).TrimEnd('\n'));
        Assert.Equal(1, range.Move(TextUnit.Line, 1));
        Assert.Equal("ef\n", range.GetText(-1));
        Assert.Equal(-1, range.Move(TextUnit.Line, -1));
        Assert.Equal("ab cd\n", range.GetText(-1));
    }

    [Fact]
    public void MovingPastTheEndStopsOnTheLastUnit()
    {
        using var tab = FakeTextHost.NewTab();
        var host = Whole(tab);
        var range = Range(host, 2, 0, 2, 1);

        Assert.Equal(0, range.Move(TextUnit.Page, 3));
        Assert.Equal("g\U0001F600h\n", range.GetText(-1));
        Assert.Equal(-2, range.Move(TextUnit.Page, -4));
        Assert.Equal("ab cd\nef\n", range.GetText(-1));
    }

    [Fact]
    public void AnEndpointMovesAndDragsTheOtherOneAlong()
    {
        using var tab = FakeTextHost.NewTab();
        var host = Whole(tab);
        var range = Range(host, 0, 3, 0, 5);

        Assert.Equal(1, range.MoveEndpointByUnit(TextPatternRangeEndpoint.End, TextUnit.Line, 1));
        Assert.Equal("cd\n", range.GetText(-1));
        Assert.Equal(2, range.MoveEndpointByUnit(TextPatternRangeEndpoint.Start, TextUnit.Page, 2));
        Assert.Equal(new DocPos(2, 0), range.Places.Start);
        Assert.Equal(range.Places.Start, range.Places.End);
        Assert.Equal("", range.GetText(-1));
    }

    [Fact]
    public void AnEndpointTakesThePlaceOfAnotherRangesEndpoint()
    {
        using var tab = FakeTextHost.NewTab();
        var host = Whole(tab);
        var range = Range(host, 0, 0, 0, 2);
        var target = Range(host, 0, 6, 0, 8);

        range.MoveEndpointByRange(TextPatternRangeEndpoint.End, target, TextPatternRangeEndpoint.End);
        Assert.Equal("ab cd\nef", range.GetText(-1));
        range.MoveEndpointByRange(TextPatternRangeEndpoint.Start, target, TextPatternRangeEndpoint.Start);
        Assert.Equal("ef", range.GetText(-1));
        range.MoveEndpointByRange(TextPatternRangeEndpoint.End, target, TextPatternRangeEndpoint.Start);
        Assert.Equal("", range.GetText(-1));
    }

    [Fact]
    public void TextIsCutAtTheLimit()
    {
        using var tab = FakeTextHost.NewTab();
        var host = Whole(tab);
        var range = Range(host, 0, 0, 3, 0);

        Assert.Equal("ab c", range.GetText(4));
        Assert.Equal("", range.GetText(0));
        Assert.Equal("ab cd\nef\n\ng\U0001F600h\n", range.GetText(-1));
        Assert.Throws<ArgumentOutOfRangeException>(() => range.GetText(-2));
    }

    [Fact]
    public void ARangeOfAnotherTabIsNotAvailableUntilItsTabIsBack()
    {
        using var a = FakeTextHost.NewTab();
        using var b = FakeTextHost.NewTab();
        var host = Whole(a);
        var range = Range(host, 0, 0, 0, 5);

        host.Tab = b;
        Assert.Throws<ElementNotAvailableException>(() => range.GetText(-1));
        Assert.Throws<ElementNotAvailableException>(range.Clone);
        Assert.Throws<ElementNotAvailableException>(() => range.Compare(range));
        Assert.Throws<ElementNotAvailableException>(() => range.Move(TextUnit.Line, 1));
        Assert.Throws<ElementNotAvailableException>(() => range.ExpandToEnclosingUnit(TextUnit.Word));
        host.Tab = a;
        Assert.Equal("ab cd", range.GetText(-1));
    }

    [Fact]
    public void AnEditMakesEveryEarlierRangeStale()
    {
        using var tab = FakeTextHost.NewTab();
        var host = Whole(tab);
        var range = Range(host, 0, 0, 0, 5);
        var other = Range(host, 0, 0);

        tab.Refresh();

        Assert.Throws<ElementNotAvailableException>(() => range.GetText(-1));
        Assert.Throws<ElementNotAvailableException>(() => range.CompareEndpoints(TextPatternRangeEndpoint.Start, other, TextPatternRangeEndpoint.Start));
        Assert.Throws<ElementNotAvailableException>(() => other.MoveEndpointByRange(TextPatternRangeEndpoint.Start, range, TextPatternRangeEndpoint.Start));
        Assert.Equal("ab cd", Range(host, 0, 0, 0, 5).GetText(-1));
    }

    [Fact]
    public void ARangeDoesNotKeepItsTabAlive()
    {
        var host = new FakeTextHost(null, 3, p => Sample[p]);
        var (range, weak) = Make(host);

        GC.Collect();
        GC.WaitForPendingFinalizers();
        GC.Collect();

        Assert.False(weak.IsAlive);
        Assert.Throws<ElementNotAvailableException>(() => range.GetText(-1));
    }

    [MethodImpl(MethodImplOptions.NoInlining)]
    private static (PageTextRange, WeakReference) Make(FakeTextHost host)
    {
        var tab = FakeTextHost.NewTab();
        host.Tab = tab;
        var range = Range(host);
        tab.Dispose();
        host.Tab = null;
        return (range, new WeakReference(tab));
    }

    [Fact]
    public void AnUnloadedPageIsABoundaryNotAnEmptyPage()
    {
        using var tab = FakeTextHost.NewTab();
        var host = new FakeTextHost(tab, 2000, p => p < 10 ? Sample[0] : null);
        var range = Range(host, 0, 0);

        Assert.Equal(10, range.Move(TextUnit.Page, 500));
        Assert.Equal(new DocPos(10, 0), range.Places.Start);
        Assert.Contains(10, host.Requested);

        var all = Range(host, 4, 0);
        all.ExpandToEnclosingUnit(TextUnit.Document);
        Assert.Equal(new DocPos(0, 0), all.Places.Start);
        Assert.Equal(new DocPos(10, 0), all.Places.End);
        string text = all.GetText(-1);
        Assert.Equal(string.Concat(Enumerable.Repeat("ab cd\nef\n", 10)), text);
        Assert.Equal(text, all.GetText(-1));
        Assert.Equal([10], host.Requested);
    }

    [Fact]
    public void WhenTheFirstPageIsNotLoadedNothingMovesAndItIsRequested()
    {
        using var tab = FakeTextHost.NewTab();
        var host = new FakeTextHost(tab, 5, _ => null);
        var range = Range(host, 2, 3);

        Assert.Equal(0, range.Move(TextUnit.Word, 1));
        Assert.Equal(new DocPos(2, 3), range.Places.Start);
        Assert.Equal(0, range.MoveEndpointByUnit(TextPatternRangeEndpoint.End, TextUnit.Line, 1));
        Assert.Equal("", range.GetText(-1));
        Assert.Equal([2], host.Requested);
    }

    [Fact]
    public void ARangeMovesOnToTheStartOfAnUnloadedPage()
    {
        using var tab = FakeTextHost.NewTab();
        var host = new FakeTextHost(tab, 5, p => p < 2 ? Sample[p] : null);
        var range = Range(host, 0, 0, 0, 5);

        Assert.Equal(2, range.Move(TextUnit.Page, 3));
        Assert.Equal(new DocPos(2, 0), range.Places.Start);
        Assert.Equal(new DocPos(2, 0), range.Places.End);
        Assert.Contains(2, host.Requested);

        var last = Range(host, 1, 0, 2, 0);
        Assert.Equal(1, last.Move(TextUnit.Line, 1));
        Assert.Equal(new DocPos(2, 0), last.Places.Start);
        Assert.Equal(new DocPos(2, 0), last.Places.End);
    }

    [Fact]
    public void ReadingARangeThatEndsOnAPageStartDoesNotAskForThatPage()
    {
        using var tab = FakeTextHost.NewTab();
        var host = new FakeTextHost(tab, 5, p => p < 2 ? Sample[p] : null);

        Assert.Equal("\n", Range(host, 1, 0, 2, 0).GetText(-1));
        Assert.Empty(host.Requested);
    }

    // "one two", "two three", "TWO"
    private static readonly TextPage[] Search = Pages(Line(100, 700, "one two"), Line(100, 700, "two three"), Line(100, 700, "TWO"));

    [Fact]
    public void FindTextTakesTheFirstHitForwardAndTheLastBackward()
    {
        using var tab = FakeTextHost.NewTab();
        var host = new FakeTextHost(tab, 3, p => Search[p]);
        var all = Range(host, 0, 0, 3, 0);

        var forward = all.FindText("two", backward: false, ignoreCase: false)!;
        var backward = all.FindText("two", backward: true, ignoreCase: false)!;
        var either = all.FindText("TWO", backward: false, ignoreCase: true)!;

        Assert.Equal("two", forward.GetText(-1));
        Assert.Equal(new DocPos(0, 4), ((PageTextRange)forward).Places.Start);
        Assert.Equal(new DocPos(1, 0), ((PageTextRange)backward).Places.Start);
        Assert.Equal(new DocPos(0, 4), ((PageTextRange)either).Places.Start);
        Assert.Equal(new DocPos(2, 0), ((PageTextRange)all.FindText("TWO", backward: true, ignoreCase: true)!).Places.Start);
        Assert.Null(all.FindText("four", backward: false, ignoreCase: true));
    }

    [Fact]
    public void FindTextStaysInsideTheRange()
    {
        using var tab = FakeTextHost.NewTab();
        var host = new FakeTextHost(tab, 3, p => Search[p]);

        var inner = Range(host, 0, 1, 1, 3);

        Assert.Equal(new DocPos(0, 4), ((PageTextRange)inner.FindText("two", false, false)!).Places.Start);
        Assert.Equal(new DocPos(1, 0), ((PageTextRange)inner.FindText("two", true, false)!).Places.Start);
        Assert.Null(Range(host, 0, 5, 1, 2).FindText("two", false, false));
    }

    [Fact]
    public void APageThatIsNotLoadedStopsTheSearchAndIsRequested()
    {
        using var tab = FakeTextHost.NewTab();
        var host = new FakeTextHost(tab, 3, p => p == 1 ? null : Search[p]);
        var all = Range(host, 0, 3, 3, 0);

        Assert.Null(all.FindText("three", false, false));
        Assert.Equal([1], host.Requested);
        Assert.Equal(new DocPos(2, 0), ((PageTextRange)all.FindText("TWO", true, false)!).Places.Start);

        host.Pages = p => Search[p];
        Assert.Equal("three", all.FindText("three", false, false)!.GetText(-1));
    }

    [Fact]
    public void AttributesAreThoseOfTheCharactersInTheRange()
    {
        using var tab = FakeTextHost.NewTab();
        var pages = Pages("1 0 0 rg " + Line(100, 700, "ab", 10) + Line(100, 600, "cd", 14), Line(100, 700, "plain"));
        var host = new FakeTextHost(tab, 2, p => pages[p]);
        var first = Range(host, 0, 0, 0, 2);
        var whole = Range(host, 0, 0, 1, 0);
        int cd = PageUiaText.Of(pages[0]).Text.IndexOf("cd", StringComparison.Ordinal);

        Assert.Equal("Helvetica", first.GetAttributeValue(TextPatternIdentifiers.FontNameAttribute.Id));
        Assert.Equal(10.0, first.GetAttributeValue(TextPatternIdentifiers.FontSizeAttribute.Id));
        Assert.Equal(0x0000FF, first.GetAttributeValue(TextPatternIdentifiers.ForegroundColorAttribute.Id));
        Assert.Equal(FlowDirections.Default, first.GetAttributeValue(TextPatternIdentifiers.TextFlowDirectionsAttribute.Id));
        Assert.Equal(true, first.GetAttributeValue(TextPatternIdentifiers.IsReadOnlyAttribute.Id));
        Assert.Same(TextPattern.MixedAttributeValue, whole.GetAttributeValue(TextPatternIdentifiers.FontSizeAttribute.Id));
        Assert.Equal("Helvetica", whole.GetAttributeValue(TextPatternIdentifiers.FontNameAttribute.Id));
        Assert.Equal(14.0, Range(host, 0, cd, 0, cd + 1).GetAttributeValue(TextPatternIdentifiers.FontSizeAttribute.Id));
        Assert.Equal(AutomationElement.NotSupported, first.GetAttributeValue(TextPatternIdentifiers.IsItalicAttribute.Id));
    }

    [Fact]
    public void OcrTextIsNotReportedAsHidden()
    {
        using var tab = FakeTextHost.NewTab();
        var pages = Pages("3 Tr " + Line(100, 700, "scanned words"));
        var host = new FakeTextHost(tab, 1, p => pages[p]);
        var range = Range(host, 0, 0, 1, 0);

        Assert.Equal(AutomationElement.NotSupported, range.GetAttributeValue(TextPatternIdentifiers.IsHiddenAttribute.Id));
        Assert.Equal("scanned words\n", range.GetText(-1));
    }

    [Fact]
    public void SelectingARangeSelectsWholeCharactersAndAnEmptyOneOnlyKeepsAPlace()
    {
        using var tab = FakeTextHost.NewTab();
        var host = Whole(tab);

        Range(host, 2, 2, 2, 3).Select();

        Assert.Equal((new Caret(2, 1), new Caret(2, 2)), host.Selection);
        host.AutomationCaret = null;

        Range(host, 0, 3, 0, 3).Select();

        Assert.Equal((new Caret(2, 1), new Caret(2, 2)), host.Selection);
        Assert.Equal(new Caret(0, 3), host.AutomationCaret);
    }
}
