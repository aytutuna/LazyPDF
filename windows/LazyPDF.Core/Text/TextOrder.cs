namespace LazyPDF.Core;

/// <summary>
/// Reading order of blocks by recursive cuts: across the widest empty bands first, then between
/// columns. Bands that are columnar on both sides of a cut and share a gutter are kept together,
/// otherwise two columns whose paragraph gaps happen to line up would be read across.
/// </summary>
internal sealed class TextOrder
{
    private const int MaxDepth = 48;
    private const int MaxBlocks = 20_000;

    private readonly double _em;
    private readonly bool _rtl;
    private readonly List<FlowBlock> _result = [];

    private TextOrder(double em, bool rtl)
    {
        _em = em;
        _rtl = rtl;
    }

    public static List<FlowBlock> Sort(List<FlowBlock> blocks, double em, bool rtl)
    {
        if (rtl)
        {
            foreach (var b in blocks.Where(b => b.Table)) b.Segs = [.. b.Segs.OrderBy(s => s.Row).ThenByDescending(s => s.X0)];
        }
        var order = new TextOrder(em, rtl);
        if (blocks.Count > MaxBlocks) order.Leaf(blocks);
        else order.Cut(blocks, true, 0);
        return order._result;
    }

    private void Cut(List<FlowBlock> items, bool horizontal, int depth)
    {
        if (items.Count <= 1)
        {
            _result.AddRange(items);
            return;
        }
        if (depth > MaxDepth)
        {
            Leaf(items);
            return;
        }
        if (horizontal)
        {
            var bands = Merge(Bands(items));
            if (bands.Count > 1 || bands[0].Merged)
            {
                foreach (var band in bands) Cut(band.Items, !band.Merged, depth + 1);
                return;
            }
        }
        var columns = Columns(items);
        if (columns.Count < 2)
        {
            Leaf(items);
            return;
        }
        if (_rtl) columns.Reverse();
        foreach (var column in columns) Cut(column, true, depth + 1);
    }

    private sealed record Band(List<FlowBlock> Items, bool Merged);

    private List<Band> Bands(List<FlowBlock> items)
    {
        var sorted = items.OrderBy(b => b.Ya).ThenBy(b => b.X0).ToList();
        var bands = new List<Band>();
        var current = new List<FlowBlock>();
        double bottom = double.MinValue;
        foreach (var b in sorted)
        {
            if (current.Count > 0 && b.Ya > bottom + 0.05 * _em)
            {
                bands.Add(new Band(current, false));
                current = [];
            }
            current.Add(b);
            bottom = current.Count == 1 ? b.Yb : Math.Max(bottom, b.Yb);
        }
        bands.Add(new Band(current, false));
        return bands;
    }

    private List<Band> Merge(List<Band> bands)
    {
        if (bands.Count < 2) return bands;
        var merged = new List<Band>();
        List<(double, double)>? previous = null;
        foreach (var band in bands)
        {
            var gutters = Gutters(Columns(band.Items));
            if (merged.Count > 0 && previous is { Count: > 0 } && gutters.Count > 0 && Shares(previous, gutters))
            {
                merged[^1] = new Band([.. merged[^1].Items, .. band.Items], true);
            }
            else
            {
                merged.Add(band);
            }
            previous = gutters;
        }
        return merged;
    }

    private bool Shares(List<(double Left, double Right)> a, List<(double Left, double Right)> b) =>
        a.Any(x => b.Any(y => Math.Min(x.Right, y.Right) - Math.Max(x.Left, y.Left) > 0.3 * _em));

    private static List<(double, double)> Gutters(List<List<FlowBlock>> columns)
    {
        var result = new List<(double, double)>();
        for (int i = 1; i < columns.Count; i++)
        {
            result.Add((columns[i - 1].Max(b => b.X1), columns[i].Min(b => b.X0)));
        }
        return result;
    }

    // Gutters are stretches of x that almost nothing covers, so that a page number sitting in one
    // does not make two columns one. A block belongs to the column its centre is in.
    private List<List<FlowBlock>> Columns(List<FlowBlock> items)
    {
        double limit = 0.04 * items.Sum(b => b.Yb - b.Ya);
        var edges = new List<(double X, double Weight)>(items.Count * 2);
        foreach (var b in items)
        {
            edges.Add((b.X0, b.Yb - b.Ya));
            edges.Add((b.X1, b.Ya - b.Yb));
        }
        edges.Sort((p, q) => p.X.CompareTo(q.X));
        var xs = new List<double>();
        var cover = new List<double>();
        double sum = 0;
        for (int i = 0; i < edges.Count;)
        {
            double x = edges[i].X;
            do sum += edges[i++].Weight;
            while (i < edges.Count && edges[i].X == x);
            xs.Add(x);
            cover.Add(sum);
        }
        var gutters = new List<double>();
        for (int i = 0; i < xs.Count - 1;)
        {
            if (cover[i] > limit)
            {
                i++;
                continue;
            }
            int j = i + 1;
            while (j < xs.Count - 1 && cover[j] <= limit) j++;
            if (i > 0 && j < xs.Count - 1 && xs[j] - xs[i] > 0.9 * _em) gutters.Add((xs[i] + xs[j]) / 2);
            i = j;
        }
        var byColumn = new SortedDictionary<int, List<FlowBlock>>();
        foreach (var b in items)
        {
            double centre = (b.X0 + b.X1) / 2;
            int k = gutters.Count(g => g < centre);
            if (!byColumn.TryGetValue(k, out var list)) byColumn[k] = list = [];
            list.Add(b);
        }
        return [.. byColumn.Values];
    }

    // Nothing separates these: rows from the top, each row left to right.
    private void Leaf(List<FlowBlock> items)
    {
        var sorted = items.OrderBy(b => b.Ya).ThenBy(b => b.X0).ToList();
        var row = new List<FlowBlock>();
        FlowBlock? head = null;
        void Flush()
        {
            _result.AddRange(_rtl ? row.OrderByDescending(b => b.X1) : row.OrderBy(b => b.X0));
            row.Clear();
        }
        foreach (var b in sorted)
        {
            if (head is not null && b.Ya >= head.Ya + 0.5 * (head.Yb - head.Ya)) Flush();
            if (row.Count == 0) head = b;
            row.Add(b);
        }
        Flush();
    }
}
