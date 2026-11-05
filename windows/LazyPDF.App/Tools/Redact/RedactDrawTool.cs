using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;
using LazyPDF.App.Viewer;

namespace LazyPDF.App.Tools.Redact;

/// <summary>Takes the pointer to drag a box over a page; the box is reported in page space when the button is let go.</summary>
public sealed class RedactDrawTool(IDocumentViewer viewer, Action<int, Point, Point> boxDrawn) : IPagePointerTool
{
    private const double Smallest = 4;

    private static readonly Size KeyBox = new(160, 24);

    private PageOverlay? _layer;
    private Rectangle? _preview;
    private int _page;
    private Point _from;

    public Cursor? Cursor => Cursors.Cross;

    public void Press(PagePointer pointer)
    {
        Cancel();
        _page = pointer.Page;
        _from = Clamp(pointer.Page, pointer.Point);
        _layer = viewer.Overlay(pointer.Page);
        _preview = new Rectangle
        {
            Stroke = new SolidColorBrush(Color.FromRgb(0xC4, 0x2B, 0x1C)),
            StrokeThickness = 1,
            StrokeDashArray = [4, 3],
            Fill = new SolidColorBrush(Color.FromArgb(0x30, 0xC4, 0x2B, 0x1C)),
            IsHitTestVisible = false,
        };
        _layer.Children.Add(_preview);
        Place(_from);
    }

    public void Move(PagePointer pointer)
    {
        if (_preview is null || !pointer.Pressed || pointer.Page != _page) return;
        Place(Clamp(_page, pointer.Point));
    }

    public void Release(PagePointer pointer)
    {
        if (_preview is null) return;
        var to = Clamp(_page, pointer.Point);
        int page = _page;
        var from = _from;
        Cancel();
        // The keyboard sends a click, which gets a box of the usual size.
        if (pointer.FromKeys && Math.Abs(to.X - from.X) < Smallest && Math.Abs(to.Y - from.Y) < Smallest) to = Clamp(page, new Point(from.X + KeyBox.Width, from.Y + KeyBox.Height));
        var box = new Rect(from, to);
        if (box.Width >= Smallest && box.Height >= Smallest) boxDrawn(page, from, to);
    }

    public void Cancel()
    {
        if (_preview is not null) _layer?.Children.Remove(_preview);
        _preview = null;
        _layer = null;
    }

    private void Place(Point to)
    {
        var box = new Rect(_from, to);
        Canvas.SetLeft(_preview, box.X);
        Canvas.SetTop(_preview, box.Y);
        _preview!.Width = box.Width;
        _preview.Height = box.Height;
    }

    private Point Clamp(int page, Point point)
    {
        var size = viewer.PageSize(page);
        return new Point(Math.Clamp(point.X, 0, size.Width), Math.Clamp(point.Y, 0, size.Height));
    }
}
