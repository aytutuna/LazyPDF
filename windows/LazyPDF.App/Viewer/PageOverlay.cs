using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace LazyPDF.App.Viewer;

/// <summary>
/// A layer a tool puts its elements on, over one page. It is a <see cref="Canvas"/> in page space: units are
/// points, (0, 0) is the top left of the page as shown before the viewer rotates it, y grows downwards. Position
/// elements with <see cref="Canvas.SetLeft"/> and <see cref="Canvas.SetTop"/>. The viewer scales and rotates the
/// whole layer with the page, so a 1 point line is 1 point at 100 % and thicker on screen at 400 %; divide by the zoom
/// for a line that keeps its width. Elements may draw past the page edge; the PageSurface still clips to the viewport. The layer takes part in the visual tree only while its
/// page is near the window, and keeps its children the rest of the time. Elements that should not catch the pointer
/// need <c>IsHitTestVisible = false</c>.
/// </summary>
public sealed class PageOverlay : Canvas
{
    internal PageOverlay(int page, Size size)
    {
        Page = page;
        Width = size.Width;
        Height = size.Height;
        ClipToBounds = false;
    }

    /// <summary>The page this layer belongs to, 0-based.</summary>
    public int Page { get; }

    /// <summary>
    /// Turns a box against the viewer's rotation so its text reads upright. It turns about the centre of its first
    /// size, so the corner that is at the screen's top left stays there when the box grows.
    /// </summary>
    public static void KeepUpright(FrameworkElement box, int viewRotation, Size first)
    {
        box.RenderTransformOrigin = new Point(0, 0);
        box.RenderTransform = viewRotation == 0 ? null : new RotateTransform(-viewRotation, first.Width / 2, first.Height / 2);
    }

    /// <summary>The page-space rectangle a box covers once it is turned upright on a view turned by <paramref name="viewRotation"/>: same centre, width and height swapped at 90 and 270.</summary>
    public static Rect UprightBounds(Rect box, int viewRotation)
    {
        if (viewRotation % 180 == 0) return box;
        double cx = box.X + box.Width / 2, cy = box.Y + box.Height / 2;
        return new Rect(cx - box.Height / 2, cy - box.Width / 2, box.Height, box.Width);
    }

    /// <summary>
    /// Moves a box so that its upright footprint lies in the page. On an axis where it does not fit, the footprint
    /// is aligned to the page edge that is at the screen's top or left.
    /// </summary>
    public static Rect Place(Rect box, Size page, int viewRotation)
    {
        var bounds = UprightBounds(box, viewRotation);
        int turn = ((viewRotation % 360) + 360) % 360;
        // The corner at the screen's top left is on the page's right edge from 180 on, and on its bottom edge at 90 and 180
        bool atRight = turn is 180 or 270, atBottom = turn is 90 or 180;
        double x = Fit(bounds.X, bounds.Width, page.Width, atRight);
        double y = Fit(bounds.Y, bounds.Height, page.Height, atBottom);
        return new Rect(box.X + x - bounds.X, box.Y + y - bounds.Y, box.Width, box.Height);
    }

    private static double Fit(double start, double length, double room, bool atEnd) =>
        length > room ? (atEnd ? room - length : 0) : Math.Clamp(start, 0, room - length);

    /// <summary>
    /// The width and height an upright box may grow to, right and down on the screen, measured from the corner of
    /// its footprint that sits at the screen's top left, to the page edges in those two directions.
    /// </summary>
    public static Size Room(Rect placed, Size page, int viewRotation)
    {
        var b = UprightBounds(placed, viewRotation);
        return (((viewRotation % 360) + 360) % 360) switch
        {
            90 => new Size(b.Bottom, page.Width - b.X),
            180 => new Size(b.Right, b.Bottom),
            270 => new Size(page.Height - b.Y, b.Right),
            _ => new Size(page.Width - b.X, page.Height - b.Y),
        };
    }
}
