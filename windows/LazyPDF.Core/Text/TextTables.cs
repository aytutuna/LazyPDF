namespace LazyPDF.Core;

/// <summary>Groups segments into tables and paragraph chains.</summary>
internal static class TextTables
{
    private const int MaxRowChars = 24;
    private const int MaxRowWords = 3;
    private const int MaxLookBack = 200;

    public static List<FlowBlock> Blocks(List<List<FlowSeg>> lines, double em)
    {
        var blocks = new List<FlowBlock>();
        var loose = new List<FlowSeg>();
        var run = new List<List<FlowSeg>>();

        void Flush()
        {
            bool table = run.Count >= 3 || (run.Count == 2 && run.All(l => l.Count >= 3));
            if (table)
            {
                var block = new FlowBlock { Table = true };
                foreach (var line in run)
                {
                    foreach (var s in line) block.Add(s);
                }
                blocks.Add(block);
            }
            else
            {
                foreach (var line in run) loose.AddRange(line);
            }
            run.Clear();
        }

        for (int i = 0; i < lines.Count; i++)
        {
            var line = lines[i];
            bool row = IsRow(line);
            if (row && run.Count > 0 && lines[i].Min(s => s.Ya) - run[^1].Max(s => s.Yb) > 1.5 * em) Flush();
            if (row)
            {
                run.Add(line);
                continue;
            }
            // A row with one filled cell stays in the table when more rows follow in line with it.
            if (run.Count > 0 && line.Count == 1 && i + 1 < lines.Count && IsRow(lines[i + 1]) && AlignsWith(line[0], run[^1]))
            {
                run.Add(line);
                continue;
            }
            Flush();
            loose.AddRange(line);
        }
        Flush();
        blocks.AddRange(Chains(loose));
        return blocks;
    }

    private static bool IsRow(List<FlowSeg> line) =>
        line.Count >= 2 && FlowSeg.Median(line.Select(s => (double)s.Text)) <= MaxRowChars && FlowSeg.Median(line.Select(s => (double)s.Words)) <= MaxRowWords;

    private static bool AlignsWith(FlowSeg cell, List<FlowSeg> row) => row.Any(s => Math.Abs(s.X0 - cell.X0) < 0.6 * cell.Em);

    // Each segment hangs under the one above it that it overlaps most, at most one child per parent
    // so that text under a heading that spans two columns does not join both columns.
    private static List<FlowBlock> Chains(List<FlowSeg> segs)
    {
        segs.Sort((a, b) => a.Y != b.Y ? a.Y.CompareTo(b.Y) : a.X0.CompareTo(b.X0));
        var candidates = new List<(int Parent, double Overlap, double Dy)>[segs.Count];
        var nearest = new List<double>();
        for (int i = 0; i < segs.Count; i++)
        {
            var s = segs[i];
            candidates[i] = [];
            double closest = double.MaxValue;
            for (int j = i - 1; j >= Math.Max(0, i - MaxLookBack); j--)
            {
                var p = segs[j];
                double dy = s.Y - p.Y;
                if (dy > 2.6 * Math.Max(s.Em, p.Em)) break;
                double ratio = s.Em / p.Em, overlap = Math.Min(s.X1, p.X1) - Math.Max(s.X0, p.X0);
                if (dy < 0.5 * Math.Max(s.Em, p.Em) || ratio < 0.7 || ratio > 1.43) continue;
                if (overlap <= 0 || overlap < 0.3 * Math.Min(s.Width, p.Width)) continue;
                candidates[i].Add((j, overlap, dy));
                closest = Math.Min(closest, dy);
            }
            if (closest < double.MaxValue) nearest.Add(closest);
        }
        // A gap well past the usual line pitch is a paragraph break.
        nearest.Sort();
        double pitch = nearest.Count > 0 ? nearest[nearest.Count / 2] : 0;
        var parent = new FlowSeg?[segs.Count];
        var hasChild = new bool[segs.Count];
        for (int i = 0; i < segs.Count; i++)
        {
            int best = -1;
            double bestOverlap = 0;
            foreach (var (j, overlap, dy) in candidates[i])
            {
                if (hasChild[j] || dy > Math.Max(1.45 * pitch, 1.3 * segs[i].Em)) continue;
                if (overlap > bestOverlap)
                {
                    bestOverlap = overlap;
                    best = j;
                }
            }
            if (best < 0) continue;
            hasChild[best] = true;
            parent[i] = segs[best];
        }

        var owner = new Dictionary<FlowSeg, FlowBlock>(segs.Count);
        var result = new List<FlowBlock>();
        for (int i = 0; i < segs.Count; i++)
        {
            var block = parent[i] is { } p ? owner[p] : null;
            if (block is null) result.Add(block = new FlowBlock());
            block.Add(segs[i]);
            owner[segs[i]] = block;
        }
        return result;
    }
}
