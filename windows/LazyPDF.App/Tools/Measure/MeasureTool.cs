using System.Windows;
using System.Windows.Input;
using LazyPDF.App.Documents;
using LazyPDF.App.Viewer;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Measure;

/// <summary>Takes the pointer on the pages: each click adds a point, snapping to the corners of the words and the ends of the lines and pictures on the page, until the shape is done.</summary>
internal sealed class MeasureTool(IDocumentViewer viewer) : IPagePointerTool
{
    private const double SnapPixels = 10;
    private const int MaxDrawn = 20000;

    private readonly Dictionary<int, Point[]> _snaps = [];
    private readonly HashSet<int> _loading = [];
    private readonly List<Point> _points = [];

    public MeasureKind Kind { get; set; }

    public bool Snap { get; set; } = true;

    /// <summary>The page of the shape being drawn; -1 when none is.</summary>
    public int Page { get; private set; } = -1;

    public IReadOnlyList<Point> Points => _points;

    /// <summary>Where the next click would land, on the page of the last move.</summary>
    public Point? Hover { get; private set; }

    public int HoverPage { get; private set; } = -1;

    public bool Snapped { get; private set; }

    /// <summary>A distance of two points reports its length through Calibrated instead of becoming an item.</summary>
    public bool Calibrate { get; set; }

    public bool CanFinish => Kind != MeasureKind.Distance && _points.Count >= 3;

    public Cursor? Cursor => Cursors.Cross;

    public event Action<MeasureItem>? Finished;

    /// <summary>The page and the length in points of the two ends clicked in calibrate mode.</summary>
    public event Action<int, double>? Calibrated;

    public event EventHandler? Changed;

    public void Press(PagePointer pointer)
    {
        if (_points.Count > 0 && pointer.Page != Page) return;
        Page = pointer.Page;
        if (pointer.Clicks >= 2)
        {
            // The first click of the double already put its point here.
            if (Kind != MeasureKind.Distance) Finish();
            return;
        }
        _ = LoadSnapsAsync(pointer.Page);
        var at = Resolve(pointer, true);
        if (CanFinish && Near(at, _points[0], pointer.Page))
        {
            Finish();
            return;
        }
        _points.Add(at);
        if (Kind == MeasureKind.Distance && _points.Count == 2) Finish();
        else Changed?.Invoke(this, EventArgs.Empty);
    }

    public void Move(PagePointer pointer)
    {
        Hover = Resolve(pointer, pointer.Page == Page);
        HoverPage = pointer.Page;
        _ = LoadSnapsAsync(pointer.Page);
        Changed?.Invoke(this, EventArgs.Empty);
    }

    public void Release(PagePointer pointer)
    {
    }

    public void Cancel()
    {
        _points.Clear();
        Page = -1;
        Hover = null;
        Changed?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>Takes back the last corner.</summary>
    public void Undo()
    {
        if (_points.Count == 0) return;
        _points.RemoveAt(_points.Count - 1);
        if (_points.Count == 0) Page = -1;
        Changed?.Invoke(this, EventArgs.Empty);
    }

    public void Finish()
    {
        if (!CanFinish && !(Kind == MeasureKind.Distance && _points.Count == 2)) return;
        var item = new MeasureItem(Kind, Page, [.. _points]);
        int page = Page;
        _points.Clear();
        Page = -1;
        Changed?.Invoke(this, EventArgs.Empty);
        if (Calibrate) Calibrated?.Invoke(page, (item.Points[1] - item.Points[0]).Length);
        else Finished?.Invoke(item);
    }

    /// <summary>Drops the snap points, which belong to the file as it was.</summary>
    public void Forget() => _snaps.Clear();

    /// <summary>View pixels per point of the page; 0 while the page is not laid out.</summary>
    public double Scale(int page) => viewer.PageToView(page) is { } m ? Math.Sqrt(m.M11 * m.M11 + m.M12 * m.M12) : 0;

    private Point Resolve(PagePointer pointer, bool sameShape)
    {
        Snapped = false;
        var at = pointer.Point;
        if (pointer.Modifiers.HasFlag(ModifierKeys.Shift) && sameShape && _points.Count > 0) return MeasureShape.Straighten(_points[^1], at);
        if (!Snap || !_snaps.TryGetValue(pointer.Page, out var corners)) return at;
        double scale = Scale(pointer.Page);
        if (scale <= 0 || MeasureShape.Nearest(corners, at, SnapPixels / scale) is not { } snapped) return at;
        Snapped = true;
        return snapped;
    }

    private bool Near(Point a, Point b, int page)
    {
        double scale = Scale(page);
        return scale > 0 && (a - b).Length * scale <= SnapPixels;
    }

    private async Task LoadSnapsAsync(int page)
    {
        if (!Snap || _snaps.ContainsKey(page) || !_loading.Add(page)) return;
        var tab = viewer.Tab;
        var document = tab?.Document;
        List<(double, double)> drawn = [];
        TextPage? text;
        try
        {
            text = await viewer.GetTextAsync(page);
            // The live document is not for other threads, so the worker reads its own copy of the bytes.
            if (text is not null && tab is not null)
            {
                var (bytes, password, certificate) = (PageSurface.Bytes(tab), tab.Password, tab.Certificate);
                drawn = await Task.Run(() => Drawn(bytes, password, certificate, page));
            }
        }
        finally { _loading.Remove(page); }
        if (!ReferenceEquals(viewer.Tab, tab) || !ReferenceEquals(tab?.Document, document)) return;
        if (text is null)
        {
            _snaps[page] = [];
            return;
        }
        var geometry = viewer.Geometry(page);
        var corners = text.Words.SelectMany(w => new[] { (w.Bounds.Left, w.Bounds.Bottom), (w.Bounds.Right, w.Bounds.Bottom), (w.Bounds.Left, w.Bounds.Top), (w.Bounds.Right, w.Bounds.Top) }).ToList();
        corners.AddRange(drawn);
        _snaps[page] = [.. corners.Select(c => geometry.ToDisplay(c.Item1, c.Item2)).Select(c => new Point(c.X, c.Y))];
    }

    private static List<(double, double)> Drawn(byte[] bytes, string? password, System.Security.Cryptography.X509Certificates.X509Certificate2? certificate, int page)
    {
        var drawn = new List<(double, double)>();
        try
        {
            var session = certificate is null ? PdfEditSession.Open(bytes, password) : PdfEditSession.Open(bytes, certificate);
            var editor = new PageEditor(session, page);
            foreach (var o in editor.Objects)
            {
                if (drawn.Count >= MaxDrawn) break;
                if (o is ImageObject image)
                {
                    var b = image.Bounds;
                    drawn.AddRange([(b.Left, b.Bottom), (b.Right, b.Bottom), (b.Left, b.Top), (b.Right, b.Top)]);
                }
                else if (o is PathObject { Clips: false } path)
                {
                    foreach (var s in path.Segments)
                    {
                        if (s.Kind is PathSegmentKind.Move or PathSegmentKind.Line) drawn.Add((s.X1, s.Y1));
                        else if (s.Kind == PathSegmentKind.Curve) drawn.Add((s.X3, s.Y3));
                    }
                }
            }
        }
        catch (Exception e) when (e is ArgumentException or InvalidOperationException or PdfReadException)
        {
            return [];
        }
        return drawn.Take(MaxDrawn).ToList();
    }
}
