using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;
using LazyPDF.App.Viewer;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.EditContent;

// What the surface draws on the pages: one canvas of its own over each page, drawn again whenever the selection,
// the gesture or the zoom changes. Line widths are divided by the scale so they stay the same on screen.
internal sealed partial class EditSurface
{
    private readonly Dictionary<int, Canvas> _chrome = [];
    private PdfReference? _activeLink;
    private int _areaPage = -1;
    private Rect _area;

    private static Brush Accent => (Brush)Application.Current.FindResource("AccentFillColorDefaultBrush");

    private static Brush Tint => (Brush)Application.Current.FindResource("MarqueeFillBrush");

    /// <summary>The link being changed, drawn heavier than the others.</summary>
    public PdfReference? ActiveLink
    {
        get => _activeLink;
        set
        {
            _activeLink = value;
            RedrawAll();
        }
    }

    /// <summary>The surface has the pointer; the viewer's Hand and Select buttons take it away.</summary>
    public bool IsActive => ReferenceEquals(viewer.PointerTool, this);

    public void Attach()
    {
        viewer.ViewChanged += Viewer_ViewChanged;
        viewer.PointerTool = this;
    }

    /// <summary>Outlines an area the person dragged and the panel has not used yet; a negative page takes it away.</summary>
    public void ShowArea(int page, PdfRect? area)
    {
        int old = _areaPage;
        _areaPage = area is null ? -1 : page;
        if (area is { } a && page >= 0) _area = PageRect(page, a);
        Redraw(old);
        Redraw(_areaPage);
    }

    private void Viewer_ViewChanged(object? sender, EventArgs e) => RedrawAll();

    private void RedrawAll()
    {
        foreach (int page in new HashSet<int>([.. viewer.VisiblePages, .. _chrome.Keys, Page])) Redraw(page);
    }

    private Canvas ChromeOf(int page)
    {
        var overlay = viewer.Overlay(page);
        if (!_chrome.TryGetValue(page, out var canvas) || !ReferenceEquals(canvas.Parent, overlay))
        {
            canvas = new Canvas { IsHitTestVisible = false };
            overlay.Children.Add(canvas);
            _chrome[page] = canvas;
        }
        return canvas;
    }

    private void RemoveChrome()
    {
        foreach (var canvas in _chrome.Values) (canvas.Parent as Panel)?.Children.Remove(canvas);
        _chrome.Clear();
    }

    private void Redraw(int page)
    {
        if (page < 0 || page >= viewer.PageCount) return;
        var canvas = ChromeOf(page);
        canvas.Children.Clear();
        double scale = ViewScale.Of(viewer, page), line = 1.5 / scale;
        if (_mode == EditMode.Link) DrawLinks(canvas, page, line);
        if (page == Page && _selected.Count > 0 && _mode != EditMode.Crop) DrawSelection(canvas, scale);
        if (page == _areaPage) Place(canvas, Outline(_area, line, dashed: true, Tint));
        if (_gesture == Gesture.Band && _moved && page == _gesturePage)
        {
            Place(canvas, Outline(Rect.Union(new Rect(_start, _start), new Rect(_now, _now)), line, dashed: _mode != EditMode.Select, Tint));
        }
    }

    private void DrawSelection(Canvas canvas, double scale)
    {
        double line = 1.5 / scale;
        var bounds = SelectionBounds();
        if (bounds.IsEmpty) return;
        if (_selected.Count > 1)
        {
            foreach (int id in _selected)
            {
                if (edits.Object(Page, id) is { } o) Place(canvas, Outline(PageRect(Page, o.Bounds), line * 0.6, dashed: true, null));
            }
        }
        if (_gesture == Gesture.Move && _moved)
        {
            bounds.Offset(_now - _start);
            Place(canvas, Outline(bounds, line, dashed: true, Tint));
            return;
        }
        if (_gesture == Gesture.Resize && _moved)
        {
            Place(canvas, Outline(Resized(), line, dashed: true, Tint));
            return;
        }
        Place(canvas, Outline(bounds, line, dashed: false, null));
        double size = 8 / scale;
        foreach (var at in Handles(bounds))
        {
            var handle = new Rectangle { Width = size, Height = size, Fill = Brushes.White, Stroke = Accent, StrokeThickness = line };
            Canvas.SetLeft(handle, at.X - size / 2);
            Canvas.SetTop(handle, at.Y - size / 2);
            canvas.Children.Add(handle);
        }
    }

    private void DrawLinks(Canvas canvas, int page, double line)
    {
        foreach (var link in edits.Links(page))
        {
            bool active = link.Reference is { } r && r.Equals(_activeLink);
            Place(canvas, Outline(PageRect(page, link.Rect), active ? line * 1.6 : line * 0.7, dashed: !active, active ? Tint : null));
        }
    }

    private static Rectangle Outline(Rect r, double thickness, bool dashed, Brush? fill)
    {
        var shape = new Rectangle { Width = Math.Max(r.Width, 0), Height = Math.Max(r.Height, 0), Stroke = Accent, StrokeThickness = thickness, Fill = fill };
        if (dashed) shape.StrokeDashArray = [4, 3];
        Canvas.SetLeft(shape, r.X);
        Canvas.SetTop(shape, r.Y);
        return shape;
    }

    private static void Place(Canvas canvas, UIElement element) => canvas.Children.Add(element);
}

/// <summary>Screen pixels to a point of page space.</summary>
internal static class ViewScale
{
    public static double Of(IDocumentViewer viewer, int page)
    {
        double scale = viewer.PageToView(page) is { } m ? Math.Sqrt(m.M11 * m.M11 + m.M12 * m.M12) : viewer.Zoom * 96 / 72;
        return scale > 0.01 ? scale : 1;
    }
}
