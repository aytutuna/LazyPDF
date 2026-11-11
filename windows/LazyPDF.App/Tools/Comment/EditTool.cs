using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;
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

    private static readonly Brush Accent = Freeze(new SolidColorBrush(Color.FromRgb(0x00, 0x78, 0xD4)));

    private readonly List<UIElement> _drawn = [];
    private int _handle = -1;
    private int _vertex = -1;
    private Point[]? _points;
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

    public event Action<PdfAnnotation>? EditRequested;

    public void Select(PdfAnnotation? mark)
    {
        Current = mark;
        Redraw();
        SelectionChanged?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>Finds the selected mark again after the file changed; it is let go if it is gone.</summary>
    public void Refresh()
    {
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
        _points = marker().PointsOf(mark);
        Draw(mark.PageIndex, _frame);
    }

    /// <summary>Whether a press lands on a handle of the selected mark or on the mark itself.</summary>
    public bool Holds(PagePointer pointer)
    {
        if (Current is not { } mark || mark.PageIndex != pointer.Page) return false;
        if (HandleAt(_points ?? Spots(_frame), pointer.Point) >= 0) return true;
        var hit = marker().At(pointer.Page, pointer.Point, Reach);
        return hit is not null && hit.Reference?.Number == mark.Reference?.Number;
    }

    public void Press(PagePointer pointer)
    {
        _handle = -1;
        _vertex = -1;
        _moving = false;
        if (Current is { } selected && selected.PageIndex == pointer.Page)
        {
            if (_points is not null)
            {
                if (HandleAt(_points, pointer.Point) is var v and >= 0)
                {
                    _vertex = v;
                    _from = _points[v];
                    return;
                }
            }
            else if (HandleAt(Spots(_frame), pointer.Point) is var h and >= 0)
            {
                _handle = h;
                Begin(pointer.Point);
                return;
            }
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
        if (_vertex >= 0 && _points is not null)
        {
            var overlay = viewer.Overlay(mark.PageIndex);
            _points[_vertex] = new Point(Math.Clamp(pointer.Point.X, 0, overlay.Width), Math.Clamp(pointer.Point.Y, 0, overlay.Height));
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
        _moving = false;
        _handle = -1;
        _vertex = -1;
        if (vertex >= 0 && _points is not null)
        {
            var to = _points[vertex];
            if ((to - _from).Length < 0.5) Redraw();
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

    public void Cancel()
    {
        _moving = false;
        _handle = -1;
        _vertex = -1;
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

    private int HandleAt(Point[] spots, Point at)
    {
        double reach = Grip / 2 / Math.Max(viewer.Zoom, 0.1) + 2;
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
        foreach (var spot in _points ?? Spots(frame))
        {
            Shape handle = _points is null
                ? new Rectangle { Width = size, Height = size, Fill = Brushes.White, Stroke = Accent, StrokeThickness = 1.5 / zoom, IsHitTestVisible = false }
                : new Ellipse { Width = size, Height = size, Fill = Brushes.White, Stroke = Accent, StrokeThickness = 1.5 / zoom, IsHitTestVisible = false };
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
        Remove();
        Current = null;
    }

    private static Brush Freeze(Brush brush)
    {
        brush.Freeze();
        return brush;
    }
}
