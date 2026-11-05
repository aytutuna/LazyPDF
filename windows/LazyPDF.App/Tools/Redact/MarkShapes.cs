using System.Windows;
using System.Windows.Media;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Redact;

/// <summary>Takes marks between page space (what the viewer shows) and PDF user space (what the engine removes).</summary>
public static class MarkShapes
{
    /// <summary>A mark over a box dragged between two points of page space. Its quad reads left to right as shown, on a turned page too.</summary>
    public static RedactionMark Box(int page, PageGeometry geometry, Point from, Point to)
    {
        var box = new Rect(from, to);
        var (x0, y0) = geometry.ToUser(box.Left, box.Bottom);
        var (x1, y1) = geometry.ToUser(box.Right, box.Bottom);
        var (x2, y2) = geometry.ToUser(box.Right, box.Top);
        var (x3, y3) = geometry.ToUser(box.Left, box.Top);
        return new RedactionMark(page, [new TextQuad(x0, y0, x1, y1, x2, y2, x3, y3)]);
    }

    public static PointCollection Outline(PageGeometry geometry, TextQuad quad)
    {
        var corners = new[] { (quad.X0, quad.Y0), (quad.X1, quad.Y1), (quad.X2, quad.Y2), (quad.X3, quad.Y3) };
        return [.. corners.Select(c =>
        {
            var (x, y) = geometry.ToDisplay(c.Item1, c.Item2);
            return new Point(x, y);
        })];
    }

    /// <summary>Where the mark starts, in page space, for the viewer to bring into view.</summary>
    public static Rect Where(PageGeometry geometry, RedactionMark mark)
    {
        var box = geometry.ToDisplay(mark.Quads[0].Bounds);
        return new Rect(box.X, box.Y, box.Width, box.Height);
    }
}
