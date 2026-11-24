using System.Diagnostics;
using System.Reflection;
using System.Windows;
using System.Windows.Automation.Peers;
using System.Windows.Input;
using System.Windows.Threading;
using LazyPDF.App.Documents;
using LazyPDF.App.Viewer;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// The viewer as the text host of its surface: reads that answer at once, requests for pages that are not loaded.
[Collection("Application")]
public sealed class TextHostTests
{
    private static (PageViewer Viewer, ITextHost Host, DocumentTab Tab) Open(int pages)
    {
        var tab = new DocumentTab(PdfEditSession.Open(Pdfs.Text(pages)), new FakeRenderer(), null, "a.pdf");
        var viewer = new PageViewer(null);
        viewer.Show(tab);
        viewer.Measure(new Size(800, 600));
        viewer.Arrange(new Rect(0, 0, 800, 600));
        viewer.UpdateLayout();
        return (viewer, viewer, tab);
    }

    private static T Field<T>(PageViewer viewer, string name) =>
        (T)typeof(PageViewer).GetField(name, BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(viewer)!;

    private static void Call(PageViewer viewer, string name) =>
        typeof(PageViewer).GetMethod(name, BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(viewer, [null, EventArgs.Empty]);

    private static TextSource? Source(PageViewer viewer) => Field<TextSource?>(viewer, "_source");

    [Fact]
    public Task APageThatIsNotLoadedAnswersNullAndArrivesLater() => Sta.Run(async () =>
    {
        var (viewer, host, tab) = Open(3);
        using var _ = tab;

        Assert.Null(host.Peek(1));
        Assert.Contains(1, Field<HashSet<int>>(viewer, "_wanted"));

        await Sta.Until(() => host.Peek(1) is not null);
        Assert.Contains("Page 2", host.Peek(1)!.Text);
        Assert.DoesNotContain(1, Field<HashSet<int>>(viewer, "_wanted"));
    });

    [Fact]
    public Task TheValueOfAPageRequestsNothing() => Sta.Run(() =>
    {
        var (viewer, _, tab) = Open(5);
        using var _ = tab;

        Assert.Null(viewer.Surface.PageText!(3));

        Assert.Empty(Field<HashSet<int>>(viewer, "_wanted"));
        Assert.Empty(Field<HashSet<int>>(viewer, "_pending"));
        return Task.CompletedTask;
    });

    [Fact]
    public Task APageIsRequestedOnce() => Sta.Run(async () =>
    {
        var (viewer, host, tab) = Open(3);
        using var _ = tab;

        for (int i = 0; i < 5; i++) host.Peek(2);

        Assert.Equal([2], Field<HashSet<int>>(viewer, "_pending"));
        await Sta.Until(() => host.Peek(2) is not null);
    });

    [Fact]
    public Task PagesOutsideTheDocumentAreNeverRequested() => Sta.Run(() =>
    {
        var (viewer, host, tab) = Open(3);
        using var _ = tab;

        Assert.Null(host.Peek(-1));
        Assert.Null(host.Peek(3));
        Assert.Empty(Field<HashSet<int>>(viewer, "_pending"));
        return Task.CompletedTask;
    });

    [Fact]
    public Task TheDocumentAndItsRevisionAreTheTabs() => Sta.Run(() =>
    {
        var (_, host, tab) = Open(4);
        using var _ = tab;

        Assert.Same(tab, host.Tab);
        Assert.Equal(4, host.PageCount);
        Assert.Equal(tab.Revision, host.Revision);
        Assert.True(host.LayoutReady);
        return Task.CompletedTask;
    });

    [Fact]
    public Task NothingIsLaidOutBetweenTheTabChangingAndBeingDrawn() => Sta.Run(() =>
    {
        var (viewer, host, tab) = Open(2);
        using var _ = tab;

        Call(viewer, "Tab_Changed");
        Assert.False(host.LayoutReady);
        Call(viewer, "Tab_Drawn");
        Assert.True(host.LayoutReady);
        return Task.CompletedTask;
    });

    [Fact]
    public Task TheTextBelongsToTheNewBytesAfterATabChange() => Sta.Run(async () =>
    {
        var (viewer, host, tab) = Open(3);
        using var _ = tab;
        host.Peek(0);
        await Sta.Until(() => host.Peek(0) is not null);
        host.Peek(2);

        Call(viewer, "Tab_Changed");

        Assert.Null(host.Peek(0));
        Assert.Equal([0], Field<HashSet<int>>(viewer, "_wanted"));
        Assert.Equal([0], Field<HashSet<int>>(viewer, "_pending"));
        await Sta.Until(() => host.Peek(0) is not null);
    });

    [Fact]
    public Task TextIsLoadedAheadOfWhereAReaderIs() => Sta.Run(async () =>
    {
        var (viewer, host, tab) = Open(30);
        using var _ = tab;
        host.Peek(10);

        await Sta.Until(() => Source(viewer) is { } source && Enumerable.Range(8, 11).All(p => source.Peek(p) is not null));

        Assert.Null(Source(viewer)!.Peek(7));
        Assert.Null(Source(viewer)!.Peek(19));
    });

    [Fact]
    public Task OnlyTheEndsOfWhatAReaderTouchedAreLoadedAhead() => Sta.Run(async () =>
    {
        var (viewer, host, tab) = Open(40);
        using var _ = tab;
        host.Peek(0);
        host.Peek(39);
        host.Peek(20);

        await Sta.Until(() => Field<(int, int)?>(viewer, "_readRange") is null && Field<HashSet<int>>(viewer, "_pending").Count == 0);

        var source = Source(viewer)!;
        Assert.NotNull(source.Peek(0));
        Assert.NotNull(source.Peek(39));
        Assert.NotNull(source.Peek(20));
        Assert.Null(source.Peek(10));
        Assert.Null(source.Peek(30));
        Assert.Equal(3, Enumerable.Range(0, 40).Count(p => source.Peek(p) is not null));
    });

    [Fact]
    public Task AFileTheTextCannotBeReadFromIsAnEmptyDocument() => Sta.Run(async () =>
    {
        var (viewer, host, tab) = Open(3);
        using var _ = tab;
        typeof(PageViewer).GetField("_text", BindingFlags.Instance | BindingFlags.NonPublic)!.SetValue(viewer, Task.FromResult<TextSource?>(null));

        Assert.Null(host.Peek(1));
        await Sta.Until(() => host.Peek(1) is not null);

        Assert.Equal("", host.Peek(1)!.Text);
        Assert.Equal("\n", PageUiaText.Of(host.Peek(1)!).Text);
        Assert.DoesNotContain(1, Field<HashSet<int>>(viewer, "_wanted"));
    });

    [Fact]
    public Task ReadsNeverWaitForTheTextCache() => Sta.Run(async () =>
    {
        var (viewer, host, tab) = Open(30);
        using var _ = tab;
        host.Peek(0);
        await Sta.Until(() => host.Peek(0) is not null);
        var source = Source(viewer)!;
        var cache = typeof(TextSource).GetField("_cache", BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(source)!;
        var gate = typeof(TextCache).GetField("_lock", BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(cache)!;
        var held = new ManualResetEventSlim();
        var release = new ManualResetEventSlim();
        var holder = Task.Run(() =>
        {
            lock (gate)
            {
                held.Set();
                release.Wait(TimeSpan.FromSeconds(5));
            }
        });
        held.Wait();

        var watch = Stopwatch.StartNew();
        var loaded = host.Peek(0);
        var missing = host.Peek(25);
        watch.Stop();
        release.Set();
        await holder;

        Assert.NotNull(loaded);
        Assert.Null(missing);
        Assert.True(watch.ElapsedMilliseconds < 2000);
        await Sta.Until(() => host.Peek(25) is not null);
    });

    // What a screen reader would hear, from the start of the call; the events the opening queued are let through first.
    private static async Task<List<AutomationEvents>> Listen(PageViewer viewer)
    {
        await viewer.Dispatcher.InvokeAsync(() => { }, DispatcherPriority.Background);
        var told = new List<AutomationEvents>();
        viewer.Surface.Told += told.Add;
        return told;
    }

    [Fact]
    public Task APreloadForPaintingTellsNoTextChange() => Sta.Run(async () =>
    {
        var (viewer, _, tab) = Open(30);
        using var _ = tab;
        var told = await Listen(viewer);

        typeof(PageViewer).GetMethod("PreloadText", BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(viewer, []);
        await Sta.Until(() => Source(viewer) is { } source && viewer.VisiblePages.Take(8).All(p => source.Peek(p) is not null));
        await Task.Delay(200);

        Assert.DoesNotContain(AutomationEvents.TextPatternOnTextChanged, told);
    });

    [Fact]
    public Task APageAReaderAskedForTellsOneTextChange() => Sta.Run(async () =>
    {
        var (viewer, host, tab) = Open(5);
        using var _ = tab;
        var told = await Listen(viewer);

        Assert.Null(host.Peek(3));
        await Sta.Until(() => host.Peek(3) is not null);
        await Task.Delay(200);

        Assert.Single(told, AutomationEvents.TextPatternOnTextChanged);
    });

    [Fact]
    public Task AReadOverMorePagesThanAreKeptSettlesInsteadOfLoadingForever() => Sta.Run(async () =>
    {
        var (viewer, host, tab) = Open(100);
        using var _ = tab;
        var told = await Listen(viewer);
        var whole = PageTextRange.Create(host, new DocPos(0, 0), new DocPos(100, 0))!;
        int capacity = Source(viewer)?.Capacity ?? 48;
        string text = "";

        // A reader asks again each time the text changes.
        for (int round = 0; round < 40; round++)
        {
            text = whole.GetText(-1);
            await Task.Delay(100);
        }
        told.Clear();
        text = whole.GetText(-1);
        await Task.Delay(300);

        Assert.DoesNotContain(AutomationEvents.TextPatternOnTextChanged, told);
        Assert.Empty(Field<HashSet<int>>(viewer, "_pending"));
        Assert.Contains("Page 1.", text);
        Assert.DoesNotContain("Page 100.", text);
        Assert.True(Enumerable.Range(0, capacity).All(p => Source(viewer)!.Peek(p) is not null));
    });

    [Fact]
    public Task TheValueOfThePageInViewChangesWhenItsTextArrives() => Sta.Run(async () =>
    {
        var (viewer, host, tab) = Open(3);
        using var _ = tab;
        var told = await Listen(viewer);

        Assert.Null(host.Peek(0));
        await Sta.Until(() => host.Peek(0) is not null);

        Assert.Contains(AutomationEvents.PropertyChanged, told);
    });

    [Fact]
    public Task ASelectionOnAPageThatIsNotLoadedIsToldWhenItsTextComes() => Sta.Run(async () =>
    {
        var (viewer, host, tab) = Open(30);
        using var _ = tab;
        var peer = (PageSurfacePeer)UIElementAutomationPeer.CreatePeerForElement(viewer.Surface);
        var provider = (PageTextProvider)peer.GetPattern(PatternInterface.Text)!;
        host.SetSelection(new Caret(25, 3), new Caret(25, 8));
        var told = await Listen(viewer);

        Assert.Empty(provider.GetSelection());
        await Sta.Until(() => host.Peek(25) is not null);
        await Task.Delay(200);

        Assert.Contains(AutomationEvents.TextPatternOnTextSelectionChanged, told);
        Assert.Equal("lo fr", Assert.Single(provider.GetSelection()).GetText(-1));
    });

    [Fact]
    public Task AResetTellsTextAndStructureAndForgetsTheReadersPlace() => Sta.Run(async () =>
    {
        var (viewer, host, tab) = Open(2);
        using var _ = tab;
        var told = await Listen(viewer);
        host.AutomationCaret = new DocPos(0, 1);
        told.Clear();

        Call(viewer, "Tab_Changed");

        Assert.Null(host.AutomationCaret);
        Assert.Contains(AutomationEvents.StructureChanged, told);
        await Task.Delay(200);
        Assert.Single(told, AutomationEvents.TextPatternOnTextChanged);

        told.Clear();
        viewer.Show(null);

        Assert.Contains(AutomationEvents.StructureChanged, told);
        await Task.Delay(200);
        Assert.Single(told, AutomationEvents.TextPatternOnTextChanged);
    });

    [Fact]
    public Task AChangeOfSelectionIsToldOnceAndSoIsTheReadersOwnPlace() => Sta.Run(async () =>
    {
        var (viewer, host, tab) = Open(2);
        using var _ = tab;
        var told = await Listen(viewer);

        viewer.SelectAll();
        Assert.Single(told, AutomationEvents.TextPatternOnTextSelectionChanged);

        host.AutomationCaret = new DocPos(1, 0);
        Assert.Equal(2, told.Count(e => e == AutomationEvents.TextPatternOnTextSelectionChanged));
    });

    [Fact]
    public Task TheCaretIsToldToAReaderThatListensAndSpokenOtherwise() => Sta.Run(async () =>
    {
        var (viewer, host, tab) = Open(1);
        using var _ = tab;
        await viewer.GetTextAsync(0);
        await viewer.ToggleCaret();
        var told = await Listen(viewer);

        Assert.True(viewer.MoveCaret(Key.Right, false, false));

        Assert.Single(told, AutomationEvents.TextPatternOnTextSelectionChanged);
        Assert.Equal("H", viewer.Speech.Text);

        viewer.Speech.Text = "";
        viewer.Surface.Listening = kind => kind == AutomationEvents.TextPatternOnTextSelectionChanged;
        Assert.True(viewer.MoveCaret(Key.Right, false, false));

        Assert.Equal("", viewer.Speech.Text);
        Assert.Equal(2, told.Count(e => e == AutomationEvents.TextPatternOnTextSelectionChanged));
    });
}
