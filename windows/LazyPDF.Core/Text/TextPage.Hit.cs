namespace LazyPDF.Core;

public sealed partial class TextPage
{
    /// <summary>
    /// The character nearest to a point in user space, with its word and line; null when the page
    /// has no text or the nearest one is farther than <paramref name="maxDistance"/> (user space units).
    /// A point inside a character's box has distance 0.
    /// </summary>
    public TextHit? HitTest(double x, double y, double maxDistance = double.PositiveInfinity)
    {
        int line = NearestLine(x, y, out double lineDistance);
        if (line < 0 || lineDistance > maxDistance) return null;
        int index = NearestChar(line, x, y, out double distance);
        if (index < 0 || distance > maxDistance) return null;
        var c = _chars[index];
        return new TextHit(index, c.Word, c.Line, distance);
    }

    /// <summary>
    /// The insertion point nearest to a point, as a character index from 0 to <c>Chars.Count</c>: the
    /// gap before that character. Used with a second one it gives a selection like a text caret does.
    /// </summary>
    public int CaretAt(double x, double y)
    {
        int line = NearestLine(x, y, out _);
        if (line < 0) return 0;
        var (top, bottom) = Extent();
        double shown = _geometry.ToDisplay(x, y).Y;
        if (shown < top) return 0;
        if (shown > bottom) return _chars.Length;
        int index = NearestChar(line, x, y, out _);
        if (index < 0) return _lines[line].Range.Start;
        var c = _chars[index];
        var (cx, cy) = c.Quad.Center;
        var (ax, ay) = ReadingAxis(_lines[line]);
        double along = (x - cx) * ax + (y - cy) * ay;
        return (c.IsRtl ? along < 0 : along > 0) ? index + 1 : index;
    }

    // The vertical extent of the text as shown, so that a point above it or below it can be told from one beside it.
    private (double Top, double Bottom) Extent()
    {
        if (_extent is { } known) return known;
        double top = double.MaxValue, bottom = double.MinValue;
        foreach (var line in _lines)
        {
            var r = _geometry.ToDisplay(line.Bounds);
            top = Math.Min(top, r.Y);
            bottom = Math.Max(bottom, r.Y + r.Height);
        }
        _extent = (top, bottom);
        return (top, bottom);
    }

    // The direction a line is read in, in user space.
    private static (double X, double Y) ReadingAxis(PageLine line)
    {
        var q = line.Quad;
        double x = line.IsVertical ? q.X0 - q.X3 : q.X1 - q.X0, y = line.IsVertical ? q.Y0 - q.Y3 : q.Y1 - q.Y0;
        double length = Math.Sqrt(x * x + y * y);
        return length < 1e-12 ? (1, 0) : (x / length, y / length);
    }

    private int NearestLine(double x, double y, out double distance)
    {
        int best = -1;
        distance = double.MaxValue;
        for (int i = 0; i < _lines.Length; i++)
        {
            var b = _lines[i].Bounds;
            double dx = Math.Max(Math.Max(b.Left - x, x - b.Right), 0), dy = Math.Max(Math.Max(b.Bottom - y, y - b.Top), 0);
            if (Math.Sqrt(dx * dx + dy * dy) - 1e-9 > distance) continue;
            double d = _lines[i].Quad.DistanceTo(x, y);
            if (d < distance)
            {
                distance = d;
                best = i;
            }
        }
        return best;
    }

    private int NearestChar(int line, double x, double y, out double distance)
    {
        int best = -1;
        distance = double.MaxValue;
        var range = _lines[line].Range;
        for (int i = range.Start; i < range.End; i++)
        {
            var q = _chars[i].Quad;
            double d = q.DistanceTo(x, y);
            if (d < distance || (d == distance && best >= 0 && _chars[best].IsSpace && !_chars[i].IsSpace))
            {
                distance = d;
                best = i;
            }
        }
        return best;
    }
}
