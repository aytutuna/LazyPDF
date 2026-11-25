using System.Windows;
using LazyPDF.App.Documents;
using LazyPDF.App.Tools;
using LazyPDF.App.Tools.Pages;

namespace LazyPDF.App;

/// <summary>What a page drag does over the tab strip: a tab takes a copy at its end, the empty part makes a new tab. Pages of a tab in another window are not taken.</summary>
internal sealed class TabPageDrop
{
    private readonly IToolHost _host;
    private DocumentTab? _hot;

    public TabPageDrop(IToolHost host) => _host = host;

    /// <summary>The effect for a page drag over <paramref name="under"/>, or over the empty strip when <paramref name="emptyStrip"/> is set. The tab it would copy to is marked.</summary>
    public DragDropEffects Over(IDataObject data, ITab? under, bool emptyStrip)
    {
        Leave();
        if (Payload(data) is not { } payload) return DragDropEffects.None;
        if (emptyStrip) return DragDropEffects.Copy;
        if (under is not DocumentTab tab || ReferenceEquals(tab, payload.Tab)) return DragDropEffects.None;
        tab.PageDropHot = true;
        _hot = tab;
        return DragDropEffects.Copy;
    }

    /// <summary>Starts the copy or the new tab; the work goes on after the drop has returned.</summary>
    public DragDropEffects Drop(IDataObject data, ITab? under, bool emptyStrip)
    {
        var effects = Over(data, under, emptyStrip);
        Leave();
        if (effects == DragDropEffects.None || Payload(data) is not { } payload) return DragDropEffects.None;
        if (emptyStrip) Run(PageTransfer.ToNewTabAsync(payload, _host, files: false));
        else Run(PageTransfer.CopyAsync(payload, (DocumentTab)under!, _host));
        return effects;
    }

    public void Leave()
    {
        if (_hot is null) return;
        _hot.PageDropHot = false;
        _hot = null;
    }

    private PagePayload? Payload(IDataObject data) =>
        data.GetData(PageDrag.Format) is PagePayload payload && _host.OpenDocuments.Contains(payload.Tab) ? payload : null;

    private static async void Run(Task work) => await work;
}
