using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;
using LazyPDF.App.Viewer;

namespace LazyPDF.App.Tools.Certificates;

/// <summary>Takes a drag on a page as the box where a visible signature goes.</summary>
internal sealed class SignatureBoxTool(IDocumentViewer viewer, Action<int, Rect> drawn, Action stopped) : IPagePointerTool
{
    private const double MinSide = 20;

    private int _page = -1;
    private Point _from;
    private Rectangle? _outline;

    public Cursor? Cursor => Cursors.Cross;

    public void Press(PagePointer pointer)
    {
        _page = pointer.Page;
        _from = pointer.Point;
    }

    public void Move(PagePointer pointer)
    {
        if (!pointer.Pressed || pointer.Page != _page) return;
        if (_outline is null)
        {
            _outline = Outline();
            viewer.Overlay(_page).Children.Add(_outline);
        }
        Place(_outline, Box(pointer.Point));
    }

    public void Release(PagePointer pointer)
    {
        if (_page < 0) return;
        int page = _page;
        var box = Box(pointer.Point);
        Clear();
        if (box.Width >= MinSide && box.Height >= MinSide) drawn(page, box);
    }

    public void Cancel()
    {
        Clear();
        stopped();
    }

    /// <summary>A dashed outline for a box on the page, in the accent colour; the caller removes it.</summary>
    public static Rectangle Outline()
    {
        var outline = new Rectangle { StrokeDashArray = [4, 3], StrokeThickness = 1.5, IsHitTestVisible = false };
        outline.SetResourceReference(Shape.StrokeProperty, "AccentFillColorDefaultBrush");
        return outline;
    }

    public static void Place(Rectangle outline, Rect box)
    {
        Canvas.SetLeft(outline, box.X);
        Canvas.SetTop(outline, box.Y);
        outline.Width = box.Width;
        outline.Height = box.Height;
    }

    // Clamped to the page, so a drag past its edge still gives a box that is on it.
    private Rect Box(Point to)
    {
        var size = viewer.PageSize(_page);
        var a = new Point(Math.Clamp(_from.X, 0, size.Width), Math.Clamp(_from.Y, 0, size.Height));
        var b = new Point(Math.Clamp(to.X, 0, size.Width), Math.Clamp(to.Y, 0, size.Height));
        return new Rect(a, b);
    }

    private void Clear()
    {
        if (_outline is not null) viewer.Overlay(_page).Children.Remove(_outline);
        _outline = null;
        _page = -1;
    }
}
