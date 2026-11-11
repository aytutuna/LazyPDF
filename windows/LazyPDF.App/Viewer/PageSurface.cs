using System.Windows;
using System.Windows.Automation.Peers;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using LazyPDF.App.Documents;
using LazyPDF.App.Services;
using LazyPDF.Core;

namespace LazyPDF.App.Viewer;

/// <summary>How the zoom follows the size of the window.</summary>
public enum FitMode
{
    None,
    Width,
    Page,
}

/// <summary>A link of a page for screen readers: where it is on the page, its name, and what following and focusing it do.</summary>
internal readonly record struct LinkTarget(Rect Area, string Name, Action Follow, Action Focus);

/// <summary>
/// The pages of a document in a scrolled area: it lays them out, scrolls, zooms and draws them, and keeps only
/// what is near the window alive (the tiles in <see cref="TileCache"/>, the overlays in the tree). This file is the
/// layout and the scrolling; drawing is in PageSurface.Draw.cs and the pictures in PageSurface.Tiles.cs.
/// </summary>
internal sealed partial class PageSurface : Panel, IScrollInfo
{
    private const double LineStep = 48;

    private DocumentTab? _tab;
    private Size[] _sizes = [];
    private ViewLayout _layout = ViewLayout.Build([], new LayoutOptions(1, false, true, 0, 1, new Size(0, 0)));
    private Size _viewport;
    private double _offsetX, _offsetY;
    private long _lastWheel;
    private double _zoom = 1;
    private FitMode _fit;
    private int _rotation;
    private int _columns = 1;
    private bool _cover;
    private bool _continuous = true;
    private PageTint _tint;
    private int _page;
    private bool _pinned;

    public PageSurface()
    {
        Focusable = true;
        ClipToBounds = true;
        SnapsToDevicePixels = true;
        IsManipulationEnabled = true;
        InitTiles();
    }

    /// <summary>The scroll position or the layout changed: overlays and tools place themselves again.</summary>
    public event EventHandler? ViewChanged;

    /// <summary>The page in view changed, by scrolling or by going to one.</summary>
    public event EventHandler? PageChanged;

    /// <summary>The zoom, the rotation or the arrangement changed.</summary>
    public event EventHandler? OptionsChanged;

    /// <summary>The text of a page for screen readers, if the viewer has it.</summary>
    public Func<int, string?>? PageText { get; set; }

    /// <summary>The label of a page (i, ii, 1) for screen readers.</summary>
    public Func<int, string>? PageLabel { get; set; }

    /// <summary>The links of a page for screen readers, in page space.</summary>
    public Func<int, IReadOnlyList<LinkTarget>>? PageLinks { get; set; }

    public int PageCount => _sizes.Length;

    public double Zoom => _zoom;

    public FitMode Fit => _fit;

    public int Rotation => _rotation;

    public int Columns => _columns;

    public bool Cover => _cover;

    public bool Continuous => _continuous;

    public PageTint Tint => _tint;

    public int CurrentPage => _page;

    public ViewLayout Layout => _layout;

    public Size Viewport => _viewport;

    /// <summary>The part of the scrolled area in view.</summary>
    public Rect ViewRect => new(_offsetX, _offsetY, _viewport.Width, _viewport.Height);

    /// <summary>The page size in points as it is shown before rotating.</summary>
    public Size PageSize(int page) => (uint)page < (uint)_sizes.Length ? _sizes[page] : new Size(0, 0);

    private double Dpi => VisualTreeHelper.GetDpi(this).DpiScaleX;

    private double Scale => _zoom * PageSpace.DipPerPoint;

    /// <summary>The zoom range for this document.</summary>
    public (double Min, double Max) ZoomLimits => ZoomMath.Limits(_sizes.Length == 0 ? 792 : _sizes.Max(s => Math.Max(s.Width, s.Height)), Dpi);

    // ----- Showing a document

    public void Show(DocumentTab? tab, int rotation = 0)
    {
        ResetTiles();
        _rotation = PageSpace.NormalizeRotation(rotation);
        _tab = tab;
        _renderer = tab?.Renderer as WindowsPageRenderer;
        _display = null;
        _bytes = null;
        _geometry.Clear();
        ClearOverlays();
        _offsetX = _offsetY = 0;
        _sizes = tab is null ? [] : ReadSizes(tab);
        _versions = new int[_sizes.Length];
        _pageObjects = tab is null ? [] : PageObjects(tab);
        _bytes = tab is null ? null : Bytes(tab);
        _page = tab is null ? 0 : Math.Clamp(tab.PageIndex, 0, Math.Max(0, _sizes.Length - 1));
        _pinned = true;
        if (tab is not null)
        {
            var limits = ZoomLimits;
            if (tab.Fit == FitMode.None && tab.Zoom > 0)
            {
                _fit = FitMode.None;
                _zoom = ZoomMath.Clamp(tab.Zoom, limits);
            }
            else
            {
                _fit = tab.Fit == FitMode.None ? FitMode.Width : tab.Fit;
                _zoom = _viewport.Width > 0 && _sizes.Length > 0 ? ZoomMath.Clamp(FitZoom(), limits) : 1;
            }
        }
        Rebuild(null, new Point(0, 0), null);
        GoToPage(_page);
        PageChanged?.Invoke(this, EventArgs.Empty);
        OptionsChanged?.Invoke(this, EventArgs.Empty);
        TellLinks();
    }

    internal static byte[] Bytes(DocumentTab tab) =>
        System.Runtime.InteropServices.MemoryMarshal.TryGetArray(tab.Session.Current, out var segment) && segment.Offset == 0 && segment.Count == segment.Array!.Length
            ? segment.Array
            : tab.Session.Current.ToArray();

    private static int[] PageObjects(DocumentTab tab) => [.. tab.Document.Pages.Select(p => p.Reference.Number)];

    // The renderer's sizes, or the engine's when the system cannot draw the file.
    private static Size[] ReadSizes(DocumentTab tab)
    {
        var pages = tab.Document.Pages;
        var sizes = new Size[pages.Count];
        for (int i = 0; i < sizes.Length; i++)
        {
            var (w, h) = tab.CanDraw ? tab.Renderer.PageSize(i) : (0, 0);
            if (w <= 0 || h <= 0)
            {
                var geometry = new PageGeometry(pages[i]);
                (w, h) = (geometry.Width, geometry.Height);
            }
            sizes[i] = new Size(w, h);
        }
        return sizes;
    }

    /// <summary>
    /// The file's bytes changed. The scroll position stays on what it was on, and only pages the change can have
    /// touched (RevisionDiff) get new pictures.
    /// </summary>
    public void Reload()
    {
        if (_tab is not { } tab) return;
        var anchor = AnchorAt(new Point(0, 0));
        var before = _bytes;
        _bytes = Bytes(tab);
        var changed = before is null ? null : RevisionDiff.Changed(before, _bytes);
        var objects = PageObjects(tab);
        var sizes = ReadSizes(tab);
        _geometry.Clear();
        var versions = new int[sizes.Length];
        var near = _layout.PageCount == 0 ? [] : _layout.PagesIn(Rect.Inflate(ViewRect, ViewRect.Width, ViewRect.Height * 2)).ToHashSet();
        for (int i = 0; i < versions.Length; i++)
        {
            bool same = changed is not null && i < _pageObjects.Length && _pageObjects[i] == objects[i]
                && near.Contains(i) && !RevisionDiff.Touches(tab.Document, tab.Document.Pages[i], changed);
            versions[i] = same ? _versions[i] : ++_nextVersion;
        }
        _pageObjects = objects;
        _versions = versions;
        _sizes = sizes;
        SyncOverlays();
        _page = Math.Clamp(_page, 0, Math.Max(0, sizes.Length - 1));
        if (_fit != FitMode.None) _zoom = FitZoom();
        _zoom = ZoomMath.Clamp(_zoom, ZoomLimits);
        _failed.Clear();
        Rebuild(null, new Point(0, 0), anchor);
        PageChanged?.Invoke(this, EventArgs.Empty);
        OptionsChanged?.Invoke(this, EventArgs.Empty);
        TellLinks();
    }

    // ----- Options

    public void SetZoom(double zoom, Point? around = null)
    {
        _fit = FitMode.None;
        ChangeZoom(zoom, around);
    }

    private void ChangeZoom(double zoom, Point? around)
    {
        zoom = ZoomMath.Clamp(zoom, ZoomLimits);
        if (Math.Abs(zoom - _zoom) < 1e-9 && _fit == FitMode.None) return;
        var point = around ?? new Point(_viewport.Width / 2, _viewport.Height / 2);
        var anchor = AnchorAt(point);
        _zoom = zoom;
        Rebuild(null, point, anchor);
        NoteZoomChange();
        OptionsChanged?.Invoke(this, EventArgs.Empty);
    }

    public void SetFit(FitMode fit)
    {
        _fit = fit;
        if (fit == FitMode.None) return;
        var anchor = AnchorAt(new Point(0, 0));
        _zoom = ZoomMath.Clamp(FitZoom(), ZoomLimits);
        Rebuild(null, new Point(0, 0), anchor);
        if (!_continuous || fit == FitMode.Page) GoToPage(_page);
        NoteZoomChange();
        OptionsChanged?.Invoke(this, EventArgs.Empty);
    }

    public void SetArrangement(int columns, bool cover, bool continuous)
    {
        columns = columns < 2 ? 1 : 2;
        if (columns == _columns && cover == _cover && continuous == _continuous) return;
        _columns = columns;
        _cover = cover;
        _continuous = continuous;
        if (_fit != FitMode.None) _zoom = ZoomMath.Clamp(FitZoom(), ZoomLimits);
        Rebuild(null, new Point(0, 0), null);
        GoToPage(_page);
        OptionsChanged?.Invoke(this, EventArgs.Empty);
    }

    public void SetRotation(int degrees)
    {
        degrees = PageSpace.NormalizeRotation(degrees);
        if (degrees == _rotation) return;
        var anchor = AnchorAt(new Point(0, 0));
        _rotation = degrees;
        if (_fit != FitMode.None) _zoom = ZoomMath.Clamp(FitZoom(), ZoomLimits);
        Rebuild(null, new Point(0, 0), anchor);
        OptionsChanged?.Invoke(this, EventArgs.Empty);
    }

    public void SetTint(PageTint tint)
    {
        if (tint == _tint) return;
        _tint = tint;
        _cache.Clear();
        _failed.Clear();
        InvalidateVisual();
        ScheduleTiles();
        OptionsChanged?.Invoke(this, EventArgs.Empty);
    }

    // The zoom that fits the current spread, from the sizes of its pages as they are shown.
    private double FitZoom()
    {
        if (_sizes.Length == 0) return _zoom;
        var (first, last) = ViewLayout.PagesOf(_columns, _cover, ViewLayout.SpreadOf(_columns, _cover, _page), _sizes.Length);
        double width = 0, height = 0;
        for (int p = first; p <= last; p++)
        {
            var shown = PageSpace.Shown(_sizes[p], _rotation, 1);
            width += shown.Width;
            height = Math.Max(height, shown.Height);
        }
        if (_columns == 2) width = last > first ? width : 2 * width;
        var room = new Size(Math.Max(0, _viewport.Width - (_columns == 2 ? ViewLayout.Gap : 0)), _viewport.Height);
        var spread = new Size(width, height);
        return _fit == FitMode.Width ? ZoomMath.FitWidth(spread.Width, room) : ZoomMath.FitPage(spread, room);
    }

    // ----- Layout

    // A point on a page that stays where it is on screen while the layout around it changes.
    private readonly record struct Anchor(int Page, Point Point);

    // Anchored on the current page, so going back there keeps the page box right; the point can lie above the page.
    public PagePoint? TopPlace()
    {
        if (!_layout.Contains(_page)) return AnchorAt(new Point(0, 0)) is { } a ? new PagePoint(a.Page, a.Point) : null;
        return new PagePoint(_page, PageSpace.ToPage(ContentMatrix(_page)).Transform(new Point(_offsetX, _offsetY)));
    }

    private Anchor? AnchorAt(Point viewPoint)
    {
        if (_layout.PageCount == 0) return null;
        var content = new Point(viewPoint.X + _offsetX, viewPoint.Y + _offsetY);
        int page = _layout.NearestPage(content);
        if (page < 0) return null;
        return new Anchor(page, PageSpace.ToPage(ContentMatrix(page)).Transform(content));
    }

    // Lays the pages out again and puts the anchor back where it was on the screen.
    private void Rebuild(int? spread, Point viewPoint, Anchor? anchor)
    {
        _layout = ViewLayout.Build(_sizes, new LayoutOptions(_columns, _cover, _continuous, _rotation, Scale, _viewport, Dpi),
            spread ?? ViewLayout.SpreadOf(_columns, _cover, _page));
        if (anchor is { } a && _layout.Contains(a.Page))
        {
            var content = ContentMatrix(a.Page).Transform(a.Point);
            _offsetX = content.X - viewPoint.X;
            _offsetY = content.Y - viewPoint.Y;
        }
        ClampOffset();
        AfterScroll(user: false);
        ScrollOwner?.InvalidateScrollInfo();
    }

    /// <summary>Takes a point of a page to the scrolled area (before the scroll offset).</summary>
    private Matrix ContentMatrix(int page) =>
        PageSpace.ToView(_sizes[page], _rotation, Scale, _layout.PageRect(page).TopLeft);

    /// <summary>Takes a point of page space to the surface; null when the page is not laid out (the other pages of a paged layout).</summary>
    public Matrix? PageMatrix(int page)
    {
        if ((uint)page >= (uint)_sizes.Length || !_layout.Contains(page)) return null;
        var m = ContentMatrix(page);
        m.Translate(-_offsetX, -_offsetY);
        return m;
    }

    /// <summary>The page under a point of the surface, with the point in page space. <paramref name="nearest"/> takes the closest page when the point is between pages.</summary>
    public (int Page, Point Point)? Hit(Point surfacePoint, bool nearest = false)
    {
        var content = new Point(surfacePoint.X + _offsetX, surfacePoint.Y + _offsetY);
        int page = _layout.PageAt(content);
        if (page < 0 && nearest) page = _layout.NearestPage(content);
        if (page < 0) return null;
        return (page, PageSpace.ToPage(ContentMatrix(page)).Transform(content));
    }

    // ----- Going places

    /// <summary>Scrolls to a page. With <paramref name="at"/> (page space) that point comes to the top of the view, whatever the rotation; <paramref name="keepX"/> also keeps its column when the layout is wider than the view.</summary>
    public void GoToPage(int page, Point? at = null, bool keepX = false)
    {
        if (_sizes.Length == 0) return;
        page = Math.Clamp(page, 0, _sizes.Length - 1);
        _page = page;
        _pinned = true;
        int spread = ViewLayout.SpreadOf(_columns, _cover, page);
        if (!_continuous && spread != _layout.FirstSpread)
        {
            if (_fit != FitMode.None) _zoom = ZoomMath.Clamp(FitZoom(), ZoomLimits);
            Rebuild(spread, new Point(0, 0), null);
        }
        var rect = _layout.PageRect(page);
        if (at is { } point) _offsetY = ContentMatrix(page).Transform(point).Y;
        else _offsetY = _continuous ? rect.Top - ViewLayout.Margin : 0;
        if (keepX && at is { } kept) _offsetX = ContentMatrix(page).Transform(kept).X;
        else if (_layout.Extent.Width > _viewport.Width) _offsetX = Math.Max(0, rect.Left + rect.Width / 2 - _viewport.Width / 2);
        ClampOffset();
        AfterScroll(user: false);
        ScrollOwner?.InvalidateScrollInfo();
        if (_tab is not null) _tab.PageIndex = page;
        PageChanged?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>Scrolls so that <paramref name="area"/> (page space) is in view, centred when it is not already.</summary>
    public void Reveal(int page, Rect area)
    {
        if ((uint)page >= (uint)_sizes.Length) return;
        if (!_layout.Contains(page)) GoToPage(page);
        var shown = PageSpace.Transform(ContentMatrix(page), area);
        var view = ViewRect;
        var margin = new Size(Math.Min(48, view.Width / 4), Math.Min(48, view.Height / 4));
        var inner = new Rect(view.Left + margin.Width, view.Top + margin.Height, view.Width - 2 * margin.Width, view.Height - 2 * margin.Height);
        if (inner.Contains(shown)) return;
        _pinned = true;
        _page = page;
        _offsetY = shown.Top + shown.Height / 2 - view.Height / 2;
        if (_layout.Extent.Width > view.Width) _offsetX = shown.Left + shown.Width / 2 - view.Width / 2;
        ClampOffset();
        AfterScroll(user: false);
        ScrollOwner?.InvalidateScrollInfo();
        if (_tab is not null) _tab.PageIndex = page;
        PageChanged?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>Scrolls by the user's doing. In a paged layout, running past the edge turns the page.</summary>
    public void ScrollBy(double dx, double dy, bool smooth = false)
    {
        long now = Environment.TickCount64;
        // A touchpad's inertia keeps sending small wheel events; only a pause lets the next one turn the page.
        bool mayTurn = !smooth || now - _lastWheel >= 250;
        if (smooth) _lastWheel = now;
        double maxY = Math.Max(0, _layout.Extent.Height - _viewport.Height);
        if (mayTurn && !_continuous && dy > 0 && _offsetY >= maxY - 0.5 && _layout.LastSpread < _layout.SpreadCount - 1)
        {
            GoToPage(ViewLayout.PagesOf(_columns, _cover, _layout.LastSpread + 1, _sizes.Length).First);
            return;
        }
        if (mayTurn && !_continuous && dy < 0 && _offsetY <= 0.5 && _layout.FirstSpread > 0)
        {
            GoToPage(ViewLayout.PagesOf(_columns, _cover, _layout.FirstSpread - 1, _sizes.Length).First);
            _offsetY = Math.Max(0, _layout.Extent.Height - _viewport.Height);
            AfterScroll(user: false);
            ScrollOwner?.InvalidateScrollInfo();
            return;
        }
        _offsetX += dx;
        _offsetY += dy;
        ClampOffset();
        AfterScroll(user: true);
        ScrollOwner?.InvalidateScrollInfo();
    }

    private void ClampOffset()
    {
        // Whole device pixels, so tiles keep their sharpness while scrolling.
        double ppd = Dpi;
        _offsetX = Math.Round(Math.Clamp(_offsetX, 0, Math.Max(0, _layout.Extent.Width - _viewport.Width)) * ppd) / ppd;
        _offsetY = Math.Round(Math.Clamp(_offsetY, 0, Math.Max(0, _layout.Extent.Height - _viewport.Height)) * ppd) / ppd;
    }

    private void AfterScroll(bool user)
    {
        if (user) _pinned = false;
        if (!_pinned && _layout.PageCount > 0)
        {
            int page = _layout.MostVisible(ViewRect);
            if (page >= 0 && page != _page)
            {
                _page = page;
                if (_tab is not null) _tab.PageIndex = page;
                PageChanged?.Invoke(this, EventArgs.Empty);
                TellScreenReader();
            }
        }
        PlaceOverlays();
        InvalidateVisual();
        ScheduleTiles();
        ViewChanged?.Invoke(this, EventArgs.Empty);
    }

    private void TellScreenReader()
    {
        if (AutomationPeer.ListenerExists(AutomationEvents.PropertyChanged) && UIElementAutomationPeer.FromElement(this) is PageSurfacePeer peer) peer.PageChanged();
        TellLinks();
    }

    private void TellLinks()
    {
        if (UIElementAutomationPeer.FromElement(this) is PageSurfacePeer peer) peer.LinksChanged();
    }

    // ----- Layout pass

    protected override Size MeasureOverride(Size available)
    {
        var size = new Size(double.IsInfinity(available.Width) ? _layout.Extent.Width : available.Width,
                            double.IsInfinity(available.Height) ? _layout.Extent.Height : available.Height);
        foreach (UIElement child in InternalChildren) child.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        if (size != _viewport)
        {
            var anchor = AnchorAt(new Point(0, 0));
            _viewport = size;
            if (_fit != FitMode.None && _sizes.Length > 0) _zoom = ZoomMath.Clamp(FitZoom(), ZoomLimits);
            Rebuild(null, new Point(0, 0), anchor);
            NoteZoomChange();
            OptionsChanged?.Invoke(this, EventArgs.Empty);
        }
        return size;
    }

    protected override void OnDpiChanged(DpiScale oldDpi, DpiScale newDpi)
    {
        var anchor = AnchorAt(new Point(0, 0));
        Rebuild(null, new Point(0, 0), anchor);
        NoteZoomChange();
    }

    protected override Size ArrangeOverride(Size finalSize)
    {
        foreach (UIElement child in InternalChildren) child.Arrange(new Rect(child.DesiredSize));
        return finalSize;
    }

    protected override AutomationPeer OnCreateAutomationPeer() => new PageSurfacePeer(this);

    // ----- IScrollInfo

    public ScrollViewer? ScrollOwner { get; set; }

    public bool CanHorizontallyScroll { get; set; }

    public bool CanVerticallyScroll { get; set; }

    public double ExtentWidth => _layout.Extent.Width;

    public double ExtentHeight => _layout.Extent.Height;

    public double ViewportWidth => _viewport.Width;

    public double ViewportHeight => _viewport.Height;

    public double HorizontalOffset => _offsetX;

    public double VerticalOffset => _offsetY;

    public void SetHorizontalOffset(double offset) => SetOffset(offset, _offsetY);

    public void SetVerticalOffset(double offset) => SetOffset(_offsetX, offset);

    private void SetOffset(double x, double y)
    {
        ScrollBy(x - _offsetX, y - _offsetY);
    }

    public void LineUp() => ScrollBy(0, -LineStep);

    public void LineDown() => ScrollBy(0, LineStep);

    public void LineLeft() => ScrollBy(-LineStep, 0);

    public void LineRight() => ScrollBy(LineStep, 0);

    public void PageUp() => ScrollBy(0, -PageStep);

    public void PageDown() => ScrollBy(0, PageStep);

    public void PageLeft() => ScrollBy(-PageStep, 0);

    public void PageRight() => ScrollBy(PageStep, 0);

    public void MouseWheelUp() => ScrollBy(0, -LineStep);

    public void MouseWheelDown() => ScrollBy(0, LineStep);

    public void MouseWheelLeft() => ScrollBy(-LineStep, 0);

    public void MouseWheelRight() => ScrollBy(LineStep, 0);

    private double PageStep => Math.Max(LineStep, _viewport.Height * 0.9);

    public Rect MakeVisible(Visual visual, Rect rectangle) => rectangle;
}
