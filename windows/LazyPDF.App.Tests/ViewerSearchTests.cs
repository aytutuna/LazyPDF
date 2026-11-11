using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Threading;
using LazyPDF.App.Documents;
using LazyPDF.App.Panels.Search;
using LazyPDF.App.Viewer;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// The search the find bar and the Search panel share, over the text of a file read for the viewer.
[Collection("Application")]
public sealed class ViewerSearchTests
{
    private static byte[] Pages(int count) => Pdfs.Text(count, "The quick brown fox jumps over the lazy dog.");

    private static ViewerSearch Searching(byte[] bytes, int startPage = 0) =>
        new(() => TextSource.OpenAsync(bytes, null), () => startPage, action => action());

    [Fact]
    public async Task EveryMatchOnEveryPageIsListedWithItsWords()
    {
        var search = Searching(Pages(3));

        await search.Start("lazy dog", new TextSearchOptions());

        Assert.Equal([0, 1, 2], search.Hits.Select(h => h.Page));
        Assert.All(search.Hits, h => Assert.Equal("lazy dog", h.Text));
        Assert.EndsWith("over the", search.Hits[0].Before);
        Assert.StartsWith(".", search.Hits[0].After);
        Assert.False(search.Running);
    }

    [Fact]
    public async Task AFileWithoutAnyTextSaysSoWhenNothingIsFound()
    {
        var search = Searching(PdfFromText.Create("", new FakeFonts()).Bytes);

        await search.Start("fox", new TextSearchOptions());

        Assert.Empty(search.Hits);
        Assert.True(search.NoText);
    }

    [Fact]
    public async Task AMissingWordInAFileWithTextIsNotNoText()
    {
        var search = Searching(Pages(2));

        await search.Start("giraffe", new TextSearchOptions());

        Assert.Empty(search.Hits);
        Assert.False(search.NoText);
    }

    [Fact]
    public async Task TheFirstCurrentHitIsTheFirstOneAtOrAfterTheStartPage()
    {
        var search = Searching(Pages(3), startPage: 1);

        await search.Start("fox", new TextSearchOptions());

        Assert.Equal(1, search.Current);
        Assert.Equal(1, search.Hits[search.Current].Page);
    }

    [Fact]
    public async Task SearchingAgainAfterAnEditLeavesTheViewWhereItIs()
    {
        var search = Searching(Pages(3), startPage: 1);
        int moves = 0;
        search.CurrentChanged += (_, _) => moves++;
        await search.Start("fox", new TextSearchOptions());
        Assert.Equal(1, moves);

        await search.Restart();

        Assert.Equal(1, moves);
        Assert.Equal(3, search.Hits.Count);
        Assert.True(search.Current >= 0);
    }

    [Fact]
    public async Task AStepAfterARestartGoesToTheHitAgain()
    {
        var search = Searching(Pages(3));
        await search.Start("fox", new TextSearchOptions());
        await search.Restart();
        int moves = 0;
        search.CurrentChanged += (_, _) => moves++;

        search.Next();

        Assert.Equal(1, moves);
    }

    [Fact]
    public async Task WithNothingAfterTheStartPageTheFirstHitIsCurrent()
    {
        var search = Searching(Pages(2), startPage: 5);

        await search.Start("fox", new TextSearchOptions());

        Assert.Equal(0, search.Current);
    }

    [Fact]
    public async Task NextAfterScrollingAwayGoesToTheFirstHitAfterTheView()
    {
        int page = 0;
        var bytes = Pages(5);
        var search = new ViewerSearch(() => TextSource.OpenAsync(bytes, null), () => page, action => action());
        await search.Start("fox", new TextSearchOptions());
        page = 3;

        search.Next();

        Assert.Equal(3, search.Hits[search.Current].Page);
        Assert.Equal(SearchWrap.None, search.Wrapped);
    }

    [Fact]
    public async Task NextFromTheLastHitSaysItWrapped()
    {
        var search = Searching(Pages(3), startPage: 2);
        await search.Start("fox", new TextSearchOptions());

        search.Next();

        Assert.Equal(0, search.Current);
        Assert.Equal(SearchWrap.Start, search.Wrapped);
    }

    [Fact]
    public async Task NextAndPreviousGoRoundTheHits()
    {
        var search = Searching(Pages(3));
        await search.Start("fox", new TextSearchOptions());
        int moved = 0;
        search.CurrentChanged += (_, _) => moved++;

        search.Next();
        search.Next();
        search.Next();
        search.Previous();

        Assert.Equal(2, search.Current);
        Assert.Equal(4, moved);
    }

    [Fact]
    public async Task SelectingAHitMakesItCurrent()
    {
        var search = Searching(Pages(3));
        await search.Start("fox", new TextSearchOptions());

        search.Select(2);
        search.Select(99);

        Assert.Equal(2, search.Current);
    }

    [Fact]
    public async Task OptionsChangeWhatMatches()
    {
        var search = Searching(Pages(2));

        await search.Start("LAZY", new TextSearchOptions());
        int loose = search.Hits.Count;
        await search.Start("LAZY", new TextSearchOptions(MatchCase: true));
        int exact = search.Hits.Count;
        await search.Start("la", new TextSearchOptions(WholeWord: true));
        int whole = search.Hits.Count;
        await search.Start("l.zy", new TextSearchOptions(Regex: true));
        int pattern = search.Hits.Count;

        Assert.Equal((2, 0, 0, 2), (loose, exact, whole, pattern));
    }

    [Fact]
    public async Task ABadPatternIsReportedAndFindsNothing()
    {
        var search = Searching(Pages(1));

        await search.Start("(", new TextSearchOptions(Regex: true));

        Assert.True(search.BadPattern);
        Assert.Empty(search.Hits);
        Assert.False(search.Running);
    }

    [Fact]
    public async Task AnEmptyQueryClears()
    {
        var search = Searching(Pages(2));
        await search.Start("fox", new TextSearchOptions());

        await search.Start("", new TextSearchOptions());

        Assert.Empty(search.Hits);
        Assert.Equal(-1, search.Current);
        Assert.Equal("", search.Query);
    }

    [Fact]
    public async Task AnotherSearchReplacesTheOneBefore()
    {
        byte[] bytes = Pages(2);
        var slow = new TaskCompletionSource<TextSource?>();
        int calls = 0;
        var search = new ViewerSearch(() => calls++ == 0 ? slow.Task : TextSource.OpenAsync(bytes, null), () => 0, action => action());

        var first = search.Start("fox", new TextSearchOptions());
        var second = search.Start("dog", new TextSearchOptions());
        await second;
        slow.SetResult(await TextSource.OpenAsync(bytes, null));
        await first;

        Assert.Equal("dog", search.Query);
        Assert.Equal(2, search.Hits.Count);
        Assert.All(search.Hits, h => Assert.Equal("dog", h.Text));
    }

    [Fact]
    public async Task AFileTheEngineCannotOpenGivesNoHits()
    {
        var search = new ViewerSearch(() => Task.FromResult<TextSource?>(null), () => 0, action => action());

        await search.Start("fox", new TextSearchOptions());

        Assert.Empty(search.Hits);
        Assert.False(search.Running);
    }

    [Fact]
    public Task TypingInThePanelSearchesAndEnterMovesOn() => Sta.Run(async () =>
    {
        var ui = Dispatcher.CurrentDispatcher;
        var bytes = Pages(3);
        var search = new ViewerSearch(() => TextSource.OpenAsync(bytes, null), () => 0, action => ui.InvokeAsync(action));
        using var tab = new DocumentTab(PdfEditSession.Open(bytes), new FakeRenderer(), null, "a.pdf", null);
        var panel = new SearchSidePanel();
        panel.Attach(tab, FakeViewer.Create(search), new RecordingHost());
        var window = new Window { Content = panel, Width = 300, Height = 300 };
        window.Show();
        var box = (TextBox)panel.FindName("Query");

        box.Text = "fox";
        await Sta.Until(() => search.Query == "fox" && !search.Running);
        Assert.Equal(3, search.Hits.Count);
        var first = search.Current;

        box.RaiseEvent(new KeyEventArgs(Keyboard.PrimaryDevice, PresentationSource.FromVisual(panel)!, 0, Key.Enter) { RoutedEvent = Keyboard.PreviewKeyDownEvent });

        Assert.NotEqual(first, search.Current);
        window.Close();
    });
}
