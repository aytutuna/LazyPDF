using System.Windows;

namespace LazyPDF.App.Viewer;

/// <param name="Columns">1, or 2 for facing pages.</param>
/// <param name="Cover">With two columns, page 1 sits alone on the right so the next two face each other.</param>
/// <param name="Continuous">All spreads in one scroll; otherwise only one spread is laid out.</param>
/// <param name="Rotation">The viewer's rotation, 0, 90, 180 or 270.</param>
/// <param name="Scale">Device independent pixels per point.</param>
/// <param name="Viewport">What the layout centres in when it is smaller.</param>
/// <param name="PixelsPerDip">Sizes and positions are rounded to whole device pixels so tiles meet exactly.</param>
public sealed record LayoutOptions(int Columns, bool Cover, bool Continuous, int Rotation, double Scale, Size Viewport, double PixelsPerDip = 1);

/// <summary>
/// Where every page of a document sits in the scrolled area: spreads (one page, or two facing) one under the
/// other, each centred. Pure arithmetic over the page sizes, so it is cheap to rebuild on every zoom.
/// </summary>
public sealed class ViewLayout
{
    public const double Margin = 16;
    public const double Gap = 12;

    private readonly Rect[] _rects;
    private readonly double[] _tops;
    private readonly int _firstSpread;
    private readonly int _firstPage;

    private ViewLayout(LayoutOptions options, int pageCount, int firstSpread, int firstPage, Rect[] rects, double[] tops, Size extent)
    {
        Options = options;
        PageCount = pageCount;
        _firstSpread = firstSpread;
        _firstPage = firstPage;
        _rects = rects;
        _tops = tops;
        Extent = extent;
    }

    public LayoutOptions Options { get; }

    public int PageCount { get; }

    /// <summary>The size of the scrolled area.</summary>
    public Size Extent { get; }

    public int SpreadCount => SpreadsOf(Options.Columns, Options.Cover, PageCount);

    /// <summary>The spread laid out first; the only one unless the layout is continuous.</summary>
    public int FirstSpread => _firstSpread;

    public int LastSpread => _firstSpread + _tops.Length - 1;

    public static int SpreadsOf(int columns, bool cover, int pages) =>
        columns < 2 ? pages : cover ? 1 + pages / 2 : (pages + 1) / 2;

    public static int SpreadOf(int columns, bool cover, int page) =>
        columns < 2 ? page : cover ? (page + 1) / 2 : page / 2;

    /// <summary>The pages of a spread, in reading order.</summary>
    public static (int First, int Last) PagesOf(int columns, bool cover, int spread, int pages)
    {
        int first = columns < 2 ? spread : cover ? (spread == 0 ? 0 : 2 * spread - 1) : 2 * spread;
        int count = columns < 2 || (cover && spread == 0) ? 1 : 2;
        return (first, Math.Min(first + count, pages) - 1);
    }

    /// <summary>Lays out <paramref name="pages"/> (sizes in points, as shown before rotating). In a paged layout only <paramref name="spread"/> is placed.</summary>
    public static ViewLayout Build(IReadOnlyList<Size> pages, LayoutOptions options, int spread = 0)
    {
        int columns = options.Columns < 2 ? 1 : 2;
        var o = options with { Columns = columns };
        int spreads = SpreadsOf(columns, o.Cover, pages.Count);
        if (spreads == 0) return new ViewLayout(o, 0, 0, 0, [], [], o.Viewport);
        int first = o.Continuous ? 0 : Math.Clamp(spread, 0, spreads - 1);
        int last = o.Continuous ? spreads - 1 : first;
        int firstPage = PagesOf(columns, o.Cover, first, pages.Count).First;
        int lastPage = PagesOf(columns, o.Cover, last, pages.Count).Last;

        double ppd = Math.Max(o.PixelsPerDip, 1e-6);
        double Snap(double v) => Math.Round(v * ppd) / ppd;
        var sizes = new Size[lastPage - firstPage + 1];
        double widest = 0;
        for (int p = firstPage; p <= lastPage; p++)
        {
            var shown = PageSpace.Shown(pages[p], o.Rotation, o.Scale);
            sizes[p - firstPage] = new Size(Snap(shown.Width), Snap(shown.Height));
        }
        var widths = new double[last - first + 1];
        var heights = new double[widths.Length];
        for (int s = first; s <= last; s++)
        {
            var (a, b) = PagesOf(columns, o.Cover, s, pages.Count);
            double w = 0, h = 0;
            for (int p = a; p <= b; p++)
            {
                w += sizes[p - firstPage].Width;
                h = Math.Max(h, sizes[p - firstPage].Height);
            }
            if (columns == 2) w = b > a ? w + Gap : 2 * w + Gap;
            widths[s - first] = w;
            heights[s - first] = h;
            widest = Math.Max(widest, w);
        }

        double width = Math.Max(o.Viewport.Width, widest + 2 * Margin);
        double total = 2 * Margin + heights.Sum() + Gap * (heights.Length - 1);
        double height = o.Continuous ? total : Math.Max(o.Viewport.Height, total);
        double y = o.Continuous ? Margin : Snap((height - total) / 2) + Margin;
        var rects = new Rect[sizes.Length];
        var tops = new double[widths.Length];
        for (int s = first; s <= last; s++)
        {
            var (a, b) = PagesOf(columns, o.Cover, s, pages.Count);
            double x = Snap((width - widths[s - first]) / 2);
            if (columns == 2 && b == a)
            {
                // A lone page keeps the place it would have in a pair: the cover on the right, the last page on the left.
                if (o.Cover && s == 0) x += sizes[a - firstPage].Width + Gap;
            }
            for (int p = a; p <= b; p++)
            {
                var size = sizes[p - firstPage];
                rects[p - firstPage] = new Rect(x, Snap(y + (heights[s - first] - size.Height) / 2), size.Width, size.Height);
                x += size.Width + Gap;
            }
            tops[s - first] = y;
            y += heights[s - first] + Gap;
        }
        return new ViewLayout(o, pages.Count, first, firstPage, rects, tops, new Size(width, height));
    }

    /// <summary>Where a page is in the scrolled area; empty for a page the layout does not place.</summary>
    public Rect PageRect(int page) => (uint)(page - _firstPage) < (uint)_rects.Length ? _rects[page - _firstPage] : Rect.Empty;

    public bool Contains(int page) => (uint)(page - _firstPage) < (uint)_rects.Length;

    /// <summary>The pages whose rectangles meet <paramref name="area"/>, in order.</summary>
    public IEnumerable<int> PagesIn(Rect area)
    {
        if (_tops.Length == 0) yield break;
        int spread = SpreadAt(area.Top);
        for (; spread <= LastSpread && _tops[spread - _firstSpread] <= area.Bottom; spread++)
        {
            var (a, b) = PagesOf(Options.Columns, Options.Cover, spread, PageCount);
            for (int p = a; p <= b; p++)
            {
                if (_rects[p - _firstPage].IntersectsWith(area)) yield return p;
            }
        }
    }

    /// <summary>The page under a point of the scrolled area, or -1.</summary>
    public int PageAt(Point point)
    {
        foreach (int p in PagesIn(new Rect(point, new Size(0, 0))))
        {
            if (_rects[p - _firstPage].Contains(point)) return p;
        }
        return -1;
    }

    /// <summary>The page nearest to a point: the one under it, else the one whose rectangle is closest.</summary>
    public int NearestPage(Point point)
    {
        if (_rects.Length == 0) return -1;
        int spread = SpreadAt(point.Y);
        var (a, b) = PagesOf(Options.Columns, Options.Cover, spread, PageCount);
        int best = a;
        double bestDistance = double.MaxValue;
        for (int p = a; p <= b; p++)
        {
            var rect = _rects[p - _firstPage];
            double dx = Math.Max(0, Math.Max(rect.Left - point.X, point.X - rect.Right));
            double dy = Math.Max(0, Math.Max(rect.Top - point.Y, point.Y - rect.Bottom));
            double distance = dx * dx + dy * dy;
            if (distance < bestDistance)
            {
                bestDistance = distance;
                best = p;
            }
        }
        return best;
    }

    /// <summary>The page with the most of its area in <paramref name="view"/>; the first of equals.</summary>
    public int MostVisible(Rect view)
    {
        int best = -1;
        double bestArea = -1;
        foreach (int p in PagesIn(view))
        {
            var seen = Rect.Intersect(_rects[p - _firstPage], view);
            double area = seen.IsEmpty ? 0 : seen.Width * seen.Height;
            if (area > bestArea)
            {
                bestArea = area;
                best = p;
            }
        }
        return best >= 0 ? best : NearestPage(new Point(view.Left + view.Width / 2, view.Top + view.Height / 2));
    }

    /// <summary>The top of a spread in the scrolled area.</summary>
    public double SpreadTop(int spread) => _tops[Math.Clamp(spread, _firstSpread, LastSpread) - _firstSpread];

    private int SpreadAt(double y)
    {
        int lo = 0, hi = _tops.Length - 1;
        while (lo < hi)
        {
            int mid = (lo + hi + 1) / 2;
            if (_tops[mid] - Gap / 2 <= y) lo = mid;
            else hi = mid - 1;
        }
        return _firstSpread + lo;
    }
}
