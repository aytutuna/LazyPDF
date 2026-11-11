using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Shapes;
using LazyPDF.App.Viewer;

namespace LazyPDF.App.Tools.Forms;

/// <summary>
/// The pointer while fields are edited: a press on a field selects it and a drag moves it, a drag from a
/// handle of the selected field resizes it, and a drag on an empty place draws a new field of the chosen kind.
/// </summary>
internal sealed class FieldTool(FormsPanel panel) : IPagePointerTool
{
    private const double MinSize = 4;
    private const double Reach = 7;

    private enum Drag
    {
        None,
        Draw,
        Move,
        Size,
    }

    private Drag _drag;
    private int _page;
    private int _handle;
    private Point _start;
    private Rect _origin;
    private Rect _box;
    private Rectangle? _ghost;

    public Cursor? Cursor => Cursors.Cross;

    internal bool Dragging => _drag != Drag.None;

    public void Press(PagePointer pointer)
    {
        _page = pointer.Page;
        _start = pointer.Point;
        double reach = Reach / FieldFrames.Scale(panel.View);
        if (panel.SelectedBox() is { } selected && selected.Page == _page
            && Array.FindIndex(FieldFrames.Handles(selected.Box), h => Math.Abs(h.X - _start.X) <= reach && Math.Abs(h.Y - _start.Y) <= reach) is var handle and >= 0)
        {
            Begin(Drag.Size, selected.Box);
            _handle = handle;
        }
        else if (panel.WidgetAt(_page, _start) is { } hit)
        {
            panel.Select(hit.Name, hit.Index, hit.Ordinal);
            Begin(Drag.Move, hit.Box);
        }
        else
        {
            // Drawing keeps the selection, so a radio button drawn next to a selected group joins it.
            if (panel.NewKind is not null) Begin(Drag.Draw, new Rect(_start, _start));
            else panel.Select(null, 0);
        }
    }

    public void Move(PagePointer pointer)
    {
        if (_drag == Drag.None || pointer.Page != _page) return;
        var page = panel.View.PageSize(_page);
        var p = new Point(Math.Clamp(pointer.Point.X, 0, page.Width), Math.Clamp(pointer.Point.Y, 0, page.Height));
        _box = _drag switch
        {
            Drag.Draw => new Rect(_start, p),
            Drag.Move => new Rect(_origin.X + p.X - _start.X, _origin.Y + p.Y - _start.Y, _origin.Width, _origin.Height),
            _ => Resized(p),
        };
        Show();
    }

    public void Release(PagePointer pointer)
    {
        Move(pointer);
        var drag = _drag;
        var box = _box;
        Cancel();
        switch (drag)
        {
            case Drag.Draw when panel.NewKind is { } kind:
                if (box.Width < MinSize && box.Height < MinSize)
                {
                    var (w, h) = FormEdits.DefaultSize(kind);
                    box = new Rect(_start.X, _start.Y, w, h);
                }
                panel.Draw(_page, box);
                break;
            case Drag.Move or Drag.Size when box != _origin && box.Width >= MinSize && box.Height >= MinSize:
                panel.Reshape(_page, box);
                break;
        }
    }

    public void Cancel()
    {
        _drag = Drag.None;
        if (_ghost?.Parent is Canvas canvas) canvas.Children.Remove(_ghost);
        _ghost = null;
    }

    private void Begin(Drag drag, Rect box)
    {
        _drag = drag;
        _origin = _box = box;
    }

    // The handles run clockwise from the top left corner: 0 1 2 across the top, 3 on the right, 4 5 6 across the bottom, 7 on the left.
    private Rect Resized(Point p)
    {
        double left = _origin.Left, top = _origin.Top, right = _origin.Right, bottom = _origin.Bottom;
        if (_handle is 0 or 6 or 7) left = p.X;
        if (_handle is 2 or 3 or 4) right = p.X;
        if (_handle is 0 or 1 or 2) top = p.Y;
        if (_handle is 4 or 5 or 6) bottom = p.Y;
        return new Rect(new Point(left, top), new Point(right, bottom));
    }

    private void Show()
    {
        if (_ghost is null)
        {
            _ghost = new Rectangle { IsHitTestVisible = false, StrokeDashArray = [4, 3] };
            _ghost.SetResourceReference(Shape.StrokeProperty, "AccentFillColorDefaultBrush");
            _ghost.SetResourceReference(Shape.FillProperty, "MarqueeFillBrush");
            panel.View.Overlay(_page).Children.Add(_ghost);
        }
        _ghost.StrokeThickness = 1.5 / FieldFrames.Scale(panel.View);
        _ghost.Width = _box.Width;
        _ghost.Height = _box.Height;
        Canvas.SetLeft(_ghost, _box.X);
        Canvas.SetTop(_ghost, _box.Y);
    }
}
