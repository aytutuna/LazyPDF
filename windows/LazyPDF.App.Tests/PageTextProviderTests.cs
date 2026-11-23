using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Automation.Provider;
using System.Windows.Automation.Text;
using System.Windows.Interop;
using LazyPDF.App.Documents;
using LazyPDF.App.Services;
using LazyPDF.App.Viewer;
using LazyPDF.Core;
using Xunit;
using static LazyPDF.App.Tests.TextPdf;

namespace LazyPDF.App.Tests;

// The Text pattern of the page surface, on a real viewer with its pages loaded.
[Collection("Application")]
public sealed class PageTextProviderTests
{
    // Wrapping a peer for a client needs a window the way a client reaches it, so the viewer sits in a bare HwndSource that is asked for its root provider.
    private sealed record Opened(PageViewer Viewer, ITextHost Host, PageSurfacePeer Peer, PageTextProvider Provider, DocumentTab Tab, HwndSource Source) : IDisposable
    {
        public void Dispose()
        {
            Source.Dispose();
            Tab.Dispose();
        }
    }

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern IntPtr SendMessage(IntPtr window, int message, IntPtr wParam, IntPtr lParam);

    private const int WmGetObject = 0x3D;
    private const int UiaRootObjectId = -25;

    private static async Task<Opened> Open(byte[] pdf, IDocumentRenderer? renderer = null)
    {
        var tab = new DocumentTab(PdfEditSession.Open(pdf), renderer ?? new FakeRenderer(), null, "a.pdf");
        var viewer = new PageViewer(null);
        var source = new HwndSource(new HwndSourceParameters("text-test")) { RootVisual = viewer };
        SendMessage(source.Handle, WmGetObject, IntPtr.Zero, new IntPtr(UiaRootObjectId));
        viewer.Show(tab);
        viewer.Measure(new Size(800, 600));
        viewer.Arrange(new Rect(0, 0, 800, 600));
        viewer.UpdateLayout();
        ITextHost host = viewer;
        await Sta.Until(() => Enumerable.Range(0, tab.PageCount).All(p => host.Peek(p) is not null));
        var peer = (PageSurfacePeer)UIElementAutomationPeer.CreatePeerForElement(viewer.Surface);
        return new Opened(viewer, host, peer, (PageTextProvider)peer.GetPattern(PatternInterface.Text)!, tab, source);
    }

    // The display-space area of the characters of a word, as a link over it would have.
    private static Rect AreaOf(Opened o, int page, string word)
    {
        var text = o.Host.Peek(page)!;
        int from = string.Concat(text.Chars.Select(c => c.Text)).IndexOf(word, StringComparison.Ordinal);
        var geometry = o.Viewer.Surface.Geometry(page);
        Rect area = Rect.Empty;
        for (int i = from; i < from + word.Length; i++)
        {
            var q = text.Chars[i].Quad;
            foreach (var (x, y) in new[] { (q.X0, q.Y0), (q.X1, q.Y1), (q.X2, q.Y2), (q.X3, q.Y3) })
            {
                var (dx, dy) = geometry.ToDisplay(x, y);
                area.Union(new Point(dx, dy));
            }
        }
        return area;
    }

    private static LinkTarget Link(Rect area, string name = "Link") => new(area, name, () => { }, () => { });

    [Fact]
    public Task ThePageSurfaceOffersTheTextPatternOnceItHasAHost() => Sta.Run(async () =>
    {
        var bare = new PageSurface();
        Assert.Null(UIElementAutomationPeer.CreatePeerForElement(bare).GetPattern(PatternInterface.Text));

        var o = await Open(Pdfs.Text(2));
        using var _ = o;

        Assert.Same(o.Provider, o.Peer.GetPattern(PatternInterface.Text));
        Assert.Equal(SupportedTextSelection.Single, o.Provider.SupportedTextSelection);
        Assert.Same(o.Peer, o.Peer.PeerOf(o.Provider.Element));
    });

    [Fact]
    public Task TheDocumentRangeHoldsTheTextOfEveryPage() => Sta.Run(async () =>
    {
        var o = await Open(Pdfs.Text(3));
        using var _ = o;

        string text = o.Provider.DocumentRange.GetText(-1);

        Assert.Equal(string.Concat(Enumerable.Range(0, 3).Select(p => PageUiaText.Of(o.Host.Peek(p)!).Text)), text);
        Assert.Contains("Page 3.", text);
    });

    [Fact]
    public Task WithNothingSelectedThereIsNoSelectionRange() => Sta.Run(async () =>
    {
        var o = await Open(Pdfs.Text(2));
        using var _ = o;

        Assert.Empty(o.Provider.GetSelection());
    });

    [Fact]
    public Task SelectAllIsTheWholeDocumentRange() => Sta.Run(async () =>
    {
        var o = await Open(Pdfs.Text(3));
        using var _ = o;

        o.Viewer.SelectAll();

        var selection = Assert.Single(o.Provider.GetSelection());
        var document = o.Provider.DocumentRange;
        Assert.Equal(0, selection.CompareEndpoints(TextPatternRangeEndpoint.Start, document, TextPatternRangeEndpoint.Start));
        Assert.Equal(0, selection.CompareEndpoints(TextPatternRangeEndpoint.End, document, TextPatternRangeEndpoint.End));
        Assert.Equal(document.GetText(-1), selection.GetText(-1));
        var last = document.Clone();
        last.MoveEndpointByUnit(TextPatternRangeEndpoint.Start, TextUnit.Document, 1);
        Assert.Equal(0, selection.CompareEndpoints(TextPatternRangeEndpoint.End, last, TextPatternRangeEndpoint.Start));
    });

    [Fact]
    public Task ASelectionInOnePageIsItsText() => Sta.Run(async () =>
    {
        var o = await Open(Pdfs.Text(2));
        using var _ = o;
        var text = o.Host.Peek(1)!;
        int from = text.Text.IndexOf("tests", StringComparison.Ordinal);
        var held = (ViewerSelection)typeof(PageViewer).GetField("_selection", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)!.GetValue(o.Viewer)!;
        held.Set(new Caret(1, from + 5), new Caret(1, from));

        var selection = Assert.Single(o.Provider.GetSelection());

        Assert.Equal("tests", selection.GetText(-1));
    });

    [Fact]
    public Task ADegenerateSelectKeepsTheReadersPlaceAndTheUsersSelection() => Sta.Run(async () =>
    {
        var o = await Open(Pdfs.Text(3));
        using var _ = o;
        o.Viewer.SelectAll();
        var place = o.Provider.DocumentRange;
        place.MoveEndpointByUnit(TextPatternRangeEndpoint.Start, TextUnit.Page, 1);
        place.MoveEndpointByRange(TextPatternRangeEndpoint.End, place, TextPatternRangeEndpoint.Start);

        place.Select();

        Assert.True(o.Viewer.HasSelection);
        var selection = Assert.Single(o.Provider.GetSelection());
        Assert.Equal("", selection.GetText(-1));
        Assert.Equal(0, selection.CompareEndpoints(TextPatternRangeEndpoint.Start, place, TextPatternRangeEndpoint.Start));

        o.Viewer.ClearSelection();

        Assert.Empty(o.Provider.GetSelection());
    });

    [Fact]
    public Task TheCaretOfCaretBrowsingIsAnEmptyRangeToo() => Sta.Run(async () =>
    {
        var o = await Open(Pdfs.Text(1));
        using var _ = o;

        await o.Viewer.ToggleCaret();

        var caret = Assert.Single(o.Provider.GetSelection());
        Assert.Equal("", caret.GetText(-1));
    });

    [Fact]
    public Task ALinkIsRangeOfItsOwnCharactersAndTheSameElementAsInTheTree() => Sta.Run(async () =>
    {
        var o = await Open(Pdfs.Text(1));
        using var _ = o;
        o.Viewer.Surface.PageLinks = _ => [Link(AreaOf(o, 0, "from"), "From link")];
        o.Peer.LinksChanged();

        var child = Assert.Single(o.Peer.GetChildren());
        var element = o.Peer.ProviderOf(child);
        var range = o.Provider.RangeFromChild(element);

        Assert.Equal("from", range.GetText(-1));
        Assert.Same(child, o.Peer.PeerOf(Assert.Single(range.GetChildren())));
        Assert.Equal(((IRawElementProviderFragment)element).GetRuntimeId(), ((IRawElementProviderFragment)range.GetChildren()[0]).GetRuntimeId());
        Assert.Same(child, o.Peer.PeerOf(Assert.Single(o.Provider.DocumentRange.GetChildren())));
        Assert.Empty(PageRange(o, "Hello").GetChildren());
        Assert.Same(o.Peer, o.Peer.PeerOf(range.GetEnclosingElement()));
    });

    private static ITextRangeProvider PageRange(Opened o, string word)
    {
        var range = o.Provider.DocumentRange;
        range.MoveEndpointByRange(TextPatternRangeEndpoint.End, range, TextPatternRangeEndpoint.Start);
        range.ExpandToEnclosingUnit(TextUnit.Word);
        Assert.StartsWith(word, range.GetText(-1));
        return range;
    }

    [Fact]
    public Task TheLinkPeersStayTheSameUntilTheLinksChange() => Sta.Run(async () =>
    {
        var o = await Open(Pdfs.Text(1));
        using var _ = o;
        o.Viewer.Surface.PageLinks = _ => [Link(AreaOf(o, 0, "from"))];
        o.Peer.LinksChanged();
        var first = Assert.Single(o.Peer.GetChildren());

        Assert.Same(first, Assert.Single(o.Peer.LinkPeers()));
        o.Peer.LinksChanged();

        Assert.NotSame(first, Assert.Single(o.Peer.GetChildren()));
    });

    [Fact]
    public Task AnElementThatIsNotALinkIsRefused() => Sta.Run(async () =>
    {
        var o = await Open(Pdfs.Text(1));
        using var _ = o;

        Assert.Throws<ArgumentException>(() => o.Provider.RangeFromChild(o.Provider.Element));
    });

    [Theory]
    [InlineData("/Rotate 90 /CropBox [100 100 500 700]")]
    [InlineData("/Rotate 270 /CropBox [100 100 500 700]")]
    [InlineData("/Rotate 180 /CropBox [50 60 450 760] /UserUnit 1")]
    public Task ALinkOnARotatedCroppedPageIsItsOwnCharacters(string entries) => Sta.Run(async () =>
    {
        var o = await Open(Pdf(entries, [Line(150, 500, "alpha beta gamma") + Line(150, 300, "delta")]));
        using var _ = o;
        o.Viewer.Surface.PageLinks = _ => [Link(AreaOf(o, 0, "beta")), Link(AreaOf(o, 0, "delta"))];
        o.Peer.LinksChanged();
        var children = o.Peer.GetChildren();

        Assert.Equal("beta", o.Provider.RangeFromChild(o.Peer.ProviderOf(children[0])).GetText(-1));
        Assert.Equal("delta", o.Provider.RangeFromChild(o.Peer.ProviderOf(children[1])).GetText(-1));
    });

    [Fact]
    public Task AChildOfALinkFollowsTheRangeThatCoversIt() => Sta.Run(async () =>
    {
        var o = await Open(Pdfs.Text(1));
        using var _ = o;
        o.Viewer.Surface.PageLinks = _ => [Link(AreaOf(o, 0, "from"))];
        o.Peer.LinksChanged();
        var range = o.Provider.DocumentRange;
        range.ExpandToEnclosingUnit(TextUnit.Character);
        Assert.Empty(range.GetChildren());

        range.MoveEndpointByUnit(TextPatternRangeEndpoint.End, TextUnit.Word, 3);

        Assert.Single(range.GetChildren());
    });

    [Fact]
    public Task ARangeMadeBetweenTheChangeAndTheDrawingOfATabStaysValid() => Sta.Run(async () =>
    {
        var renderer = new SlowRenderer();
        using var o = await Open(Pdfs.Text(2), renderer);
        var before = o.Provider.DocumentRange;
        var drawn = new TaskCompletionSource();
        o.Tab.Drawn += (_, _) => drawn.TrySetResult();
        renderer.Gate = new TaskCompletionSource();

        o.Tab.Refresh();
        var between = o.Provider.DocumentRange;

        Assert.False(o.Host.LayoutReady);
        Assert.Throws<ElementNotAvailableException>(() => before.GetText(-1));
        Assert.Equal("", between.GetText(-1));
        renderer.Gate.SetResult();
        await drawn.Task;
        await Sta.Until(() => o.Host.LayoutReady);
        Assert.Equal(new DocPos(2, 0), ((PageTextRange)between).Places.End);
        await Sta.Until(() => o.Host.Peek(1) is not null);
        Assert.Contains("Page 2.", between.GetText(-1));
        Assert.Throws<ElementNotAvailableException>(() => before.Clone());
    });

    // A renderer whose load waits for the gate once one is set, so a test can stand between a tab's change and its drawing.
    private sealed class SlowRenderer : IDocumentRenderer
    {
        private readonly FakeRenderer _inner = new();

        public TaskCompletionSource? Gate { get; set; }

        public bool Load(PdfEditSession session, string? password) => _inner.Load(session, password);

        public async Task<bool> LoadAsync(PdfEditSession session, string? password)
        {
            if (Gate is { } gate) await gate.Task;
            return _inner.Load(session, password);
        }

        public (double Width, double Height) PageSize(int pageIndex) => _inner.PageSize(pageIndex);

        public PdfRgbaImage? Render(int pageIndex, double dpi) => _inner.Render(pageIndex, dpi);

        public void Dispose() => _inner.Dispose();
    }
}
