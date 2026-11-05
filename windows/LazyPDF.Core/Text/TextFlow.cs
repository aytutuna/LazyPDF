namespace LazyPDF.Core;

/// <summary>A line of the result: glyphs in logical order and how it joins the line before it.</summary>
internal sealed class FlowLine
{
    public List<FlowGlyph> Glyphs = [];
    public TextBreak Before;
    public int Block;
    public bool Table, Vertical, Rtl;
}

/// <summary>Glyphs on one baseline with no wide gap, in the frame of their orientation group.</summary>
internal sealed class FlowSeg
{
    public List<FlowGlyph> Glyphs = [];
    public double X0 = double.MaxValue, X1 = double.MinValue, Ya = double.MaxValue, Yb = double.MinValue, Y, Em;
    public int Row;
    public int Text, Words;

    public double Width => X1 - X0;

    public void Finish()
    {
        var ink = Glyphs.Where(g => !g.Space).ToList();
        int first = Glyphs.FindIndex(g => !g.Space), last = Glyphs.FindLastIndex(g => !g.Space);
        Glyphs = first < 0 ? [] : Glyphs.GetRange(first, last - first + 1);
        Text = ink.Count;
        Words = 1;
        for (int i = 1; i < Glyphs.Count; i++)
        {
            var (a, b) = (Glyphs[i - 1], Glyphs[i]);
            if (!b.Space && (a.Space || b.X0 - a.X1 > 0.1 * (a.Em + b.Em) / 2)) Words++;
        }
        foreach (var g in ink)
        {
            X0 = Math.Min(X0, g.X0);
            X1 = Math.Max(X1, g.X1);
            Ya = Math.Min(Ya, g.Ya);
            Yb = Math.Max(Yb, g.Yb);
        }
        if (ink.Count == 0) return;
        Y = Median(ink.Select(g => g.Y));
        Em = Median(ink.Select(g => g.Em));
    }

    public static double Median(IEnumerable<double> values)
    {
        var a = values.ToArray();
        Array.Sort(a);
        return a.Length == 0 ? 0 : a[a.Length / 2];
    }
}

/// <summary>A paragraph-like chain of segments, or a table.</summary>
internal sealed class FlowBlock
{
    public List<FlowSeg> Segs = [];
    public double X0 = double.MaxValue, X1 = double.MinValue, Ya = double.MaxValue, Yb = double.MinValue;
    public bool Table;

    public void Add(FlowSeg s)
    {
        Segs.Add(s);
        X0 = Math.Min(X0, s.X0);
        X1 = Math.Max(X1, s.X1);
        Ya = Math.Min(Ya, s.Ya);
        Yb = Math.Max(Yb, s.Yb);
    }
}

/// <summary>
/// Turns glyphs into ordered lines: orientation groups, baselines, segments split at wide gaps,
/// tables, paragraph chains, then a recursive cut of the blocks into reading order.
/// </summary>
internal sealed class TextFlow(PageGeometry geometry)
{
    private const double ColumnGap = 1.2;
    private const double SpaceGap = 0.1;

    private int _block;
    private double _dx, _dy, _nx, _ny;

    public List<FlowLine> Run(List<FlowGlyph> glyphs)
    {
        var result = new List<FlowLine>();
        if (glyphs.Count == 0) return result;
        var (a, b, c, d, _, _) = geometry.Matrix;
        double scale = Math.Sqrt(Math.Abs(a * d - b * c));
        for (int i = 0; i < glyphs.Count; i++) Prepare(glyphs[i], i, scale);
        glyphs = glyphs.FindAll(g => double.IsFinite(g.Em) && double.IsFinite(g.Display.X0 + g.Display.Y0 + g.Display.X1 + g.Display.Y1
            + g.Display.X2 + g.Display.Y2 + g.Display.X3 + g.Display.Y3));
        if (glyphs.Count == 0) return result;

        var groups = new Dictionary<(bool, int), List<FlowGlyph>>();
        foreach (var g in glyphs)
        {
            int bin = (int)Math.Round(g.Angle / (Math.PI / 12));
            var key = (g.Vertical, ((bin % 24) + 24) % 24);
            if (!groups.TryGetValue(key, out var list)) groups[key] = list = [];
            list.Add(g);
        }
        foreach (var group in groups.Values.OrderByDescending(l => l.Count)) Layout(group, result);
        return result;
    }

    private void Prepare(FlowGlyph g, int run, double scale)
    {
        var q = g.Quad;
        var (x0, y0) = geometry.ToDisplay(q.X0, q.Y0);
        var (x1, y1) = geometry.ToDisplay(q.X1, q.Y1);
        var (x2, y2) = geometry.ToDisplay(q.X2, q.Y2);
        var (x3, y3) = geometry.ToDisplay(q.X3, q.Y3);
        g.Display = new TextQuad(x0, y0, x1, y1, x2, y2, x3, y3);
        g.Em = g.Size * scale;
        g.Run = run;
        // The reading direction follows the baseline, so that a sheared matrix (fake italic) stays
        // upright. Vertical fonts and zero-width glyphs use the up vector turned a quarter clockwise.
        double bx = x1 - x0, by = y1 - y0;
        double ux = x3 - x0, uy = y3 - y0, length = Math.Sqrt(ux * ux + uy * uy);
        if (length < 1e-12) (ux, uy) = (0, -1);
        if (!g.Vertical && bx * bx + by * by > 1e-12) g.Angle = Math.Atan2(by, bx);
        else g.Angle = g.Vertical ? Math.Atan2(-uy, -ux) : Math.Atan2(ux, -uy);
    }

    private void Place(FlowGlyph g)
    {
        var d = g.Display;
        Span<double> u = [_dx * d.X0 + _dy * d.Y0, _dx * d.X1 + _dy * d.Y1, _dx * d.X2 + _dy * d.Y2, _dx * d.X3 + _dy * d.Y3];
        Span<double> v = [_nx * d.X0 + _ny * d.Y0, _nx * d.X1 + _ny * d.Y1, _nx * d.X2 + _ny * d.Y2, _nx * d.X3 + _ny * d.Y3];
        g.X0 = Math.Min(Math.Min(u[0], u[1]), Math.Min(u[2], u[3]));
        g.X1 = Math.Max(Math.Max(u[0], u[1]), Math.Max(u[2], u[3]));
        g.Ya = Math.Min(Math.Min(v[0], v[1]), Math.Min(v[2], v[3]));
        g.Yb = Math.Max(Math.Max(v[0], v[1]), Math.Max(v[2], v[3]));
        if (g.Vertical)
        {
            g.Y = (g.Ya + g.Yb) / 2;
            return;
        }
        double bx = d.X0 + g.Base * (d.X3 - d.X0), by = d.Y0 + g.Base * (d.Y3 - d.Y0);
        g.Y = _nx * bx + _ny * by;
    }

    private void Layout(List<FlowGlyph> group, List<FlowLine> result)
    {
        bool vertical = group[0].Vertical;
        double centre = (int)Math.Round(group[0].Angle / (Math.PI / 12)) * (Math.PI / 12);
        double phi = centre + FlowSeg.Median(group.Select(g => Math.IEEERemainder(g.Angle - centre, 2 * Math.PI)));
        (_dx, _dy) = (Math.Cos(phi), Math.Sin(phi));
        (_nx, _ny) = (-_dy, _dx);
        foreach (var g in group) Place(g);

        int rtlCount = 0, ltrCount = 0;
        foreach (var g in group)
        {
            var cls = TextBidi.ClassOf(g.Text);
            if (cls is BidiClass.R) rtlCount++;
            else if (cls is BidiClass.L) ltrCount++;
        }
        bool pageRtl = rtlCount > ltrCount;

        var lines = Lines(group);
        var segs = new List<FlowSeg>();
        for (int i = 0; i < lines.Count; i++)
        {
            foreach (var s in lines[i])
            {
                s.Row = i;
                segs.Add(s);
            }
        }
        if (segs.Count == 0) return;
        double em = FlowSeg.Median(segs.Select(s => s.Em));
        var blocks = TextTables.Blocks(lines, em);
        var order = TextOrder.Sort(blocks, em, pageRtl);

        FlowSeg? previous = null;
        var first = result.Count == 0;
        foreach (var block in order)
        {
            int number = _block++;
            FlowSeg? last = null;
            foreach (var seg in block.Segs)
            {
                var line = new FlowLine { Block = number, Table = block.Table, Vertical = vertical };
                line.Before = previous is null ? first ? TextBreak.None : TextBreak.Block
                    : last is null ? SameRow(previous, seg) ? TextBreak.Tab : TextBreak.Block
                    : block.Table && last.Row == seg.Row ? TextBreak.Tab : TextBreak.Line;
                line.Glyphs = Logical(seg, pageRtl, out bool rtl);
                line.Rtl = rtl;
                result.Add(line);
                (previous, last) = (seg, seg);
            }
        }
    }

    private static bool SameRow(FlowSeg a, FlowSeg b) => Math.Abs(a.Y - b.Y) < 0.3 * Math.Max(a.Em, b.Em);

    // Lines: glyphs on one baseline, found by sorting on it and cutting where it jumps, then script
    // glyphs (smaller, shifted off the baseline) are taken into the line they sit beside. Split at
    // gaps too wide for a word space.
    private List<List<FlowSeg>> Lines(List<FlowGlyph> group)
    {
        var sorted = group.OrderBy(g => g.Y).ThenBy(g => g.Run).ToList();
        var lines = new List<List<FlowGlyph>>();
        double first = 0;
        for (int i = 0; i < sorted.Count; i++)
        {
            var g = sorted[i];
            if (i > 0 && g.Y - sorted[i - 1].Y <= 0.35 * Math.Min(g.Em, sorted[i - 1].Em) && g.Y - first <= 0.7 * g.Em)
            {
                lines[^1].Add(g);
                continue;
            }
            lines.Add([g]);
            first = g.Y;
        }
        lines = AttachScripts(lines);

        var result = new List<List<FlowSeg>>();
        foreach (var line in lines)
        {
            line.Sort((p, q) => p.X0 != q.X0 ? p.X0.CompareTo(q.X0) : p.Run.CompareTo(q.Run));
            var segs = new List<FlowSeg>();
            var cur = new FlowSeg();
            double right = double.MinValue, lastEm = 0;
            foreach (var g in line)
            {
                if (cur.Glyphs.Count > 0 && g.X0 - right > ColumnGap * Math.Max(g.Em, lastEm))
                {
                    segs.Add(cur);
                    cur = new FlowSeg();
                }
                cur.Glyphs.Add(g);
                if (!g.Space)
                {
                    right = cur.Glyphs.Count == 1 || right == double.MinValue ? g.X1 : Math.Max(right, g.X1);
                    lastEm = g.Em;
                }
            }
            segs.Add(cur);
            foreach (var s in segs) s.Finish();
            segs.RemoveAll(s => s.Glyphs.Count == 0);
            if (segs.Count > 0) result.Add(segs);
        }
        return result;
    }

    private static List<List<FlowGlyph>> AttachScripts(List<List<FlowGlyph>> lines)
    {
        var stats = lines.Select(l => (Y: FlowSeg.Median(l.Select(g => g.Y)), Em: FlowSeg.Median(l.Select(g => g.Em)),
            X0: l.Min(g => g.X0), X1: l.Max(g => g.X1))).ToArray();
        var target = Enumerable.Range(0, lines.Count).ToArray();
        for (int i = 0; i < lines.Count; i++)
        {
            int best = -1;
            double bestDistance = double.MaxValue;
            for (int j = Math.Max(0, i - 3); j <= Math.Min(lines.Count - 1, i + 3); j++)
            {
                if (j == i || stats[j].Em * 0.85 < stats[i].Em || stats[i].Em < 0.55 * stats[j].Em) continue;
                double d = Math.Abs(stats[j].Y - stats[i].Y);
                bool beside = stats[i].X1 >= stats[j].X0 - stats[j].Em && stats[i].X0 <= stats[j].X1 + stats[j].Em;
                if (d < 0.7 * stats[j].Em && beside && d < bestDistance)
                {
                    best = j;
                    bestDistance = d;
                }
            }
            if (best >= 0) target[i] = best;
        }
        var result = new List<List<FlowGlyph>>();
        var index = new Dictionary<int, int>();
        for (int i = 0; i < lines.Count; i++)
        {
            int t = target[i];
            while (target[t] != t) t = target[t];
            if (!index.TryGetValue(t, out int at))
            {
                index[t] = at = result.Count;
                result.Add([]);
            }
            result[at].AddRange(lines[i]);
        }
        return result;
    }

    // A line's glyphs in logical order with a space glyph wherever a gap is wide enough to be one.
    private List<FlowGlyph> Logical(FlowSeg seg, bool pageRtl, out bool rtl)
    {
        var visual = new List<FlowGlyph>(seg.Glyphs.Count + 8);
        FlowGlyph? prev = null;
        foreach (var g in seg.Glyphs)
        {
            if (prev is { Space: false } && !g.Space && g.X0 - prev.X1 > SpaceGap * (prev.Em + g.Em) / 2) visual.Add(Gap(prev, g));
            visual.Add(g);
            prev = g;
        }
        rtl = TextBidi.ToLogical(visual, pageRtl);
        return visual;
    }

    private FlowGlyph Gap(FlowGlyph a, FlowGlyph b)
    {
        double ya = (a.Ya + b.Ya) / 2, yb = (a.Yb + b.Yb) / 2, u0 = a.X1, u1 = b.X0;
        (double X, double Y) P(double u, double v)
        {
            double x = u * _dx + v * _nx, y = u * _dy + v * _ny;
            return geometry.ToUser(x, y);
        }
        var (p0, p1, p2, p3) = a.Vertical ? (P(u1, yb), P(u1, ya), P(u0, ya), P(u0, yb)) : (P(u0, yb), P(u1, yb), P(u1, ya), P(u0, ya));
        return new FlowGlyph
        {
            Text = " ",
            Quad = new TextQuad(p0.X, p0.Y, p1.X, p1.Y, p2.X, p2.Y, p3.X, p3.Y),
            Size = a.Size,
            Color = a.Color,
            Mode = a.Mode,
            Artifact = a.Artifact,
            Vertical = a.Vertical,
            Space = true,
            Implied = true,
            X0 = u0,
            X1 = u1,
            Y = a.Y,
            Ya = ya,
            Yb = yb,
            Em = a.Em,
        };
    }
}
