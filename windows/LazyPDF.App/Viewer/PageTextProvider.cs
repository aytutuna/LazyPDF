using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Provider;

namespace LazyPDF.App.Viewer;

/// <summary>The Text pattern of the page surface: the whole document as one range, the selection, and the ranges of its links.</summary>
internal sealed class PageTextProvider(PageSurfacePeer peer, ITextHost host) : ITextProvider
{
    public ITextHost Host => host;

    /// <summary>The surface's own element, which every range of the document is in.</summary>
    public IRawElementProviderSimple Element => peer.ProviderOf(peer);

    public ITextRangeProvider DocumentRange =>
        PageTextRange.Create(host, new DocPos(0, 0), new DocPos(host.PageCount, 0), this) ?? throw new ElementNotAvailableException();

    public SupportedTextSelection SupportedTextSelection => SupportedTextSelection.Single;

    // WPF has no ITextProvider2, so the caret reaches a reader only as a range without text.
    public ITextRangeProvider[] GetSelection()
    {
        (Caret Anchor, Caret Focus)? selection = host.AutomationCaret is { } placed ? (placed, placed)
            : host.Selection ?? (host.BrowsingCaret is { } caret ? (caret, caret) : null);
        if (selection is not var (anchor, focus)) return [];
        var units = PageTextRange.Units(host);
        var (first, last) = anchor < focus ? (anchor, focus) : (focus, anchor);
        var range = PageTextRange.Create(host, units.FromCaret(first).Pos, units.FromCaret(last).Pos, this);
        return range is null ? [] : [range];
    }

    // TODO: both come with the geometry step.
    public ITextRangeProvider[] GetVisibleRanges() => [];

    public ITextRangeProvider? RangeFromPoint(Point screenLocation) => null;

    public ITextRangeProvider RangeFromChild(IRawElementProviderSimple childElement)
    {
        if (peer.PeerOf(childElement) is not LinkPeer link) throw new ArgumentException("Not a link of this document.", nameof(childElement));
        var (start, end) = SpanOf(link) ?? (new DocPos(link.Page, 0), new DocPos(link.Page, 0));
        return PageTextRange.Create(host, start, end, this) ?? throw new ElementNotAvailableException();
    }

    /// <summary>The links in view whose text overlaps the stretch, as the elements of the tree.</summary>
    public IRawElementProviderSimple[] ChildrenIn(DocPos start, DocPos end)
    {
        var found = new List<IRawElementProviderSimple>();
        foreach (var link in peer.LinkPeers())
        {
            if (link.Page < start.Page || link.Page > end.Page || SpanOf(link) is not var (from, to)) continue;
            bool overlaps = start == end ? from <= start && start < to : from < end && start < to;
            if (overlaps) found.Add(peer.ProviderOf(link));
        }
        return [.. found];
    }

    // The characters whose centers are inside the link's area, which is in display space like the geometry of the page.
    private (DocPos Start, DocPos End)? SpanOf(LinkPeer link)
    {
        if (host.Peek(link.Page) is not { } page) return null;
        var geometry = peer.Geometry(link.Page);
        int first = -1, last = -1;
        for (int i = 0; i < page.Chars.Count; i++)
        {
            var c = page.Chars[i];
            if (c.Text.Length == 0 || c.IsSpace || c.Text == "­") continue;
            var (x, y) = geometry.ToDisplay(c.Quad.Center.X, c.Quad.Center.Y);
            if (!link.Target.Area.Contains(x, y)) continue;
            if (first < 0) first = i;
            last = i;
        }
        if (first < 0) return null;
        var text = PageUiaText.Of(page);
        return (new DocPos(link.Page, text.OffsetOf(first)), new DocPos(link.Page, text.OffsetOf(last) + page.Chars[last].Text.Length));
    }
}
