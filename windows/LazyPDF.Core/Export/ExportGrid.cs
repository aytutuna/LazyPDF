namespace LazyPDF.Core;

/// <summary>A grid the page draws with lines, with the text lines that sit in it.</summary>
internal sealed record ExportRuled(ExportTable Table, List<ExLine> Lines);

/// <summary>Finds tables from the horizontal and vertical lines of a page and fills their cells with the text inside.</summary>
internal static class ExportGrid
{
    private const double Snap = 2;
    private const double Gap = 3;
    private const int MaxPairs = 4_000_000;
    private const int MaxCells = 20000;

    public static List<ExportRuled> Find(IReadOnlyList<ExportRule> rules, IReadOnlyList<ExLine> lines)
    {
        var found = new List<ExportRuled>();
        var hs = Merge(rules.Where(r => r.Horizontal));
        var vs = Merge(rules.Where(r => !r.Horizontal));
        if (hs.Count < 2 || vs.Count < 2 || (long)hs.Count * vs.Count > MaxPairs) return found;

        var parent = Enumerable.Range(0, hs.Count + vs.Count).ToArray();
        int Root(int i)
        {
            while (parent[i] != i) i = parent[i] = parent[parent[i]];
            return i;
        }
        for (int h = 0; h < hs.Count; h++)
        {
            for (int v = 0; v < vs.Count; v++)
            {
                if (vs[v].Pos >= hs[h].From - Snap && vs[v].Pos <= hs[h].To + Snap && hs[h].Pos >= vs[v].From - Snap && hs[h].Pos <= vs[v].To + Snap)
                    parent[Root(h)] = Root(hs.Count + v);
            }
        }

        var groups = Enumerable.Range(0, hs.Count + vs.Count).GroupBy(Root).Select(g => (
            H: g.Where(i => i < hs.Count).Select(i => hs[i]).ToList(),
            V: g.Where(i => i >= hs.Count).Select(i => vs[i - hs.Count]).ToList())).Where(g => g.H.Count >= 2 && g.V.Count >= 2).ToList();

        // The smaller grid first, so a table inside another keeps its own text.
        var candidates = groups.Select(g =>
        {
            var xs = Positions(g.V.Select(v => v.Pos));
            var ys = Positions(g.H.Select(h => h.Pos));
            return (xs, ys, area: (xs[^1] - xs[0]) * (ys[^1] - ys[0]));
        }).Where(c => c.xs.Count >= 3 && c.ys.Count >= 3 && (c.xs.Count - 1) * (c.ys.Count - 1) <= MaxCells).OrderBy(c => c.area);

        var taken = new HashSet<ExLine>();
        foreach (var (xs, ys, _) in candidates)
        {
            var inside = lines.Where(l => !taken.Contains(l) && l.Left >= xs[0] - Snap && l.Left <= xs[^1] && l.CenterY >= ys[0] && l.CenterY <= ys[^1]).ToList();
            if (Fill(xs, ys, inside) is not { } table) continue;
            foreach (var l in inside) taken.Add(l);
            found.Add(new ExportRuled(table, inside));
        }
        return found;
    }

    private static ExportTable? Fill(List<double> xs, List<double> ys, List<ExLine> inside)
    {
        int cols = xs.Count - 1, rows = ys.Count - 1;
        var cells = new List<ExLine>[rows, cols];
        foreach (var line in inside.OrderBy(l => l.CenterY).ThenBy(l => l.Left))
        {
            int r = Index(ys, line.CenterY), c = Math.Max(0, Index(xs, line.Left + 1.5));
            (cells[r, c] ??= []).Add(line);
        }

        var texts = new string[rows, cols];
        int filled = 0;
        for (int r = 0; r < rows; r++)
        {
            for (int c = 0; c < cols; c++)
            {
                texts[r, c] = cells[r, c] is { } list ? CellText(list) : "";
                if (texts[r, c].Length > 0) filled++;
            }
        }
        if (filled < 3) return null;

        var keepRows = Enumerable.Range(0, rows).Where(r => Enumerable.Range(0, cols).Any(c => texts[r, c].Length > 0)).ToList();
        var keepCols = Enumerable.Range(0, cols).Where(c => keepRows.Any(r => texts[r, c].Length > 0)).ToList();
        if (keepRows.Count < 2 || keepCols.Count < 2) return null;

        var body = keepRows.Select(r => (IReadOnlyList<string>)keepCols.Select(c => texts[r, c]).ToList()).ToList();
        var widths = keepCols.Count == cols ? Enumerable.Range(0, cols).Select(c => xs[c + 1] - xs[c]).ToList() : null;
        var bounds = new DisplayRect(xs[0], ys[0], xs[^1] - xs[0], ys[^1] - ys[0]);
        return new ExportTable(bounds, body, widths, true);
    }

    // Lines of a cell in reading order: those within half a line of each other are one row of the cell.
    private static string CellText(List<ExLine> lines)
    {
        var parts = new List<string>();
        var row = new List<ExLine>();
        void Flush()
        {
            parts.Add(string.Join(" ", row.OrderBy(l => l.Left).Select(l => l.Text)));
            row.Clear();
        }
        foreach (var line in lines)
        {
            if (row.Count > 0 && line.CenterY - row[0].CenterY > 0.5 * line.Size) Flush();
            row.Add(line);
        }
        if (row.Count > 0) Flush();
        return string.Join(" ", parts).Trim();
    }

    private static int Index(List<double> edges, double value)
    {
        int i = edges.FindLastIndex(e => e <= value);
        return Math.Clamp(i, 0, edges.Count - 2);
    }

    private static List<double> Positions(IEnumerable<double> values)
    {
        var sorted = values.OrderBy(v => v).ToList();
        var result = new List<double>();
        double last = double.NegativeInfinity;
        foreach (double v in sorted)
        {
            if (v - last > Snap) result.Add(v);
            last = v;
        }
        return result;
    }

    // Lines on the same line of the page that touch or nearly touch become one.
    private static List<ExportRule> Merge(IEnumerable<ExportRule> rules)
    {
        var sorted = rules.OrderBy(r => r.Pos).ToList();
        var merged = new List<ExportRule>();
        for (int i = 0; i < sorted.Count;)
        {
            int j = i + 1;
            while (j < sorted.Count && sorted[j].Pos - sorted[j - 1].Pos <= 1.5) j++;
            var cluster = sorted.GetRange(i, j - i);
            double from = 0, to = 0, pos = cluster.Average(r => r.Pos);
            bool open = false;
            foreach (var r in cluster.OrderBy(r => r.From))
            {
                if (open && r.From <= to + Gap)
                {
                    to = Math.Max(to, r.To);
                    continue;
                }
                if (open) merged.Add(new ExportRule(r.Horizontal, pos, from, to));
                (from, to, open) = (r.From, r.To, true);
            }
            merged.Add(new ExportRule(sorted[i].Horizontal, pos, from, to));
            i = j;
        }
        return merged;
    }
}
