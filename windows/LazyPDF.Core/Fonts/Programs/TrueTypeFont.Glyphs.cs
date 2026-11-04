using static LazyPDF.Core.FontBytes;

namespace LazyPDF.Core;

public sealed partial class TrueTypeFont
{
    private const int MaxCompositeDepth = 8;
    private const int MaxComponents = 512;
    private const int MaxPoints = 100_000;

    private struct Pt(double x, double y, bool on)
    {
        public double X = x, Y = y;
        public bool On = on;
    }

    private sealed class Contours
    {
        public readonly List<Pt> Points = [];
        public readonly List<int> Ends = [];
    }

    /// <summary>The glyph's data in 'glyf', empty for a blank glyph or one whose loca entry is out of range.</summary>
    internal ReadOnlySpan<byte> GlyphData(int glyphId)
    {
        if (glyphId < 0 || glyphId >= GlyphCount) return default;
        var loca = Table("loca");
        var glyf = Table("glyf");
        int start, end;
        if (_locaFormat == 0)
        {
            start = U16(loca, 2 * glyphId) * 2;
            end = U16(loca, 2 * glyphId + 2) * 2;
        }
        else
        {
            start = Offset32(loca, 4 * glyphId);
            end = Offset32(loca, 4 * glyphId + 4);
        }
        end = Math.Min(end, glyf.Length);
        return start < end ? glyf[start..end] : default;
    }

    /// <summary>Box of the glyph in font units, null for an empty glyph. TrueType reads the glyph header, CFF measures the outline.</summary>
    public GlyphBounds? GetBounds(int glyphId)
    {
        if (Cff != null) return Cff.GetOutline(glyphId)?.Bounds();
        var g = GlyphData(glyphId);
        if (g.Length < 10) return null;
        return new GlyphBounds(I16(g, 2), I16(g, 4), I16(g, 6), I16(g, 8));
    }

    /// <summary>
    /// The outline of a glyph, composites resolved, in font units. Empty for a blank glyph, null when the glyph
    /// does not exist or the font has no outlines. Broken glyph data gives an empty outline.
    /// </summary>
    public GlyphOutline? GetOutline(int glyphId)
    {
        if (glyphId < 0 || glyphId >= GlyphCount) return null;
        if (Cff != null) return Cff.GetOutline(glyphId);
        if (!HasOutlines) return null;

        var budget = MaxComponents;
        var points = MaxPoints;
        var outline = new GlyphOutline();
        if (Load(glyphId, 0, ref budget, ref points) is { } c) Emit(outline, c);
        return outline;
    }

    private Contours? Load(int glyphId, int depth, ref int budget, ref int points)
    {
        var g = GlyphData(glyphId);
        if (g.Length < 10) return new Contours();
        var n = I16(g, 0);
        if (n < 0) return LoadComposite(g, depth, ref budget, ref points);
        var simple = LoadSimple(g, n);
        // A glyph that components repeat is counted each time: the points are built for each of them.
        return simple is not null && (points -= simple.Points.Count) >= 0 ? simple : null;
    }

    private static Contours? LoadSimple(ReadOnlySpan<byte> g, int contourCount)
    {
        var result = new Contours();
        if (contourCount == 0) return result;
        var p = 10;
        var last = -1;
        for (var i = 0; i < contourCount; i++)
        {
            var end = U16(g, p);
            if (end < last) return null;
            result.Ends.Add(end);
            last = end;
            p += 2;
        }
        var count = last + 1;
        p += 2 + U16(g, p);
        if (p > g.Length) return null;

        var flags = new byte[count];
        for (var i = 0; i < count;)
        {
            if (p >= g.Length) return null;
            var f = g[p++];
            flags[i++] = f;
            if ((f & 8) == 0) continue;
            if (p >= g.Length) return null;
            for (var r = g[p++]; r > 0 && i < count; r--) flags[i++] = f;
        }

        var xs = new double[count];
        var ys = new double[count];
        if (!ReadCoords(g, ref p, flags, xs, 0x02, 0x10) || !ReadCoords(g, ref p, flags, ys, 0x04, 0x20)) return null;

        result.Points.EnsureCapacity(count);
        for (var i = 0; i < count; i++) result.Points.Add(new Pt(xs[i], ys[i], (flags[i] & 1) != 0));
        return result;
    }

    private static bool ReadCoords(ReadOnlySpan<byte> g, ref int p, byte[] flags, double[] into, int shortBit, int sameBit)
    {
        var v = 0;
        for (var i = 0; i < flags.Length; i++)
        {
            var f = flags[i];
            if ((f & shortBit) != 0)
            {
                if (p >= g.Length) return false;
                var d = g[p++];
                v += (f & sameBit) != 0 ? d : -d;
            }
            else if ((f & sameBit) == 0)
            {
                if (p > g.Length - 2) return false;
                v += I16(g, p);
                p += 2;
            }
            into[i] = v;
        }
        return true;
    }

    private Contours? LoadComposite(ReadOnlySpan<byte> g, int depth, ref int budget, ref int points)
    {
        var result = new Contours();
        if (depth >= MaxCompositeDepth) return result;
        var p = 10;
        while (true)
        {
            if (p > g.Length - 4 || --budget < 0) return result;
            var flags = U16(g, p);
            var component = U16(g, p + 2);
            p += 4;

            int a1, a2;
            var xy = (flags & 2) != 0;
            if ((flags & 1) != 0)
            {
                a1 = xy ? I16(g, p) : U16(g, p);
                a2 = xy ? I16(g, p + 2) : U16(g, p + 2);
                p += 4;
            }
            else
            {
                a1 = xy ? (sbyte)U8(g, p) : U8(g, p);
                a2 = xy ? (sbyte)U8(g, p + 1) : U8(g, p + 1);
                p += 2;
            }

            double xx = 1, xy01 = 0, yx10 = 0, yy = 1;
            if ((flags & 0x8) != 0)
            {
                xx = yy = F2Dot14(g, p);
                p += 2;
            }
            else if ((flags & 0x40) != 0)
            {
                xx = F2Dot14(g, p);
                yy = F2Dot14(g, p + 2);
                p += 4;
            }
            else if ((flags & 0x80) != 0)
            {
                xx = F2Dot14(g, p);
                xy01 = F2Dot14(g, p + 2);
                yx10 = F2Dot14(g, p + 4);
                yy = F2Dot14(g, p + 6);
                p += 8;
            }

            if (Load(component, depth + 1, ref budget, ref points) is { } child)
            {
                for (var i = 0; i < child.Points.Count; i++)
                {
                    var pt = child.Points[i];
                    child.Points[i] = new Pt(xx * pt.X + yx10 * pt.Y, xy01 * pt.X + yy * pt.Y, pt.On);
                }

                double dx = a1, dy = a2;
                if (!xy)
                {
                    // Point matching: the child point a2 lands on the parent point a1.
                    if (a1 < result.Points.Count && a2 < child.Points.Count)
                    {
                        dx = result.Points[a1].X - child.Points[a2].X;
                        dy = result.Points[a1].Y - child.Points[a2].Y;
                    }
                    else dx = dy = 0;
                }

                var baseIndex = result.Points.Count;
                foreach (var pt in child.Points) result.Points.Add(new Pt(pt.X + dx, pt.Y + dy, pt.On));
                foreach (var e in child.Ends) result.Ends.Add(e + baseIndex);
            }

            if ((flags & 0x20) == 0) return result;
        }
    }

    private static double F2Dot14(ReadOnlySpan<byte> d, int o) => I16(d, o) / 16384.0;

    private static void Emit(GlyphOutline outline, Contours c)
    {
        var first = 0;
        foreach (var end in c.Ends)
        {
            var last = Math.Min(end, c.Points.Count - 1);
            if (last - first >= 1) EmitContour(outline, c.Points, first, last);
            first = end + 1;
        }
    }

    private static void EmitContour(GlyphOutline o, List<Pt> pts, int s, int e)
    {
        Pt start;
        int from, to;
        if (pts[s].On)
        {
            start = pts[s];
            from = s + 1;
            to = e;
        }
        else if (pts[e].On)
        {
            start = pts[e];
            from = s;
            to = e - 1;
        }
        else
        {
            start = new Pt((pts[s].X + pts[e].X) / 2, (pts[s].Y + pts[e].Y) / 2, true);
            from = s;
            to = e;
        }

        o.MoveTo(start.X, start.Y);
        Pt? ctrl = null;
        for (var i = from; i <= to; i++)
        {
            var p = pts[i];
            if (p.On)
            {
                if (ctrl is { } c) o.QuadTo(c.X, c.Y, p.X, p.Y);
                else o.LineTo(p.X, p.Y);
                ctrl = null;
            }
            else
            {
                if (ctrl is { } c) o.QuadTo(c.X, c.Y, (c.X + p.X) / 2, (c.Y + p.Y) / 2);
                ctrl = p;
            }
        }
        if (ctrl is { } last) o.QuadTo(last.X, last.Y, start.X, start.Y);
        o.Close();
    }
}
