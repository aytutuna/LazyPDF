using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;
using LazyPDF.App.Viewer;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Pages;

/// <summary>Draws a box on a page with the left button and keeps it, in page space, until the next drag or <see cref="Clear"/>.</summary>
internal sealed class CropTool(IDocumentViewer viewer) : IPagePointerTool
{
    private readonly Rectangle _frame = new()
    {
        Stroke = (Brush)Application.Current.FindResource("AccentFillColorDefaultBrush"),
        Fill = (Brush)Application.Current.FindResource("MarqueeFillBrush"),
        StrokeThickness = 1.5,
        StrokeDashArray = [4, 3],
        IsHitTestVisible = false,
    };

    private int _page = -1;
    private Point _from;
    private bool _dragging;

    public Cursor? Cursor => Cursors.Cross;

    /// <summary>The page the box is on and the box; null until one is drawn.</summary>
    public (int Page, DisplayRect Area)? Box { get; private set; }

    public event EventHandler? BoxChanged;

    public void Press(PagePointer pointer)
    {
        Clear();
        _page = pointer.Page;
        _from = Inside(pointer);
        _dragging = true;
        viewer.Overlay(_page).Children.Add(_frame);
        Draw(_from);
    }

    public void Move(PagePointer pointer)
    {
        if (_dragging && pointer.Page == _page) Draw(Inside(pointer));
    }

    public void Release(PagePointer pointer)
    {
        if (!_dragging) return;
        _dragging = false;
        var to = Inside(pointer);
        double width = Math.Abs(to.X - _from.X), height = Math.Abs(to.Y - _from.Y);
        if (width < 4 || height < 4)
        {
            Clear();
            return;
        }
        Box = (_page, new DisplayRect(Math.Min(_from.X, to.X), Math.Min(_from.Y, to.Y), width, height));
        BoxChanged?.Invoke(this, EventArgs.Empty);
    }

    public void Cancel()
    {
        if (_dragging) Clear();
    }

    public void Clear()
    {
        _dragging = false;
        if (_page >= 0 && _frame.Parent is Panel parent) parent.Children.Remove(_frame);
        _page = -1;
        if (Box is null) return;
        Box = null;
        BoxChanged?.Invoke(this, EventArgs.Empty);
    }

    private Point Inside(PagePointer pointer)
    {
        var size = viewer.PageSize(_page);
        return new Point(Math.Clamp(pointer.Point.X, 0, size.Width), Math.Clamp(pointer.Point.Y, 0, size.Height));
    }

    private void Draw(Point to)
    {
        Canvas.SetLeft(_frame, Math.Min(_from.X, to.X));
        Canvas.SetTop(_frame, Math.Min(_from.Y, to.Y));
        _frame.Width = Math.Abs(to.X - _from.X);
        _frame.Height = Math.Abs(to.Y - _from.Y);
    }
}
