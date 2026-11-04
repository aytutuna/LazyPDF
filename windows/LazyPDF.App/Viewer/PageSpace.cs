using System.Windows;
using System.Windows.Media;

namespace LazyPDF.App.Viewer;

/// <summary>
/// The coordinates the viewer and the tools share. <b>Page space</b> is the page as it is shown before the
/// viewer rotates it: points (1/72 inch), origin at the top left of the crop box with /Rotate applied, y down.
/// It is what <c>PageGeometry</c> calls display space. <b>View space</b> is device independent pixels in the
/// viewer's element. A rotation is 0, 90, 180 or 270 degrees clockwise.
/// </summary>
public static class PageSpace
{
    /// <summary>Device independent pixels in one point at 100 %: the page shows at the size it prints.</summary>
    public const double DipPerPoint = 96.0 / 72.0;

    /// <summary>The nearest multiple of 90 in 0 to 270.</summary>
    public static int NormalizeRotation(int degrees) => ((int)Math.Round(degrees / 90.0) % 4 + 4) % 4 * 90;

    /// <summary>The size of a page of <paramref name="page"/> points once rotated and scaled by <paramref name="scale"/> (pixels per point).</summary>
    public static Size Shown(Size page, int rotation, double scale) =>
        rotation is 90 or 270 ? new Size(page.Height * scale, page.Width * scale) : new Size(page.Width * scale, page.Height * scale);

    /// <summary>
    /// Takes a point of the page to the plane the page is drawn in. <paramref name="origin"/> is where the top left
    /// of the page as rotated lands; <paramref name="scale"/> is pixels per point.
    /// </summary>
    public static Matrix ToView(Size page, int rotation, double scale, Point origin)
    {
        double k = scale;
        return rotation switch
        {
            90 => new Matrix(0, k, -k, 0, origin.X + page.Height * k, origin.Y),
            180 => new Matrix(-k, 0, 0, -k, origin.X + page.Width * k, origin.Y + page.Height * k),
            270 => new Matrix(0, -k, k, 0, origin.X, origin.Y + page.Width * k),
            _ => new Matrix(k, 0, 0, k, origin.X, origin.Y),
        };
    }

    /// <summary>The way back: a point of the plane to the page, whether or not it lies on the page.</summary>
    public static Matrix ToPage(Matrix toView)
    {
        toView.Invert();
        return toView;
    }

    /// <summary>The smallest rectangle holding <paramref name="rect"/> once <paramref name="matrix"/> is applied.</summary>
    public static Rect Transform(Matrix matrix, Rect rect)
    {
        var a = matrix.Transform(rect.TopLeft);
        var b = matrix.Transform(rect.BottomRight);
        return new Rect(a, b);
    }
}
