using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;
using LazyPDF.App.Viewer;

namespace LazyPDF.App.Tools.FillSign;

/// <summary>
/// Takes one click, or one drag when the thing placed has a shape to draw, on a page. The drag shows a dashed
/// outline of the box the picture will fill.
/// </summary>
internal sealed class PlacementTool(IDocumentViewer viewer, double aspect, Action<int, Point, Point?> placed, Action stopped) : IPagePointerTool
{
    private const double ClickSlop = 4;

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
        if (!pointer.Pressed || pointer.Page != _page || aspect <= 0) return;
        var box = FillSignPlacement.FromDrag(_from, pointer.Point, aspect, viewer.PageSize(_page));
        if (_outline is null)
        {
            _outline = new Rectangle
            {
                StrokeDashArray = [4, 3],
                IsHitTestVisible = false,
            };
            _outline.SetResourceReference(Shape.StrokeProperty, "AccentFillColorDefaultBrush");
            viewer.Overlay(_page).Children.Add(_outline);
        }
        _outline.StrokeThickness = 1.5 / Math.Max(viewer.Zoom, 0.1);
        System.Windows.Controls.Canvas.SetLeft(_outline, box.X);
        System.Windows.Controls.Canvas.SetTop(_outline, box.Y);
        _outline.Width = box.Width;
        _outline.Height = box.Height;
    }

    public void Release(PagePointer pointer)
    {
        if (_page < 0) return;
        int page = _page;
        bool dragged = aspect > 0 && pointer.Page == page && (pointer.Point - _from).Length > ClickSlop;
        Clear();
        placed(page, _from, dragged ? pointer.Point : null);
    }

    public void Cancel()
    {
        Clear();
        stopped();
    }

    private void Clear()
    {
        if (_outline is not null) viewer.Overlay(_page).Children.Remove(_outline);
        _outline = null;
        _page = -1;
    }
}
