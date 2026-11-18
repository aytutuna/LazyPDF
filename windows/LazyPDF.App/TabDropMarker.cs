using System.Windows;
using System.Windows.Documents;
using System.Windows.Media;

namespace LazyPDF.App;

/// <summary>A vertical line over the tab strip showing where a tab dragged in from another window will go.</summary>
internal sealed class TabDropMarker : Adorner
{
    private readonly Pen _pen;
    private double _x;

    public TabDropMarker(UIElement strip) : base(strip)
    {
        IsHitTestVisible = false;
        _pen = new Pen(strip is FrameworkElement e && e.TryFindResource("AccentFillColorDefaultBrush") is Brush brush ? brush : Brushes.DodgerBlue, 2);
        _pen.Freeze();
    }

    public void MoveTo(double x)
    {
        _x = x;
        InvalidateVisual();
    }

    protected override void OnRender(DrawingContext drawing) =>
        drawing.DrawLine(_pen, new Point(_x, 2), new Point(_x, Math.Max(2, ((FrameworkElement)AdornedElement).ActualHeight - 2)));
}
