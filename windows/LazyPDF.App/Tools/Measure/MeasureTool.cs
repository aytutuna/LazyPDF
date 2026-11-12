using System.Windows;
using System.Windows.Input;
using LazyPDF.App.Documents;
using LazyPDF.App.Viewer;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Measure;

/// <summary>Takes the pointer on the pages: each click adds a point, snapping to the corners of the words and the lines and pictures on the page, until the shape is done.</summary>
internal sealed class MeasureTool(IDocumentViewer viewer) : IPagePointerTool
{
    private const double SnapPixels = 10;
    private const int MaxDrawn = 20000;

    private readonly Dictionary<int, Point[]> _snaps = [];
    private readonly Dictionary<int, (Point From, Point To)[]> _lines = [];
    private readonly HashSet<int> _loading = [];
    private readonly List<Point> _points = [];

    // One parsed copy of the bytes serves every page, read one after another since the copy is not for several threads.
    private Task _reading = Task.CompletedTask;
    private byte[]? _copyOf;
    private PdfEditSession? _copy;

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
    public void Forget()
    {
        _snaps.Clear();
        _lines.Clear();
        _reading = _reading.ContinueWith(_ => (_copyOf, _copy) = (null, null), TaskScheduler.Default);
    }

    /// <summary>View pixels per point of the page; 0 while the page is not laid out.</summary>
    public double Scale(int page) => viewer.PageToView(page) is { } m ? Math.Sqrt(m.M11 * m.M11 + m.M12 * m.M12) : 0;

    private Point Resolve(PagePointer pointer, bool sameShape)
    {
        Snapped = false;
        var at = pointer.Point;
        if (pointer.Modifiers.HasFlag(ModifierKeys.Shift) && sameShape && _points.Count > 0) return MeasureShape.Straighten(_points[^1], at);
        if (!Snap || pointer.Modifiers.HasFlag(ModifierKeys.Alt) || !_snaps.TryGetValue(pointer.Page, out var corners)) return at;
        double scale = Scale(pointer.Page);
        if (scale <= 0) return at;
        double radius = SnapPixels / scale;
        var snapped = MeasureShape.Nearest(corners, at, radius) ?? MeasureShape.NearestOnLines(_lines.GetValueOrDefault(pointer.Page) ?? [], at, radius);
        if (snapped is not { } found) return at;
        Snapped = true;
        return found;
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
        List<(double X1, double Y1, double X2, double Y2)> drawn = [];
        TextPage? text;
        try
        {
            text = await viewer.GetTextAsync(page);
            // The live document is not for other threads, so the worker reads its own copy of the bytes.
            if (tab is not null)
            {
                var (bytes, password, certificate) = (PageSurface.Bytes(tab), tab.Password, tab.Certificate);
                var previous = _reading;
                var read = Task.Run(async () =>
                {
                    try { await previous; }
                    catch (Exception) { }
                    return Drawn(bytes, password, certificate, page);
                });
                _reading = read;
                drawn = await read;
            }
        }
        finally { _loading.Remove(page); }
        if (!ReferenceEquals(viewer.Tab, tab) || !ReferenceEquals(tab?.Document, document)) return;
        var geometry = viewer.Geometry(page);
        Point Shown(double x, double y)
        {
            var p = geometry.ToDisplay(x, y);
            return new Point(p.X, p.Y);
        }
        var edges = drawn.Select(e => (From: Shown(e.X1, e.Y1), To: Shown(e.X2, e.Y2))).ToList();
        var words = (text?.Words ?? []).SelectMany(w => new[] { Shown(w.Bounds.Left, w.Bounds.Bottom), Shown(w.Bounds.Right, w.Bounds.Bottom), Shown(w.Bounds.Left, w.Bounds.Top), Shown(w.Bounds.Right, w.Bounds.Top) });
        _lines[page] = [.. edges.Where(e => e.From != e.To)];
        _snaps[page] = [.. words, .. edges.Select(e => e.From), .. edges.Select(e => e.To)];
    }

    private List<(double X1, double Y1, double X2, double Y2)> Drawn(byte[] bytes, string? password, System.Security.Cryptography.X509Certificates.X509Certificate2? certificate, int page)
    {
        var drawn = new List<(double X1, double Y1, double X2, double Y2)>();
        try
        {
            if (!ReferenceEquals(_copyOf, bytes))
            {
                _copyOf = bytes;
                _copy = null;
                _copy = certificate is null ? PdfEditSession.Open(bytes, password) : PdfEditSession.Open(bytes, certificate);
            }
            if (_copy is null) return [];
            var editor = new PageEditor(_copy, page);
            foreach (var o in editor.Objects)
            {
                if (drawn.Count >= MaxDrawn) break;
                if (o is ImageObject image)
                {
                    var b = image.Bounds;
                    drawn.AddRange([(b.Left, b.Bottom, b.Right, b.Bottom), (b.Right, b.Bottom, b.Right, b.Top), (b.Right, b.Top, b.Left, b.Top), (b.Left, b.Top, b.Left, b.Bottom)]);
                }
                else if (o is PathObject { Clips: false } path)
                {
                    (double, double)? start = null, last = null;
                    foreach (var s in path.Segments)
                    {
                        switch (s.Kind)
                        {
                            case PathSegmentKind.Move:
                                start = last = (s.X1, s.Y1);
                                drawn.Add((s.X1, s.Y1, s.X1, s.Y1));
                                break;
                            case PathSegmentKind.Line:
                                if (last is { } from) drawn.Add((from.Item1, from.Item2, s.X1, s.Y1));
                                last = (s.X1, s.Y1);
                                break;
                            case PathSegmentKind.Curve:
                                last = (s.X3, s.Y3);
                                drawn.Add((s.X3, s.Y3, s.X3, s.Y3));
                                break;
                            case PathSegmentKind.Close:
                                if (last is { } end && start is { } begin) drawn.Add((end.Item1, end.Item2, begin.Item1, begin.Item2));
                                last = start;
                                break;
                        }
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
