using System.Windows;
using System.Windows.Media;
using System.Windows.Automation;
using System.Windows.Automation.Provider;
using LazyPDF.Core;

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
        PageTextRange? range;
        if (host.AutomationCaret is { } placed)
        {
            range = PageTextRange.Create(host, placed, placed, this);
        }
        else
        {
            var selection = host.Selection ?? (host.BrowsingCaret is { } caret ? (caret, caret) : null);
            if (selection is not var (anchor, focus)) return [];
            var units = PageTextRange.Units(host);
            var (first, last) = anchor < focus ? (anchor, focus) : (focus, anchor);
            var (start, missingStart) = units.FromCaret(first);
            var (end, missingEnd) = units.FromCaret(last);
            // An end inside a page that is not loaded has no place yet; the page is asked for and the reader is told when it is there.
            if (missingStart >= 0 || missingEnd >= 0)
            {
                if (missingStart >= 0) host.Peek(missingStart);
                if (missingEnd >= 0) host.Peek(missingEnd);
                return [];
            }
            range = PageTextRange.Create(host, start, end, this);
        }
        return range is null ? [] : [range];
    }

    // The lines in view of every page in view, one range for each page.
    public ITextRangeProvider[] GetVisibleRanges()
    {
        var ranges = new List<ITextRangeProvider>();
        foreach (var (page, matrix) in PagesInView())
        {
            if (host.Peek(page) is not { } text || text.Lines.Count == 0) continue;
            var seen = text.Lines.Where(l => ViewArea(page, matrix, l.Quad) is not null).ToList();
            if (seen.Count == 0) continue;
            var units = PageUiaText.Of(text);
            var range = PageTextRange.Create(host, new DocPos(page, units.OffsetOf(seen[0].Range.Start)), new DocPos(page, units.OffsetOf(seen[^1].Range.End)), this);
            if (range is not null) ranges.Add(range);
        }
        return [.. ranges];
    }

    // The start of the character under the point, or the nearest one when the point is between pages; the range is empty.
    // A page that is not loaded gives the start of the page.
    public ITextRangeProvider? RangeFromPoint(Point screenLocation)
    {
        if (!host.LayoutReady) return null;
        var surface = peer.Surface;
        var point = surface.PointFromScreen(screenLocation);
        if (!new Rect(surface.RenderSize).Contains(point) || surface.Hit(point, nearest: true) is not var (page, at)) return null;
        var pos = new DocPos(page, 0);
        if (host.Peek(page) is { } text)
        {
            var (x, y) = surface.Geometry(page).ToUser(at.X, at.Y);
            if (text.HitTest(x, y) is { } hit) pos = new DocPos(page, PageUiaText.Of(text).OffsetOf(hit.Char));
        }
        return PageTextRange.Create(host, pos, pos, this);
    }

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
        var geometry = peer.Surface.Geometry(link.Page);
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

    /// <summary>The rectangles of the range on the screen (x, y, width and height each), the part of its lines that is in view.</summary>
    public double[] Rectangles(DocPos start, DocPos end)
    {
        var found = new List<double>();
        foreach (var (page, matrix) in PagesInView())
        {
            if (page < start.Page || page > end.Page || (page == end.Page && end.Offset == 0)) continue;
            if (host.Peek(page) is not { } text) continue;
            var (first, last) = Chars(text, start, end, page);
            if (last <= first) continue;
            foreach (var quad in text.Quads(new TextRange(first, last)))
            {
                if (ViewArea(page, matrix, quad) is not { } area) continue;
                var (a, b) = (peer.Surface.PointToScreen(area.TopLeft), peer.Surface.PointToScreen(area.BottomRight));
                found.AddRange([a.X, a.Y, b.X - a.X, b.Y - a.Y]);
            }
        }
        return [.. found];
    }

    /// <summary>Scrolls the first or last part of the range into view; a page whose text is not loaded is shown as a page.</summary>
    public void Reveal(DocPos start, DocPos end, bool alignToTop)
    {
        if (!host.LayoutReady || host.PageCount == 0) return;
        int page = alignToTop ? start.Page : end.Offset == 0 && end.Page > start.Page ? end.Page - 1 : end.Page;
        page = Math.Min(page, host.PageCount - 1);
        if (host.Peek(page) is { } text)
        {
            var (first, last) = Chars(text, start, end, page);
            // An empty range is the character it is in front of.
            if (last <= first) last = Math.Min(first + 1, text.Chars.Count);
            if (last > first && text.Quads(new TextRange(first, last)) is { Count: > 0 } quads)
            {
                peer.Surface.Reveal(page, peer.Surface.QuadArea(page, alignToTop ? quads[0] : quads[^1]));
                return;
            }
        }
        peer.Surface.Reveal(page, new Rect(new Point(0, 0), peer.Surface.PageSize(page)));
    }

    // The characters of one page that the range covers.
    private static (int First, int Last) Chars(TextPage text, DocPos start, DocPos end, int page)
    {
        var units = PageUiaText.Of(text);
        int from = page == start.Page ? start.Offset : 0;
        int to = page == end.Page ? end.Offset : units.Length;
        return (units.CharStart(from), units.CharEnd(to));
    }

    // The pages laid out in the view, with their matrix, once the layout belongs to the text.
    private IEnumerable<(int Page, Matrix Matrix)> PagesInView()
    {
        if (!host.LayoutReady) yield break;
        var surface = peer.Surface;
        foreach (int page in surface.Layout.PagesIn(surface.ViewRect).Order())
            if (surface.PageMatrix(page) is { } matrix) yield return (page, matrix);
    }

    // The part of a text quad that is in the view, in surface coordinates.
    private Rect? ViewArea(int page, Matrix matrix, TextQuad quad)
    {
        var surface = peer.Surface;
        var area = Rect.Intersect(PageSpace.Transform(matrix, surface.QuadArea(page, quad)), new Rect(surface.Viewport));
        return area.IsEmpty ? null : area;
    }
}
