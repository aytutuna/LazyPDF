// What the window paints on the pages: a box for each difference in the list, and in overlay mode the picture
// of how the new page differs from the old one. Both are made for the pages in view only.

using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;
using LazyPDF.App.Services;
using LazyPDF.App.Viewer;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Compare;

internal sealed partial class CompareWindow
{
    private const int MaxImages = 12;

    private static readonly Color Green = Color.FromRgb(46, 160, 67);
    private static readonly Color Red = Color.FromRgb(209, 52, 56);
    private static readonly Color Amber = Color.FromRgb(245, 160, 0);
    private static readonly Color Blue = Color.FromRgb(0, 120, 212);

    private readonly Dictionary<int, List<(Rect Box, Color Color)>> _oldMarks = [];
    private readonly Dictionary<int, List<(Rect Box, Color Color)>> _newMarks = [];
    private readonly Dictionary<int, Canvas> _oldLayers = [];
    private readonly Dictionary<int, Canvas> _newLayers = [];
    private readonly Dictionary<Color, (Brush Fill, Brush Stroke)> _brushes = [];
    private readonly Dictionary<int, Image> _images = [];
    private readonly HashSet<int> _tried = [];
    private bool _closed;
    private bool _loading;
    private bool _again;

    private void DrawMarks()
    {
        Clear(_old, _oldLayers);
        Clear(_new, _newLayers);
        _oldMarks.Clear();
        _newMarks.Clear();
        foreach (var row in _rows)
        {
            var color = row.Kind switch
            {
                ChangeKind.Added => Green,
                ChangeKind.Removed => Red,
                null => Blue,
                _ => Amber,
            };
            Group(_oldMarks, row.OldPage, row.OldBoxes, color);
            Group(_newMarks, row.NewPage, row.NewBoxes, color);
        }
        DrawVisible();
    }

    private static void Group(Dictionary<int, List<(Rect Box, Color Color)>> marks, int page, IReadOnlyList<Rect> boxes, Color color)
    {
        if (page < 0 || boxes.Count == 0) return;
        if (!marks.TryGetValue(page, out var list)) marks[page] = list = [];
        foreach (var box in boxes) list.Add((box, color));
    }

    private static void Clear(IDocumentViewer viewer, Dictionary<int, Canvas> layers)
    {
        foreach (var (page, layer) in layers) viewer.Overlay(page).Children.Remove(layer);
        layers.Clear();
    }

    private void DrawVisible()
    {
        if (_closed) return;
        DrawVisible(_old, _oldMarks, _oldLayers);
        DrawVisible(_new, _newMarks, _newLayers);
    }

    private void DrawVisible(IDocumentViewer viewer, Dictionary<int, List<(Rect Box, Color Color)>> marks, Dictionary<int, Canvas> layers)
    {
        var visible = viewer.VisiblePages;
        foreach (int page in layers.Keys.Where(p => !visible.Contains(p)).ToList())
        {
            viewer.Overlay(page).Children.Remove(layers[page]);
            layers.Remove(page);
        }
        foreach (int page in visible)
        {
            if (page >= viewer.PageCount || layers.ContainsKey(page) || !marks.TryGetValue(page, out var list)) continue;
            var layer = new Canvas { IsHitTestVisible = false };
            foreach (var (box, color) in list) layer.Children.Add(Mark(box, color));
            layers[page] = layer;
            viewer.Overlay(page).Children.Add(layer);
        }
    }

    private Rectangle Mark(Rect box, Color color)
    {
        if (!_brushes.TryGetValue(color, out var brushes))
        {
            var fill = new SolidColorBrush(Color.FromArgb(70, color.R, color.G, color.B));
            var stroke = new SolidColorBrush(Color.FromArgb(200, color.R, color.G, color.B));
            fill.Freeze();
            stroke.Freeze();
            _brushes[color] = brushes = (fill, stroke);
        }
        // Text that was removed leaves a box of no width: keep it visible.
        double width = Math.Max(box.Width, 3), height = Math.Max(box.Height, 3);
        var mark = new Rectangle { Width = width, Height = height, Fill = brushes.Fill, Stroke = brushes.Stroke, StrokeThickness = 0.75, IsHitTestVisible = false };
        Canvas.SetLeft(mark, box.X - (width - box.Width) / 2);
        Canvas.SetTop(mark, box.Y - (height - box.Height) / 2);
        return mark;
    }

    private void Viewer_ViewChanged(object? sender, EventArgs e)
    {
        DrawVisible();
        if (_overlay) LoadOverlays();
    }

    private void ShowOverlays()
    {
        foreach (var image in _images.Values) image.Visibility = _overlay ? Visibility.Visible : Visibility.Collapsed;
        if (_overlay) LoadOverlays();
    }

    // One loop at a time: a view change while it runs asks it to look again, since the renderers do one page at a time.
    private async void LoadOverlays()
    {
        if (_loading)
        {
            _again = true;
            return;
        }
        _loading = true;
        try
        {
            do
            {
                _again = false;
                foreach (int page in _new.VisiblePages.ToList())
                {
                    if (_closed || !_overlay) return;
                    if (_images.ContainsKey(page) || !_tried.Add(page)) continue;
                    PdfRgbaImage? picture;
                    try
                    {
                        picture = await Task.Run(() => _session.Overlay(page));
                    }
                    catch (ArgumentException)
                    {
                        continue;
                    }
                    if (_closed || picture is null) continue;
                    if (!_new.VisiblePages.Contains(page))
                    {
                        _tried.Remove(page);
                        continue;
                    }
                    AddImage(page, picture);
                }
            }
            while (_again);
        }
        finally
        {
            _loading = false;
        }
    }

    private void AddImage(int page, PdfRgbaImage picture)
    {
        var size = _new.PageSize(page);
        var image = new Image
        {
            Source = Pixels.ToBitmap(picture),
            Width = size.Width,
            Height = size.Height,
            Stretch = Stretch.Fill,
            IsHitTestVisible = false,
            Visibility = _overlay ? Visibility.Visible : Visibility.Collapsed,
        };
        _new.Overlay(page).Children.Insert(0, image);
        _images[page] = image;
        while (_images.Count > MaxImages)
        {
            int far = _images.Keys.MaxBy(p => Math.Abs(p - page));
            _new.Overlay(far).Children.Remove(_images[far]);
            _images.Remove(far);
            _tried.Remove(far);
        }
    }
}
