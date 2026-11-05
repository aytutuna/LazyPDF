using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;
using LazyPDF.App.Viewer;

namespace LazyPDF.App.Tools.Measure;

/// <summary>Draws the measurements waiting to be written and the one being drawn on the pages' overlay layers.</summary>
internal sealed class MeasureOverlay(IDocumentViewer viewer, MeasureTool tool)
{
    private static readonly Brush Ink = Frozen(Color.FromRgb(13, 97, 191));
    private static readonly Brush Halo = Frozen(Color.FromArgb(200, 255, 255, 255));
    private static readonly Brush Wash = Frozen(Color.FromArgb(40, 13, 97, 191));

    private readonly List<(Canvas Layer, UIElement Element)> _drawn = [];

    public void Clear()
    {
        foreach (var (layer, element) in _drawn) layer.Children.Remove(element);
        _drawn.Clear();
    }

    public void Draw(IReadOnlyList<MeasureItem> items, MeasureScale scale)
    {
        Clear();
        foreach (var item in items)
        {
            Shape(item.Page, item.Points, item.Kind != MeasureKind.Distance, dashed: false, item.Kind == MeasureKind.Area, item.Value(scale), item.Middle);
        }

        if (tool.Page >= 0 && tool.Points.Count > 0)
        {
            var points = tool.Points.ToList();
            bool live = tool.HoverPage == tool.Page && tool.Hover is not null;
            if (live) points.Add(tool.Hover!.Value);
            bool closed = tool.Kind != MeasureKind.Distance && points.Count > 2;
            string? text = points.Count > 1 ? new MeasureItem(tool.Kind, tool.Page, points).Value(scale) : null;
            Shape(tool.Page, points, closed, dashed: live, closed && tool.Kind == MeasureKind.Area, text, points[^1]);
        }
        if (tool.Snapped && tool.Hover is { } at) Marker(tool.HoverPage, at);
    }

    private void Shape(int page, IReadOnlyList<Point> points, bool closed, bool dashed, bool filled, string? label, Point at)
    {
        double scale = tool.Scale(page);
        if (scale <= 0 || points.Count == 0) return;
        var layer = viewer.Overlay(page);
        var collection = new PointCollection(points);
        foreach (var (brush, width) in new[] { (Halo, 4.5), (Ink, 1.5) })
        {
            Shape shape = closed
                ? new Polygon { Points = collection, Fill = filled && brush == Ink ? Wash : null }
                : new Polyline { Points = collection };
            shape.Stroke = brush;
            shape.StrokeThickness = width / scale;
            shape.StrokeLineJoin = PenLineJoin.Round;
            if (dashed && brush == Ink) shape.StrokeDashArray = [4, 3];
            Add(layer, shape);
        }
        double dot = 3 / scale;
        foreach (var p in points)
        {
            var ellipse = new Ellipse { Width = dot * 2, Height = dot * 2, Fill = Ink, Stroke = Halo, StrokeThickness = 1 / scale };
            Canvas.SetLeft(ellipse, p.X - dot);
            Canvas.SetTop(ellipse, p.Y - dot);
            Add(layer, ellipse);
        }
        if (label is null) return;
        var text = new TextBlock
        {
            Text = label,
            FontSize = 12 / scale,
            Foreground = Ink,
            Background = Halo,
            Padding = new Thickness(3 / scale, 1 / scale, 3 / scale, 1 / scale),
        };
        Canvas.SetLeft(text, at.X + 6 / scale);
        Canvas.SetTop(text, at.Y - 18 / scale);
        Add(layer, text);
    }

    private void Marker(int page, Point at)
    {
        double scale = tool.Scale(page);
        if (scale <= 0) return;
        double side = 10 / scale;
        var square = new Rectangle { Width = side, Height = side, Stroke = Ink, StrokeThickness = 1.5 / scale };
        Canvas.SetLeft(square, at.X - side / 2);
        Canvas.SetTop(square, at.Y - side / 2);
        Add(viewer.Overlay(page), square);
    }

    private void Add(Canvas layer, UIElement element)
    {
        element.IsHitTestVisible = false;
        layer.Children.Add(element);
        _drawn.Add((layer, element));
    }

    private static Brush Frozen(Color color)
    {
        var brush = new SolidColorBrush(color);
        brush.Freeze();
        return brush;
    }
}
