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

    /// <summary>Turns a box against the viewer's rotation so its text reads upright.</summary>
    public static void KeepUpright(FrameworkElement box, int viewRotation)
    {
        box.RenderTransformOrigin = new Point(0.5, 0.5);
        box.RenderTransform = viewRotation == 0 ? null : new RotateTransform(-viewRotation);
    }
}
