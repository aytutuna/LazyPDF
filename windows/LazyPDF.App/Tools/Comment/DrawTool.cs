using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;
using LazyPDF.App.Tools.Measure;
using LazyPDF.App.Viewer;

namespace LazyPDF.App.Tools.Comment;

/// <summary>Takes the pointer to draw one kind of mark on a page; what was drawn goes to <paramref name="done"/> as page points.</summary>
public sealed class DrawTool(IDocumentViewer viewer, MarkTool tool, Func<MarkStyle> style, Action<MarkTool, int, IReadOnlyList<Point>> done, Func<PagePointer, IPagePointerTool?>? grab = null) : IPagePointerTool
{
    private const double MinDrag = 3;

    private static readonly Size DefaultBox = new(160, 48);

    private readonly List<Point> _points = [];
    private int _page = -1;
    private Point _now;
    private Shape? _preview;
    private Shape? _box;
    private bool _keyed;
    private IPagePointerTool? _grabbed;

    public Cursor? Cursor => tool == MarkTool.Pencil ? Cursors.Pen : Cursors.Cross;

    /// <summary>A polygon or cloud has corners and waits for more.</summary>
    public bool Started => _page >= 0;

    private bool ByClick => tool is MarkTool.Note or MarkTool.Stamp or MarkTool.Attach;

    private bool Many => tool is MarkTool.Polygon or MarkTool.Cloud;

    public void Press(PagePointer pointer)
    {
        if (_page < 0 && !pointer.FromKeys && grab?.Invoke(pointer) is { } other)
        {
            _grabbed = other;
            other.Press(pointer);
            return;
        }
        if (_keyed && pointer.FromKeys && pointer.Page == _page)
        {
            _now = pointer.Point;
            return;
        }
        if (Many && _page >= 0)
        {
            if (pointer.Page != _page) return;
            if (pointer.Clicks >= 2 || (_points.Count >= 3 && Close(pointer.Point, _points[0]))) Complete();
            else Extend(pointer.Point);
            return;
        }
        Clear();
        _page = pointer.Page;
        _points.Add(pointer.Point);
        _now = pointer.Point;
        if (!ByClick) Show();
    }

    public void Move(PagePointer pointer)
    {
        if (_grabbed is not null)
        {
            _grabbed.Move(pointer);
            return;
        }
        if (_page < 0 || pointer.Page != _page) return;
        _now = Constrain(pointer);
        if (pointer.Pressed && (tool == MarkTool.Pencil || tool == MarkTool.Eraser) && (_now - _points[^1]).Length >= 1) _points.Add(_now);
        Show();
    }

    public void Release(PagePointer pointer)
    {
        if (_grabbed is { } held)
        {
            _grabbed = null;
            held.Release(pointer);
            return;
        }
        if (_page < 0) return;
        if (pointer.Page == _page) _now = Constrain(pointer);
        if (Many)
        {
            if (_points.Count == 1) Extend(_now);
            return;
        }
        if (ByClick)
        {
            Complete();
            return;
        }
        if (tool is MarkTool.Pencil or MarkTool.Eraser)
        {
            if (_points.Count < 2) _points.Add(_now + new Vector(0.1, 0));
            Complete();
            return;
        }
        if ((_now - _points[0]).Length < MinDrag)
        {
            // A keyed click on a drag tool only sets the start; the next one on the page ends it.
            if (tool != MarkTool.TextBox)
            {
                if (pointer.FromKeys && !_keyed) _keyed = true;
                else Clear();
                return;
            }
            // A click makes a box of the usual size, so the keyboard can place one too.
            var page = viewer.PageSize(_page);
            _now = new Point(Math.Min(_points[0].X + DefaultBox.Width, page.Width), Math.Min(_points[0].Y + DefaultBox.Height, page.Height));
        }
        _points.Add(_now);
        Complete();
    }

    public void Cancel()
    {
        _grabbed?.Cancel();
        _grabbed = null;
        Clear();
    }

    public void Finish()
    {
        if (Many && _points.Count >= 3) Complete();
    }

    private Point Constrain(PagePointer pointer)
    {
        if (!pointer.Modifiers.HasFlag(ModifierKeys.Shift) || _points.Count == 0) return pointer.Point;
        var first = _points[0];
        if (tool is MarkTool.Line or MarkTool.Arrow) return MeasureShape.Straighten(first, pointer.Point);
        var d = pointer.Point - first;
        if (tool is MarkTool.Callout) return Math.Abs(d.X) >= Math.Abs(d.Y) ? new Point(pointer.Point.X, first.Y) : new Point(first.X, pointer.Point.Y);
        if (tool is not (MarkTool.Rectangle or MarkTool.Oval or MarkTool.TextBox)) return pointer.Point;
        var page = viewer.PageSize(_page);
        int sx = d.X >= 0 ? 1 : -1, sy = d.Y >= 0 ? 1 : -1;
        double roomX = sx > 0 ? page.Width - first.X : first.X;
        double roomY = sy > 0 ? page.Height - first.Y : first.Y;
        double side = Math.Min(Math.Max(Math.Abs(d.X), Math.Abs(d.Y)), Math.Min(roomX, roomY));
        return new Point(first.X + sx * side, first.Y + sy * side);
    }

    private static bool Close(Point a, Point b) => (a - b).Length < 6;

    private void Extend(Point at)
    {
        if ((at - _points[^1]).Length < 1) return;
        _points.Add(at);
        Show();
    }

    private void Complete()
    {
        int page = _page;
        var points = _points.ToArray();
        Clear();
        if (Many && points.Length < 3) return;
        done(tool, page, points);
    }

    private void Clear()
    {
        if (_preview is not null) viewer.Overlay(_page).Children.Remove(_preview);
        if (_box is not null) viewer.Overlay(_page).Children.Remove(_box);
        _preview = null;
        _box = null;
        _points.Clear();
        _page = -1;
        _keyed = false;
    }

    // The preview is redrawn whole on every move: the shapes are small and a page rarely holds more than a few points.
    private void Show()
    {
        if (_page < 0) return;
        var overlay = viewer.Overlay(_page);
        var look = style();
        var color = look.Color is { } c ? Color.FromRgb(Byte(c, 0), Byte(c, 1), Byte(c, 2)) : Colors.Red;
        var brush = new SolidColorBrush(tool == MarkTool.Eraser ? Colors.Gray : color) { Opacity = tool == MarkTool.Eraser ? 0.5 : look.Opacity };
        double thickness = tool == MarkTool.Eraser ? 8 : Math.Max(look.Width, 1);
        if (_preview is not null) overlay.Children.Remove(_preview);
        if (_box is not null) overlay.Children.Remove(_box);
        _preview = _box = null;

        var shape = Outline(brush, thickness);
        if (shape is null) return;
        shape.IsHitTestVisible = false;
        var dashes = Marker.TakesLine(tool) ? Dashes(look.Dash, thickness) : null;
        if (dashes is not null) shape.StrokeDashArray = dashes;
        if (Marker.TakesFill(tool) && look.Fill is { } f)
        {
            shape.Fill = new SolidColorBrush(Color.FromRgb(Byte(f, 0), Byte(f, 1), Byte(f, 2))) { Opacity = look.Opacity };
        }
        _preview = shape;
        overlay.Children.Add(shape);
        if (tool == MarkTool.Callout)
        {
            var area = Marker.BoxOf(tool, [_points[0], _now]);
            var frame = new Rectangle { Width = area.Width, Height = area.Height, Stroke = brush, StrokeThickness = thickness, StrokeDashArray = dashes, IsHitTestVisible = false };
            if (look.Fill is { } filling) frame.Fill = new SolidColorBrush(Color.FromRgb(Byte(filling, 0), Byte(filling, 1), Byte(filling, 2))) { Opacity = look.Opacity };
            Canvas.SetLeft(frame, area.X);
            Canvas.SetTop(frame, area.Y);
            _box = frame;
            overlay.Children.Add(frame);
        }
    }

    private Shape? Outline(Brush brush, double thickness)
    {
        var first = _points[0];
        switch (tool)
        {
            case MarkTool.Rectangle or MarkTool.TextBox or MarkTool.Oval:
            {
                var area = new Rect(first, _now);
                Shape shape = tool == MarkTool.Oval ? new Ellipse() : new Rectangle();
                shape.Width = area.Width;
                shape.Height = area.Height;
                shape.Stroke = brush;
                shape.StrokeThickness = tool == MarkTool.TextBox ? 1 : thickness;
                if (tool == MarkTool.TextBox) shape.StrokeDashArray = [4, 3];
                Canvas.SetLeft(shape, area.X);
                Canvas.SetTop(shape, area.Y);
                return shape;
            }
            case MarkTool.Line or MarkTool.Arrow or MarkTool.Callout:
                return new Line { X1 = first.X, Y1 = first.Y, X2 = _now.X, Y2 = _now.Y, Stroke = brush, StrokeThickness = thickness };
            case MarkTool.Polygon or MarkTool.Cloud:
                return new Polyline { Points = [.. _points, _now], Stroke = brush, StrokeThickness = thickness, StrokeLineJoin = PenLineJoin.Round };
            case MarkTool.Pencil or MarkTool.Eraser:
                return new Polyline { Points = [.. _points], Stroke = brush, StrokeThickness = thickness, StrokeLineJoin = PenLineJoin.Round, StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round };
            default:
                return null;
        }
    }

    // WPF counts dashes in line widths; the file counts them in points, with a dot one point longer than wide.
    private static DoubleCollection? Dashes(LineStyle style, double thickness) => style switch
    {
        LineStyle.Dashed => [3, 2],
        LineStyle.Dotted => [1, 1 + 1 / thickness],
        _ => null,
    };

    private static byte Byte(double[] color, int i) => (byte)Math.Round(Math.Clamp(color.Length == 1 ? color[0] : color.Length >= 3 ? color[i] : 0, 0, 1) * 255);
}
