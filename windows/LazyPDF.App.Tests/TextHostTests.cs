using System.Diagnostics;
using System.Reflection;
using System.Windows;
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
}
