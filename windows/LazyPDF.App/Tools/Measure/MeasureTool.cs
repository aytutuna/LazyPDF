using System.Windows;
using System.Windows.Input;
using LazyPDF.App.Viewer;

namespace LazyPDF.App.Tools.Measure;

/// <summary>Takes the pointer on the pages: each click adds a point, snapping to the corners of the words on the page, until the shape is done.</summary>
internal sealed class MeasureTool(IDocumentViewer viewer) : IPagePointerTool
{
    private const double SnapPixels = 10;

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

    public bool CanFinish => Kind != MeasureKind.Distance && _points.Count >= 3;

    public Cursor? Cursor => Cursors.Cross;

    public event Action<MeasureItem>? Finished;

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
        _points.Clear();
        Page = -1;
        Changed?.Invoke(this, EventArgs.Empty);
        Finished?.Invoke(item);
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
        var text = await viewer.GetTextAsync(page);
        _loading.Remove(page);
        if (text is null)
        {
            _snaps[page] = [];
            return;
        }
        var geometry = viewer.Geometry(page);
        _snaps[page] =
        [
            .. text.Words.SelectMany(w => new[] { (w.Bounds.Left, w.Bounds.Bottom), (w.Bounds.Right, w.Bounds.Bottom), (w.Bounds.Left, w.Bounds.Top), (w.Bounds.Right, w.Bounds.Top) })
                .Select(c => geometry.ToDisplay(c.Item1, c.Item2))
                .Select(c => new Point(c.X, c.Y)),
        ];
    }
}
