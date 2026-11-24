using System.ComponentModel;
using System.Windows;
using LazyPDF.App.Documents;
using LazyPDF.App.Tools.Pages;
using Xunit;
using static LazyPDF.App.Tests.PagesKit;

namespace LazyPDF.App.Tests;

// What a page drag does over the tab strip, without a window: the strip's handlers only find the tab under the pointer and call this.
[Collection("Application")]
public sealed class TabPageDropTests
{
    private static (DocumentTab From, DocumentTab To, StageHost Host, TabPageDrop Drop, DataObject Data) Set()
    {
        var from = Open(4, "a.pdf");
        var to = Open(2, "b.pdf");
        var host = new StageHost();
        host.Documents.AddRange([from, to]);
        return (from, to, host, new TabPageDrop(host), new DataObject(PageDrag.Format, new PagePayload(from, [1, 2], from.Revision)));
    }

    [Fact]
    public Task AnotherTabTakesACopyAndIsMarkedUntilTheDragLeaves() => Sta.Run(() =>
    {
        var (from, to, _, drop, data) = Set();
        using var _1 = from;
        using var _2 = to;
        var changed = new List<string?>();
        ((INotifyPropertyChanged)to).PropertyChanged += (_, e) => changed.Add(e.PropertyName);

        Assert.Equal(DragDropEffects.Copy, drop.Over(data, to, emptyStrip: false));
        Assert.True(to.PageDropHot);
        Assert.False(from.PageDropHot);
        drop.Leave();

        Assert.False(to.PageDropHot);
        Assert.Equal([nameof(DocumentTab.PageDropHot), nameof(DocumentTab.PageDropHot)], changed);
        return Task.CompletedTask;
    });

    [Fact]
    public Task HomeAndTheSourceTabTakeNothing() => Sta.Run(() =>
    {
        var (from, to, host, drop, data) = Set();
        using var _1 = from;
        using var _2 = to;

        Assert.Equal(DragDropEffects.None, drop.Over(data, HomeTab.Instance, emptyStrip: false));
        Assert.Equal(DragDropEffects.None, drop.Over(data, from, emptyStrip: false));
        Assert.Equal(DragDropEffects.None, drop.Drop(data, HomeTab.Instance, emptyStrip: false));

        Assert.False(from.PageDropHot);
        Assert.Empty(host.Opened);
        Assert.Equal(2, to.PageCount);
        return Task.CompletedTask;
    });

    [Fact]
    public Task DroppingOnATabCopiesThePagesToItsEnd() => Sta.Run(async () =>
    {
        var (from, to, host, drop, data) = Set();
        using var _1 = from;
        using var _2 = to;
        var fromOrder = Order(from);
        int revision = to.Revision;

        Assert.Equal(DragDropEffects.Copy, drop.Drop(data, to, emptyStrip: false));
        await Sta.Until(() => to.Revision > revision);

        Assert.Equal(4, to.PageCount);
        Assert.Equal(fromOrder[1], TextOf(to, 2));
        Assert.Equal(fromOrder[2], TextOf(to, 3));
        Assert.False(to.PageDropHot);
        Assert.Empty(host.Opened);
    });

    [Fact]
    public Task TheEmptyStripMakesANewTab() => Sta.Run(async () =>
    {
        var (from, to, host, drop, data) = Set();
        using var _1 = from;
        using var _2 = to;

        Assert.Equal(DragDropEffects.Copy, drop.Over(data, null, emptyStrip: true));
        Assert.Equal(DragDropEffects.Copy, drop.Drop(data, null, emptyStrip: true));
        await Sta.Until(() => host.Opened.Count == 1);

        Assert.Equal("a extract.pdf", host.Opened[0]);
        Assert.Empty(host.Notices);
        Assert.Equal(2, to.PageCount);
        Assert.Equal(4, from.PageCount);
    });

    [Fact]
    public Task APageDragFromAnotherWindowOrAnythingElseIsNotTaken() => Sta.Run(() =>
    {
        var (from, to, host, drop, _) = Set();
        using var _1 = from;
        using var _2 = to;
        using var elsewhere = Open(3, "c.pdf");
        var foreign = new DataObject(PageDrag.Format, new PagePayload(elsewhere, [0], elsewhere.Revision));

        Assert.Equal(DragDropEffects.None, drop.Over(foreign, to, emptyStrip: false));
        Assert.Equal(DragDropEffects.None, drop.Over(foreign, null, emptyStrip: true));
        Assert.Equal(DragDropEffects.None, drop.Over(new DataObject(DataFormats.Text, "text"), to, emptyStrip: false));
        Assert.False(to.PageDropHot);
        Assert.Empty(host.Opened);
        return Task.CompletedTask;
    });
}
