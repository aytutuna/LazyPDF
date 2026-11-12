namespace LazyPDF.Core.Office;

/// <summary>One line of a cell with the space around it: <see cref="Lead"/> is the paragraph's space before (first line only), <see cref="Height"/> includes it and the space after.</summary>
internal sealed record Slot(LayoutLine Line, double Lead, double Height);

internal sealed class CellLines
{
    public required LayoutCell Source { get; init; }
    /// <summary>From the left edge of the text area.</summary>
    public double X { get; init; }
    public double Width { get; init; }
    public List<Slot> Slots { get; set; } = [];
    /// <summary>Rows the cell covers, after a merge too tall for a page has been undone.</summary>
    public int RowSpan { get; set; }

    public double Content => Slots.Sum(s => s.Height);
}

internal sealed class RowLines
{
    public required LayoutRow Source { get; init; }
    public List<CellLines> Cells { get; } = [];
    public double Height;
    /// <summary>What the content alone needs, without the row's minimum height.</summary>
    public double Need;
    public bool HasLines => Cells.Any(c => c.Slots.Count > 0);
}

internal sealed class TableLines
{
    public required LayoutTable Source { get; init; }
    public List<RowLines> Rows { get; } = [];
    /// <summary>The row that starts the group after the one at the index: rows joined by a vertical merge stay together.</summary>
    public int[] Next { get; set; } = [];
    /// <summary>Rows repeated at the top of each page the table continues on.</summary>
    public int Header { get; set; }

    public double Height(int from, int to)
    {
        double sum = 0;
        for (int r = from; r < to; r++) sum += Rows[r].Height;
        return sum;
    }
}

/// <summary>Measures a table: column positions, the lines of every cell, row heights and which rows must stay together.</summary>
internal static class TableLayout
{
    private const double Tolerance = 0.01;

    public static TableLines Measure(LayoutTable table, LayoutFonts fonts, double areaWidth, double bodyHeight, Action<ParagraphLines> count)
    {
        var x = Columns(table, areaWidth);
        var result = new TableLines { Source = table };
        foreach (var row in table.Rows)
        {
            var lines = new RowLines { Source = row };
            foreach (var cell in row.Cells)
            {
                int from = Math.Min(cell.Column, x.Length - 1), to = Math.Min(cell.Column + cell.Span, x.Length - 1);
                double width = x[to] - x[from];
                var made = new CellLines { Source = cell, X = x[from], Width = width, RowSpan = cell.RowSpan };
                double inner = Math.Max(1, width - cell.MarginLeft - cell.MarginRight);
                foreach (var paragraph in cell.Paragraphs)
                {
                    var paragraphLines = ParagraphLayout.Run(paragraph, fonts, inner, bodyHeight);
                    count(paragraphLines);
                    for (int k = 0; k < paragraphLines.Lines.Count; k++)
                    {
                        double lead = k == 0 ? paragraph.Before : 0, tail = k == paragraphLines.Lines.Count - 1 ? paragraph.After : 0;
                        made.Slots.Add(new Slot(paragraphLines.Lines[k], lead, lead + paragraphLines.Lines[k].Height + tail));
                    }
                }
                lines.Cells.Add(made);
            }
            result.Rows.Add(lines);
        }

        Heights(result);
        Groups(result);
        // A merge taller than a page cannot be kept in one piece; its cell goes back to one row and breaks across pages like any other.
        bool undone = false;
        for (int r = 0; r < result.Rows.Count; r = result.Next[r])
        {
            int next = result.Next[r];
            if (next - r > 1 && result.Height(r, next) > bodyHeight)
            {
                for (int k = r; k < next; k++)
                {
                    foreach (var cell in result.Rows[k].Cells) cell.RowSpan = 1;
                }
                undone = true;
            }
        }
        if (undone)
        {
            Heights(result);
            Groups(result);
        }

        int header = 0;
        while (header < result.Rows.Count && result.Rows[header].Source.Header) header++;
        while (header > 0 && !IsStart(result, header)) header--;
        if (header < result.Rows.Count && result.Height(0, header) * 2 <= bodyHeight) result.Header = header;
        return result;
    }

    private static bool IsStart(TableLines table, int row)
    {
        for (int r = 0; r < table.Rows.Count; r = table.Next[r])
        {
            if (r == row) return true;
            if (r > row) return false;
        }
        return row == table.Rows.Count;
    }

    // Column edges from the left of the text area. Columns without a width share what the others leave; a table wider
    // than its room is narrowed to fit instead of running into the margin.
    private static double[] Columns(LayoutTable table, double areaWidth)
    {
        var widths = table.Columns.Select(w => Math.Max(0, w)).ToArray();
        double indent = table.Align == LayoutAlign.Left ? Math.Clamp(table.Indent, 0, Math.Max(0, areaWidth - 36)) : 0;
        double room = Math.Max(36, areaWidth - indent);
        int free = widths.Count(w => w == 0);
        if (free > 0)
        {
            double each = Math.Max(room - widths.Sum(), free * 12) / free;
            for (int c = 0; c < widths.Length; c++)
            {
                if (widths[c] == 0) widths[c] = each;
            }
        }
        double total = widths.Sum();
        if (total > room)
        {
            for (int c = 0; c < widths.Length; c++) widths[c] *= room / total;
            total = room;
        }
        double start = table.Align switch
        {
            LayoutAlign.Center => (areaWidth - total) / 2,
            LayoutAlign.Right => areaWidth - total,
            _ => table.Indent,
        };
        var edges = new double[widths.Length + 1];
        edges[0] = start;
        for (int c = 0; c < widths.Length; c++) edges[c + 1] = edges[c] + widths[c];
        return edges;
    }

    private static void Heights(TableLines table)
    {
        var rows = table.Rows;
        for (int r = 0; r < rows.Count; r++)
        {
            var row = rows[r];
            bool exact = row.Source.HeightExact && row.Source.Height > 0;
            row.Need = 0;
            foreach (var cell in row.Cells)
            {
                if (cell.RowSpan > 1) continue;
                double need = cell.Source.MarginTop + cell.Content + cell.Source.MarginBottom;
                row.Need = Math.Max(row.Need, need);
            }
            row.Height = exact ? row.Source.Height : Math.Max(row.Source.Height, row.Need);
            if (!exact) continue;
            // What does not fit in a fixed height is cut off.
            foreach (var cell in row.Cells)
            {
                double allowed = row.Height - cell.Source.MarginTop - cell.Source.MarginBottom, used = 0;
                int keep = 0;
                while (keep < cell.Slots.Count && used + cell.Slots[keep].Height <= allowed + Tolerance) used += cell.Slots[keep++].Height;
                if (keep < cell.Slots.Count) cell.Slots = cell.Slots.GetRange(0, keep);
            }
        }

        // A merged cell that needs more than its rows give makes the last of them taller.
        var spanning = new List<(int Row, int End, CellLines Cell)>();
        for (int r = 0; r < rows.Count; r++)
        {
            foreach (var cell in rows[r].Cells)
            {
                if (cell.RowSpan > 1) spanning.Add((r, Math.Min(rows.Count, r + cell.RowSpan), cell));
            }
        }
        foreach (var (row, end, cell) in spanning.OrderBy(s => s.End).ThenBy(s => s.Row))
        {
            double need = cell.Source.MarginTop + cell.Content + cell.Source.MarginBottom, have = 0;
            for (int r = row; r < end; r++) have += rows[r].Height;
            if (need > have) rows[end - 1].Height += need - have;
        }
    }

    private static void Groups(TableLines table)
    {
        var rows = table.Rows;
        var starts = new List<int>();
        int reach = 0;
        for (int r = 0; r < rows.Count; r++)
        {
            if (r >= reach) starts.Add(r);
            reach = Math.Max(reach, r + 1);
            foreach (var cell in rows[r].Cells) reach = Math.Max(reach, Math.Min(rows.Count, r + cell.RowSpan));
        }
        table.Next = new int[rows.Count];
        for (int g = 0; g < starts.Count; g++)
        {
            int end = g + 1 < starts.Count ? starts[g + 1] : rows.Count;
            for (int r = starts[g]; r < end; r++) table.Next[r] = end;
        }
    }
}
