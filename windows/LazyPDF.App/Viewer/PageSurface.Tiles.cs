using System.Windows;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using LazyPDF.App.Services;
using LazyPDF.Core;

namespace LazyPDF.App.Viewer;

// The pictures of the pages: which tiles the window needs, who draws them, and where they are kept.
internal sealed partial class PageSurface
{
    private const long CacheBudget = 192L * 1024 * 1024;
    private const int MaxWanted = 96;

    private readonly TileCache _cache = new(CacheBudget);
    private readonly HashSet<TileKey> _failed = [];
    private readonly DispatcherTimer _settle = new(DispatcherPriority.Background) { Interval = TimeSpan.FromMilliseconds(140) };
    private WindowsPageRenderer? _renderer;
    private WindowsPageRenderer? _display;
    private TileScheduler? _scheduler;
    private byte[]? _bytes;
    private int[] _versions = [];
    private int[] _pageObjects = [];
    private int _nextVersion;
    private int _generation;
    private bool _planQueued;
    private bool _settling;

    private WindowsPageRenderer? Active => _display ?? _renderer;

    /// <summary>Tiles waiting or being drawn.</summary>
    public int TilesPending => _scheduler?.Pending ?? 0;

    public long CacheBytes => _cache.Bytes;

    /// <summary>The number that names the content of a page's pictures; it changes only when an edit touched the page.</summary>
    public int VersionOf(int page) => _versions[page];

    private void InitTiles()
    {
        _settle.Tick += (_, _) =>
        {
            _settle.Stop();
            _settling = false;
            _failed.RemoveWhere(key => !key.IsPreview);
            PlanTiles();
        };
        NewScheduler();
    }

    private void NewScheduler()
    {
        _scheduler?.Dispose();
        int generation = ++_generation;
        _scheduler = new TileScheduler(DrawAsync, (spec, image) => Deliver(generation, spec, image));
    }

    // A new document or a tab switch: nothing drawn for the old one may land in the new one.
    private void ResetTiles()
    {
        NewScheduler();
        _cache.Clear();
        _failed.Clear();
        _settling = false;
        _settle.Stop();
    }

    /// <summary>Draws the pages from <paramref name="renderer"/> instead of the tab's (the layers panel makes one from a display copy); null goes back to the tab's.</summary>
    public void SetDisplay(WindowsPageRenderer? renderer)
    {
        _display = renderer;
        for (int i = 0; i < _versions.Length; i++) _versions[i] = ++_nextVersion;
        _failed.Clear();
        InvalidateVisual();
        ScheduleTiles();
    }

    private Task<PdfRgbaImage?> DrawAsync(TileSpec spec)
    {
        if (Active is not { } renderer) return Task.FromResult<PdfRgbaImage?>(null);
        var key = spec.Key;
        return key.IsPreview
            ? renderer.RenderAsync(key.Page, key.Scale * 72)
            : renderer.RenderTileAsync(key.Page, key.Scale, spec.X, spec.Y, spec.Width, spec.Height);
    }

    // On a worker thread: the pixels become a bitmap here so the UI thread only has to file it.
    private void Deliver(int generation, TileSpec spec, PdfRgbaImage? image)
    {
        BitmapSource? bitmap = null;
        try
        {
            if (image is not null) bitmap = PageTints.ToBitmap(image, spec.Key.Tint);
        }
        catch (OutOfMemoryException)
        {
            // Left as a page that could not be drawn.
        }
        Dispatcher.InvokeAsync(() =>
        {
            if (generation != _generation) return;
            if (bitmap is null) _failed.Add(spec.Key);
            else _cache.Add(spec.Key, bitmap);
            InvalidateVisual();
        }, DispatcherPriority.Input);
    }

    private void NoteZoomChange()
    {
        if (_cache.Count == 0) return;
        _settling = true;
        _settle.Stop();
        _settle.Start();
    }

    private void ScheduleTiles()
    {
        if (_planQueued) return;
        _planQueued = true;
        Dispatcher.InvokeAsync(PlanTiles, DispatcherPriority.Background);
    }

    // Asks for whatever of the pages near the window is not drawn yet: first the previews of what is in view, then its tiles,
    // then the previews and tiles around it.
    private void PlanTiles()
    {
        _planQueued = false;
        if (_scheduler is null || _layout.PageCount == 0 || Active is null) return;
        double ppp = Scale * Dpi;
        var view = ViewRect;
        var near = Rect.Inflate(view, view.Width * 0.5, view.Height);
        var far = Rect.Inflate(view, view.Width, view.Height * 2);
        var center = new Point(view.Left + view.Width / 2, view.Top + view.Height / 2);
        var wanted = new List<(TileSpec, double)>();
        foreach (int page in _layout.PagesIn(far))
        {
            var rect = _layout.PageRect(page);
            var preview = TilePlan.Preview(page, _versions[page], _tint, _sizes[page]);
            if (!_cache.Contains(preview.Key) && !_failed.Contains(preview.Key))
                wanted.Add((preview, (rect.IntersectsWith(view) ? 0 : 2e6) + Distance(rect, center)));
            if (_settling || ppp <= preview.Key.Scale || !rect.IntersectsWith(near)) continue;
            foreach (var tile in Required(page, Rect.Intersect(rect, near)))
            {
                if (_cache.Contains(tile.Key) || _failed.Contains(tile.Key)) continue;
                var box = ContentRect(page, tile);
                wanted.Add((tile, (box.IntersectsWith(view) ? 1e6 : 3e6) + Distance(box, center)));
            }
        }
        if (wanted.Count > MaxWanted) wanted = [.. wanted.OrderBy(w => w.Item2).Take(MaxWanted)];
        _scheduler.Want(wanted);
    }

    private static double Distance(Rect rect, Point from) =>
        Math.Abs(rect.Left + rect.Width / 2 - from.X) + Math.Abs(rect.Top + rect.Height / 2 - from.Y);

    // The tiles of a page at the current zoom that cover a part of it given in the scrolled area's coordinates.
    private List<TileSpec> Required(int page, Rect contentArea)
    {
        double ppp = Scale * Dpi;
        var points = PageSpace.Transform(PageSpace.ToPage(ContentMatrix(page)), contentArea);
        var pixels = new Rect(points.X * ppp, points.Y * ppp, points.Width * ppp, points.Height * ppp);
        return TilePlan.Cover(page, _versions[page], _tint, _sizes[page], ppp, pixels, WindowsPageRenderer.Reachable);
    }

    private Rect ContentRect(int page, TileSpec tile) =>
        PageSpace.Transform(ContentMatrix(page), TilePlan.PointsRect(tile, tile.Width, tile.Height));
}
