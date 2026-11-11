using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;
using LazyPDF.App.Tools.Certificates;
using LazyPDF.App.Viewer;

namespace LazyPDF.App.Tools.Redact;

/// <summary>Shows a frame with handles over the selected box mark; dragging it moves the box, dragging a handle resizes it.</summary>
public sealed class RedactBoxEditor
{
    public enum Handle { Body, TopLeft, Top, TopRight, Right, BottomRight, Bottom, BottomLeft, Left }

    private const double Smallest = 4;
    private const double ThumbSize = 12;

    private readonly IDocumentViewer _viewer;
    private readonly Action<MarkItem, MarkItem> _changed;
    private readonly List<(Handle Handle, Thumb Thumb)> _thumbs = [];
    private MarkItem? _item;
    private PageOverlay? _layer;
    private Rectangle? _frame;
    private Rect _rect;
    private Rect _start;
    private Point _grab;

    public RedactBoxEditor(IDocumentViewer viewer, Action<MarkItem, MarkItem> changed)
    {
        _viewer = viewer;
        _changed = changed;
        viewer.ViewChanged += Viewer_ViewChanged;
    }

    public void Detach()
    {
        _viewer.ViewChanged -= Viewer_ViewChanged;
        Show(null);
    }

    /// <summary>Frames <paramref name="item"/> when it is a box; null, or any other mark, removes the frame.</summary>
    public void Show(MarkItem? item)
    {
        Clear();
        if (item is not { IsBox: true } || item.Page >= _viewer.PageCount) return;
        _item = item;
        _layer = _viewer.Overlay(item.Page);
        _rect = MarkShapes.Where(_viewer.Geometry(item.Page), item.Mark);
        _frame = SignatureBoxTool.Outline();
        _layer.Children.Add(_frame);
        foreach (var handle in Enum.GetValues<Handle>()) Add(handle);
        Place();
    }

    public void Clear()
    {
        if (_layer is not null)
        {
            if (_frame is not null) _layer.Children.Remove(_frame);
            foreach (var (_, thumb) in _thumbs) _layer.Children.Remove(thumb);
        }
        _thumbs.Clear();
        _frame = null;
        _layer = null;
        _item = null;
    }

    /// <summary>The box after a drag of <paramref name="delta"/> (page space) on <paramref name="handle"/>, kept on the page and at least <paramref name="smallest"/> across.</summary>
    public static Rect Drag(Rect rect, Handle handle, Vector delta, Size page, double smallest = Smallest)
    {
        if (handle == Handle.Body)
        {
            double x = Math.Clamp(rect.X + delta.X, 0, Math.Max(0, page.Width - rect.Width));
            double y = Math.Clamp(rect.Y + delta.Y, 0, Math.Max(0, page.Height - rect.Height));
            return new Rect(x, y, rect.Width, rect.Height);
        }
        double left = rect.Left, top = rect.Top, right = rect.Right, bottom = rect.Bottom;
        if (handle is Handle.TopLeft or Handle.Left or Handle.BottomLeft) left = Math.Clamp(left + delta.X, 0, right - smallest);
        if (handle is Handle.TopRight or Handle.Right or Handle.BottomRight) right = Math.Clamp(right + delta.X, left + smallest, page.Width);
        if (handle is Handle.TopLeft or Handle.Top or Handle.TopRight) top = Math.Clamp(top + delta.Y, 0, bottom - smallest);
        if (handle is Handle.BottomLeft or Handle.Bottom or Handle.BottomRight) bottom = Math.Clamp(bottom + delta.Y, top + smallest, page.Height);
        return new Rect(left, top, right - left, bottom - top);
    }

    private void Add(Handle handle)
    {
        var thumb = new Thumb
        {
            Cursor = Cursor(handle),
            Template = new ControlTemplate(typeof(Thumb)) { VisualTree = Visual(handle) },
        };
        thumb.DragStarted += (_, _) => { _start = _rect; _grab = Mouse.GetPosition(_layer); };
        thumb.DragDelta += (_, _) => Dragged(handle);
        thumb.DragCompleted += (_, e) => Done(e.Canceled);
        _layer!.Children.Add(thumb);
        _thumbs.Add((handle, thumb));
    }

    private static FrameworkElementFactory Visual(Handle handle)
    {
        var square = new FrameworkElementFactory(typeof(Rectangle));
        square.SetValue(Shape.FillProperty, handle == Handle.Body ? Brushes.Transparent : Brushes.White);
        if (handle == Handle.Body) return square;
        square.SetResourceReference(Shape.StrokeProperty, "AccentFillColorDefaultBrush");
        square.SetValue(Shape.StrokeThicknessProperty, 1.0);
        return square;
    }

    private void Dragged(Handle handle)
    {
        var delta = Mouse.GetPosition(_layer) - _grab;
        _rect = Drag(_start, handle, delta, _viewer.PageSize(_item!.Page));
        Place();
    }

    private void Done(bool canceled)
    {
        if (_item is not { } old) return;
        if (canceled)
        {
            _rect = _start;
            Place();
            return;
        }
        if (_rect == _start) return;
        var geometry = _viewer.Geometry(old.Page);
        var now = old with { Mark = MarkShapes.Box(old.Page, geometry, _rect.TopLeft, _rect.BottomRight) };
        _changed(old, now);
    }

    // The layer is scaled with the page, so the handles are divided by the zoom to stay the same size on screen.
    private void Place()
    {
        SignatureBoxTool.Place(_frame!, _rect);
        double size = ThumbSize / _viewer.Zoom;
        foreach (var (handle, thumb) in _thumbs)
        {
            if (handle == Handle.Body)
            {
                thumb.Width = _rect.Width;
                thumb.Height = _rect.Height;
                Canvas.SetLeft(thumb, _rect.X);
                Canvas.SetTop(thumb, _rect.Y);
                continue;
            }
            var centre = Centre(handle);
            thumb.Width = size;
            thumb.Height = size;
            Canvas.SetLeft(thumb, centre.X - size / 2);
            Canvas.SetTop(thumb, centre.Y - size / 2);
        }
    }

    private Point Centre(Handle handle)
    {
        double x = handle switch
        {
            Handle.TopLeft or Handle.Left or Handle.BottomLeft => _rect.Left,
            Handle.TopRight or Handle.Right or Handle.BottomRight => _rect.Right,
            _ => _rect.Left + _rect.Width / 2,
        };
        double y = handle switch
        {
            Handle.TopLeft or Handle.Top or Handle.TopRight => _rect.Top,
            Handle.BottomLeft or Handle.Bottom or Handle.BottomRight => _rect.Bottom,
            _ => _rect.Top + _rect.Height / 2,
        };
        return new Point(x, y);
    }

    private static Cursor Cursor(Handle handle) => handle switch
    {
        Handle.Body => Cursors.SizeAll,
        Handle.Top or Handle.Bottom => Cursors.SizeNS,
        Handle.Left or Handle.Right => Cursors.SizeWE,
        Handle.TopLeft or Handle.BottomRight => Cursors.SizeNWSE,
        _ => Cursors.SizeNESW,
    };

    private void Viewer_ViewChanged(object? sender, EventArgs e)
    {
        if (_frame is not null) Place();
    }
}
