using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;
using LazyPDF.App.Tools.Measure;
using LazyPDF.App.Viewer;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Comment;

/// <summary>
/// Selects a mark under the pointer, with a frame and eight handles to move and resize it. The tool only previews;
/// the change to the file is asked of the panel when the button is released.
/// </summary>
public sealed class EditTool(IDocumentViewer viewer, Func<Marker> marker) : IPagePointerTool
{
    private const double Reach = 4;
    private const double Grip = 9;
    private const double MinSize = 8;

    // View pixels; the viewer asks about handles only this far past a page edge, and the 2 page points of slack grow with zoom.
    private const double MaxReach = 24;

    private static readonly Brush Accent = Freeze(new SolidColorBrush(Color.FromRgb(0x00, 0x78, 0xD4)));

    private readonly List<UIElement> _drawn = [];
    private int _handle = -1;
    private int _vertex = -1;
    private int _adding = -1;
    private int _picked = -1;
    private Point[]? _points;
    private bool _moveOnly;
    private bool _moving;
    private Point _from;
    private Rect _start;
    private Rect _frame;

    /// <summary>The mark that is selected; null when none is.</summary>
    public PdfAnnotation? Current { get; private set; }

    public Cursor? Cursor => Cursors.Arrow;

    public event EventHandler? SelectionChanged;

    public event Action<PdfAnnotation, Vector>? Moved;

    public event Action<PdfAnnotation, Rect>? Resized;

    public event Action<PdfAnnotation, int, Point>? VertexMoved;

    /// <summary>A corner was added after the one with this number, at the point.</summary>
    public event Action<PdfAnnotation, int, Point>? VertexAdded;

    /// <summary>Enter on a corner or end took hold of it; the number is 0-based.</summary>
    public event Action<int>? VertexPicked;

    /// <summary>The corner or end that Enter took hold of and the arrow keys are moving; -1 when none.</summary>
    public int PickedVertex => _picked;

    public event Action<PdfAnnotation>? EditRequested;

    public void Select(PdfAnnotation? mark)
    {
        ClearPick(closeCross: true);
        Current = mark;
        Redraw();
        SelectionChanged?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>Finds the selected mark again after the file changed; it is let go if it is gone.</summary>
    public void Refresh()
    {
        ClearPick(closeCross: true);
        // The file changed, so a corner still being pulled out has nothing left to join.
        if (_adding >= 0)
        {
            _adding = -1;
            _vertex = -1;
            _handle = -1;
            _moving = false;
        }
        if (Current is not { Reference: { } reference } mark) return;
        Current = marker().Find(mark.PageIndex, reference.Number);
        Redraw();
        if (Current is null) SelectionChanged?.Invoke(this, EventArgs.Empty);
    }

    public void Redraw()
    {
        Remove();
        if (Current is not { } mark || !marker().OnPage(mark)) return;
        _frame = marker().BoxOf(mark);
        // A scroll or zoom redraws mid-drag, and the corner being pulled out is not in the file yet.
        if (_adding < 0) _points = marker().PointsOf(mark);
        _moveOnly = Marker.Fixed(mark);
        if (_picked >= (_points?.Length ?? 0)) ClearPick(closeCross: true);
        // An undo can leave fewer points than the one being dragged.
        if (_vertex >= (_points?.Length ?? 0))
        {
            _vertex = -1;
            _adding = -1;
            _handle = -1;
            _moving = false;
        }
        Draw(mark.PageIndex, _frame);
    }

    /// <summary>Whether a press lands on a handle of the selected mark or on the mark itself.</summary>
    public bool Holds(PagePointer pointer)
    {
        if (Current is not { } mark || mark.PageIndex != pointer.Page) return false;
        if (HandleIndex(pointer) >= 0) return true;
        var hit = marker().At(pointer.Page, pointer.Point, Reach);
        return hit is not null && hit.Reference?.Number == mark.Reference?.Number;
    }

    /// <summary>Whether a press lands on a handle of the selected mark, on the page or just off it.</summary>
    public bool HandleUnder(PagePointer pointer) => HandleIndex(pointer) >= 0;

    private int HandleIndex(PagePointer pointer) =>
        Current is { } mark && mark.PageIndex == pointer.Page && !_moveOnly
            ? _points is null ? HandleAt(Spots(_frame), pointer.Point) : VertexAt(_points, pointer.Point)
            : -1;

    public void Press(PagePointer pointer)
    {
        _handle = -1;
        _vertex = -1;
        _adding = -1;
        _moving = false;
        if (!pointer.FromKeys && _picked >= 0)
        {
            ClearPick(closeCross: true);
            Redraw();
        }
        if (pointer.FromKeys && Current is { } keyed && keyed.PageIndex == pointer.Page && _points is not null && !_moveOnly && KeyedPress(keyed, pointer)) return;
        if (HandleIndex(pointer) is var grip and >= 0)
        {
            if (_points is not null)
            {
                _vertex = grip;
                _from = _points[grip];
            }
            else
            {
                _handle = grip;
                Begin(pointer.Point);
            }
            return;
        }
        // The corner is added as the press lands, so a click adds one on the side and a drag pulls it out.
        if (Current is { } selected && selected.PageIndex == pointer.Page && !_moveOnly && _points is not null
            && pointer.Modifiers.HasFlag(ModifierKeys.Control) && !pointer.FromKeys && marker().SegmentAt(selected, pointer.Point, Reach) is var side and >= 0)
        {
            _adding = side;
            _vertex = side + 1;
            _points = [.. _points[..(side + 1)], pointer.Point, .. _points[(side + 1)..]];
            _from = pointer.Point;
            Remove();
            Draw(selected.PageIndex, _frame);
            return;
        }
        var hit = marker().At(pointer.Page, pointer.Point, Reach);
        if (hit is null)
        {
            if (Current is not null) Select(null);
            return;
        }
        if (Current?.Reference?.Number != hit.Reference?.Number || Current?.PageIndex != hit.PageIndex) Select(hit);
        _frame = marker().BoxOf(hit);
        if (pointer.Clicks >= 2)
        {
            EditRequested?.Invoke(hit);
            return;
        }
        _moving = true;
        Begin(pointer.Point);
    }

    public void Move(PagePointer pointer)
    {
        if (Current is not { } mark || pointer.Page != mark.PageIndex || !pointer.Pressed || (!_moving && _handle < 0 && _vertex < 0)) return;
        if (_vertex >= 0)
        {
            if (_points is null || _vertex >= _points.Length) return;
            var overlay = viewer.Overlay(mark.PageIndex);
            var to = pointer.Point;
            if (!pointer.FromKeys && pointer.Modifiers.HasFlag(ModifierKeys.Shift) && Neighbour(mark) is { } fixedPoint) to = MeasureShape.Straighten(fixedPoint, to);
            _points[_vertex] = new Point(Math.Clamp(to.X, 0, overlay.Width), Math.Clamp(to.Y, 0, overlay.Height));
            Remove();
            Draw(mark.PageIndex, _frame);
            return;
        }
        var shift = pointer.Point - _from;
        _frame = Keep(_moving ? new Rect(_start.X + shift.X, _start.Y + shift.Y, _start.Width, _start.Height) : Resize(shift), mark.PageIndex);
        Remove();
        Draw(mark.PageIndex, _frame);
    }

    public void Release(PagePointer pointer)
    {
        if (Current is not { } mark || (!_moving && _handle < 0 && _vertex < 0)) return;
        bool moving = _moving;
        int vertex = _vertex;
        int adding = _adding;
        _moving = false;
        _handle = -1;
        _vertex = -1;
        _adding = -1;
        if (vertex >= 0)
        {
            if (_points is null || vertex >= _points.Length)
            {
                Redraw();
                return;
            }
            var to = _points[vertex];
            if (adding >= 0) VertexAdded?.Invoke(mark, adding, to);
            else if ((to - _from).Length < 0.5) Redraw();
            else VertexMoved?.Invoke(mark, vertex, to);
            return;
        }
        if (Math.Abs(_frame.X - _start.X) < 0.5 && Math.Abs(_frame.Y - _start.Y) < 0.5 && Math.Abs(_frame.Width - _start.Width) < 0.5 && Math.Abs(_frame.Height - _start.Height) < 0.5)
        {
            Redraw();
            return;
        }
        if (moving) Moved?.Invoke(mark, new Vector(_frame.X - _start.X, _frame.Y - _start.Y));
        else Resized?.Invoke(mark, _frame);
    }

    // The first Enter on a corner picks it and puts the cross there; the Enter that ends the arrow keys moves it.
    private bool KeyedPress(PdfAnnotation mark, PagePointer pointer)
    {
        var points = _points!;
        if (_picked >= 0)
        {
            int vertex = _picked;
            ClearPick(closeCross: false);
            if ((pointer.Point - points[vertex]).Length >= 0.5) VertexMoved?.Invoke(mark, vertex, pointer.Point);
            else Redraw();
            return true;
        }
        if (VertexAt(points, pointer.Point) is var v and >= 0)
        {
            _picked = v;
            viewer.PlacementEnded += PlacementEnded;
            Remove();
            Draw(mark.PageIndex, _frame);
            viewer.BeginPlacement(mark.PageIndex, points[v]);
            VertexPicked?.Invoke(v);
            return true;
        }
        if (marker().SegmentAt(mark, pointer.Point, Reach) is var side and >= 0)
        {
            VertexAdded?.Invoke(mark, side, pointer.Point);
            return true;
        }
        return false;
    }

    // Escape closed the cross, so there is nothing left to move.
    private void PlacementEnded(object? sender, EventArgs e)
    {
        ClearPick(closeCross: false);
        Redraw();
    }

    /// <summary>Lets go of the picked corner and, when asked, closes the cross the arrow keys were moving.</summary>
    public void ClearPick(bool closeCross)
    {
        if (_picked < 0) return;
        _picked = -1;
        viewer.PlacementEnded -= PlacementEnded;
        if (closeCross) viewer.CancelPlacement();
    }

    public void Cancel()
    {
        ClearPick(closeCross: true);
        _moving = false;
        _handle = -1;
        _vertex = -1;
        _adding = -1;
        Redraw();
    }

    private void Begin(Point at)
    {
        _from = at;
        _start = _frame;
    }

    // Handles run clockwise from the top left corner: corners at even places, sides at odd.
    private Rect Resize(Vector shift)
    {
        double left = _start.Left, top = _start.Top, right = _start.Right, bottom = _start.Bottom;
        if (_handle is 0 or 6 or 7) left = Math.Min(left + shift.X, right - MinSize);
        if (_handle is 2 or 3 or 4) right = Math.Max(right + shift.X, left + MinSize);
        if (_handle is 0 or 1 or 2) top = Math.Min(top + shift.Y, bottom - MinSize);
        if (_handle is 4 or 5 or 6) bottom = Math.Max(bottom + shift.Y, top + MinSize);
        return new Rect(new Point(left, top), new Point(right, bottom));
    }

    // A mark dragged off the page could not be picked again, so the frame stops at the edge.
    private Rect Keep(Rect frame, int page)
    {
        var overlay = viewer.Overlay(page);
        var bounds = new Rect(0, 0, overlay.Width, overlay.Height);
        if (!_moving)
        {
            var inside = Rect.Intersect(frame, bounds);
            return inside.IsEmpty ? frame : inside;
        }
        return new Rect(Math.Clamp(frame.X, 0, Math.Max(0, bounds.Width - frame.Width)), Math.Clamp(frame.Y, 0, Math.Max(0, bounds.Height - frame.Height)), frame.Width, frame.Height);
    }

    // Shift straightens the dragged point against the one before it; the first end of an open shape takes the next one.
    private Point? Neighbour(PdfAnnotation mark)
    {
        if (_points is not { Length: > 1 } points) return null;
        if (_vertex > 0) return points[_vertex - 1];
        return mark.Type == AnnotationType.Polygon ? points[^1] : points[1];
    }

    // The nearer corner wins, and a press between two close corners belongs to neither, so a short line can still be moved.
    private int VertexAt(Point[] points, Point at)
    {
        int nearest = -1;
        for (int i = 0; i < points.Length; i++)
        {
            if (nearest < 0 || (points[i] - at).Length < (points[nearest] - at).Length) nearest = i;
        }
        if (nearest < 0) return -1;
        double gap = points.Where((_, i) => i != nearest).Select(p => (p - points[nearest]).Length).DefaultIfEmpty(double.MaxValue).Min();
        double zoom = Math.Max(viewer.Zoom, 0.1);
        double reach = Math.Min(Math.Min(Grip / 2 / zoom + 2, MaxReach / zoom), gap / 2);
        return (points[nearest] - at).Length <= reach ? nearest : -1;
    }

    private int HandleAt(Point[] spots, Point at)
    {
        double zoom = Math.Max(viewer.Zoom, 0.1);
        double reach = Math.Min(Grip / 2 / zoom + 2, MaxReach / zoom);
        for (int i = 0; i < spots.Length; i++)
        {
            if ((spots[i] - at).Length <= reach) return i;
        }
        return -1;
    }

    private static Point[] Spots(Rect r)
    {
        double mx = r.X + r.Width / 2, my = r.Y + r.Height / 2;
        return [new(r.Left, r.Top), new(mx, r.Top), new(r.Right, r.Top), new(r.Right, my), new(r.Right, r.Bottom), new(mx, r.Bottom), new(r.Left, r.Bottom), new(r.Left, my)];
    }

    private void Draw(int page, Rect frame)
    {
        var overlay = viewer.Overlay(page);
        double zoom = Math.Max(viewer.Zoom, 0.1);
        var outline = new Rectangle
        {
            Width = frame.Width,
            Height = frame.Height,
            Stroke = Accent,
            StrokeThickness = 1.5 / zoom,
            StrokeDashArray = [4, 3],
            IsHitTestVisible = false,
        };
        Canvas.SetLeft(outline, frame.X);
        Canvas.SetTop(outline, frame.Y);
        Add(overlay, outline);
        double size = Grip / zoom;
        if (_moveOnly) return;
        int at = 0;
        foreach (var spot in _points ?? Spots(frame))
        {
            Shape handle = _points is null
                ? new Rectangle { Width = size, Height = size, Fill = Brushes.White, Stroke = Accent, StrokeThickness = 1.5 / zoom, IsHitTestVisible = false }
                : new Ellipse { Width = size, Height = size, Fill = at++ == _picked ? Accent : Brushes.White, Stroke = Accent, StrokeThickness = 1.5 / zoom, IsHitTestVisible = false };
            Canvas.SetLeft(handle, spot.X - size / 2);
            Canvas.SetTop(handle, spot.Y - size / 2);
            Add(overlay, handle);
        }
    }

    private void Add(PageOverlay overlay, UIElement element)
    {
        overlay.Children.Add(element);
        _drawn.Add(element);
    }

    private void Remove()
    {
        foreach (var element in _drawn)
        {
            if (element is FrameworkElement { Parent: Panel panel }) panel.Children.Remove(element);
        }
        _drawn.Clear();
    }

    /// <summary>Takes the frame off the page and lets go of the selection.</summary>
    public void Clear()
    {
        ClearPick(closeCross: true);
        Remove();
        Current = null;
    }

    private static Brush Freeze(Brush brush)
    {
        brush.Freeze();
        return brush;
    }
}
