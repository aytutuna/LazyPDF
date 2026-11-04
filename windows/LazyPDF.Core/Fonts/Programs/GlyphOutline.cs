namespace LazyPDF.Core;

public enum OutlineOp { Move, Line, Quad, Cubic, Close }

/// <summary>
/// One step of a glyph outline in font units. (X, Y) is where the step ends; (X1, Y1) is the control
/// point of a quadratic curve or the first of a cubic one, (X2, Y2) the second of a cubic one.
/// </summary>
public readonly record struct OutlineSegment(OutlineOp Op, double X, double Y, double X1 = 0, double Y1 = 0, double X2 = 0, double Y2 = 0);

/// <summary>A glyph's outline in font units, y up. TrueType gives lines and quadratics, CFF and Type 1 lines and cubics.</summary>
public sealed class GlyphOutline
{
    private readonly List<OutlineSegment> _segments = [];

    public IReadOnlyList<OutlineSegment> Segments => _segments;

    public bool IsEmpty => _segments.Count == 0;

    internal void Add(OutlineSegment segment) => _segments.Add(segment);

    internal void MoveTo(double x, double y) => _segments.Add(new(OutlineOp.Move, x, y));

    internal void LineTo(double x, double y) => _segments.Add(new(OutlineOp.Line, x, y));

    internal void QuadTo(double x1, double y1, double x, double y) => _segments.Add(new(OutlineOp.Quad, x, y, x1, y1));

    internal void CubicTo(double x1, double y1, double x2, double y2, double x, double y) =>
        _segments.Add(new(OutlineOp.Cubic, x, y, x1, y1, x2, y2));

    internal void Close() => _segments.Add(new(OutlineOp.Close, 0, 0));

    /// <summary>The box around the points of the outline, control points included, or null when it is empty.</summary>
    public GlyphBounds? Bounds()
    {
        double minX = double.MaxValue, minY = double.MaxValue, maxX = double.MinValue, maxY = double.MinValue;
        var any = false;
        foreach (var s in _segments)
        {
            if (s.Op == OutlineOp.Close) continue;
            any = true;
            Grow(s.X, s.Y);
            if (s.Op is OutlineOp.Quad or OutlineOp.Cubic) Grow(s.X1, s.Y1);
            if (s.Op == OutlineOp.Cubic) Grow(s.X2, s.Y2);
        }
        return any ? new GlyphBounds(minX, minY, maxX, maxY) : null;

        void Grow(double x, double y)
        {
            if (x < minX) minX = x;
            if (x > maxX) maxX = x;
            if (y < minY) minY = y;
            if (y > maxY) maxY = y;
        }
    }
}

public readonly record struct GlyphBounds(double XMin, double YMin, double XMax, double YMax);
