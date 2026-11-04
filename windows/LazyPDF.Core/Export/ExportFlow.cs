using System.Text.RegularExpressions;

namespace LazyPDF.Core;

/// <summary>The line cells that sit on one row of the page.</summary>
internal sealed class ExRow
{
    public List<ExLine> Cells { get; } = [];

    public TextBreak Before => Cells[0].Before;
    public double Left => Cells.Min(c => c.Left);
    public double Right => Cells.Max(c => c.Right);
    public double Top => Cells.Min(c => c.Top);
    public double Bottom => Cells.Max(c => c.Bottom);
    public double Size => Cells.OrderByDescending(c => c.Text.Length).First().Size;
    public bool AllBold => Cells.All(c => c.AllBold);
    public string Text => string.Join("\t", Cells.Select(c => c.Text));
    public DisplayRect Box => new(Left, Top, Right - Left, Bottom - Top);

    public List<ExportRun> Runs()
    {
        var runs = new List<ExportRun>();
        foreach (var cell in Cells)
        {
            if (runs.Count > 0) runs.Add(new ExportRun("\t", false, false, cell.Size));
            runs.AddRange(cell.Runs);
        }
        return runs;
    }
}

/// <summary>A paragraph, heading candidate or list item while the lines are still being joined.</summary>
internal sealed class ExPara
{
    public required List<ExportRun> Runs { get; init; }
    public required ExRow Last { get; set; }
    public required double Size { get; init; }
    public required bool AllBold { get; init; }
    public required double Left { get; init; }
    public double Right { get; set; }
    public double Top { get; init; }
    public double Bottom { get; set; }
    public int Lines { get; set; } = 1;
    public int Heading { get; set; }

    /// <summary>For an item of a list: whether it is numbered, its number, and where its marker stood.</summary>
    public (bool Ordered, int Number, double MarkerLeft)? Item { get; init; }

    public string Text => string.Concat(Runs.Select(r => r.Text));
    public DisplayRect Box => new(Left, Top, Math.Max(0, Right - Left), Math.Max(0, Bottom - Top));
}

internal static class ExportFlow
{
    private const string Bullets = "•◦▪▫●○■□‣⁃∙·▸►▶➢➤✓✔◆◇–—-*";

    private static readonly Regex NumberOnly = new(@"^[0-9]{1,3}[.)]$");
    private static readonly Regex NumberThenText = new(@"^[0-9]{1,3}[.)]\s+(?=\S)");

    public static bool IsMarker(string text) => text.Length == 1 && Bullets.Contains(text[0]) || NumberOnly.IsMatch(text);

    /// <summary>
    /// A bullet or number drawn apart from its text, which the text layer may have put in a column
    /// of its own, goes back in front of the text on its row. The marker's place in the order is dropped.
    /// </summary>
    public static void JoinMarkers(List<ExLine?> lines)
    {
        for (int i = 0; i < lines.Count; i++)
        {
            if (lines[i] is not { } marker || !IsMarker(marker.Text)) continue;
            int at = lines.FindIndex(l => l is not null && l != marker && !IsMarker(l.Text) && Math.Abs(l.CenterY - marker.CenterY) <= 0.5 * marker.Size
                && l.Left > marker.Right - 0.1 * marker.Size && l.Left - marker.Right < 3 * marker.Size);
            if (at < 0) continue;
            var text = lines[at]!;
            var runs = new List<ExportRun> { marker.Runs[0] with { Text = marker.Text + " " } };
            runs.AddRange(text.Runs);
            lines[at] = new ExLine
            {
                Box = new DisplayRect(marker.Left, Math.Min(marker.Top, text.Top), text.Right - marker.Left, Math.Max(marker.Bottom, text.Bottom) - Math.Min(marker.Top, text.Top)),
                Runs = runs,
                Size = text.Size,
                AllBold = text.AllBold,
                Before = text.Before,
                Block = text.Block,
                IsArtifact = text.IsArtifact,
            };
            lines[i] = null;
        }
    }

    public static List<ExRow> Rows(IEnumerable<ExLine> lines)
    {
        var rows = new List<ExRow>();
        foreach (var line in lines)
        {
            if (rows.Count == 0 || line.Before != TextBreak.Tab) rows.Add(new ExRow());
            rows[^1].Cells.Add(line);
        }
        return rows;
    }

    /// <summary>A block the text layer found to be a table, as cells under columns; null when it has fewer than two columns.</summary>
    public static ExportTable? Aligned(List<ExRow> rows)
    {
        if (rows.Count < 2) return null;
        bool even = rows.All(r => r.Cells.Count == rows[0].Cells.Count);
        var spans = new List<(double L, double R)>();
        if (!even)
        {
            // Cells whose extents overlap sit in one column.
            foreach (var cell in rows.SelectMany(r => r.Cells).OrderBy(c => c.Left))
            {
                if (spans.Count > 0 && cell.Left <= spans[^1].R + 0.5) spans[^1] = (spans[^1].L, Math.Max(spans[^1].R, cell.Right));
                else spans.Add((cell.Left, cell.Right));
            }
        }
        int columns = even ? rows[0].Cells.Count : spans.Count;
        if (columns < 2) return null;

        var body = new List<IReadOnlyList<string>>();
        foreach (var row in rows)
        {
            var cells = new string[columns];
            Array.Fill(cells, "");
            for (int i = 0; i < row.Cells.Count; i++)
            {
                var cell = row.Cells[i];
                double middle = (cell.Left + cell.Right) / 2;
                int c = even ? i : spans.FindIndex(s => middle <= s.R + 0.25);
                if (c < 0) c = columns - 1;
                cells[c] = cells[c].Length > 0 ? cells[c] + " " + cell.Text : cell.Text;
            }
            body.Add(cells);
        }
        double left = rows.Min(r => r.Left), top = rows.Min(r => r.Top);
        return new ExportTable(new DisplayRect(left, top, rows.Max(r => r.Right) - left, rows.Max(r => r.Bottom) - top), body, null, false);
    }

    public static List<ExPara> Paragraphs(List<ExRow> rows)
    {
        var paragraphs = new List<ExPara>();
        if (rows.Count == 0) return paragraphs;
        double blockLeft = rows.Min(r => r.Left), blockRight = rows.Max(r => r.Right);
        var steps = rows.Zip(rows.Skip(1), (a, b) => b.Top - a.Top).Where(d => d > 0).Order().ToList();
        double pitch = steps.Count >= 2 ? steps[steps.Count / 2] : 0;
        ExPara? current = null;
        foreach (var row in rows)
        {
            if (Item(row) is { } item)
            {
                paragraphs.Add(current = item);
                continue;
            }
            if (current is not null && Continues(current, row, blockLeft, blockRight, pitch))
            {
                Append(current, row);
                continue;
            }
            paragraphs.Add(current = New(row, row.Runs(), null));
        }
        return paragraphs;
    }

    private static ExPara New(ExRow row, List<ExportRun> runs, (bool, int, double)? item) => new()
    {
        Runs = runs,
        Last = row,
        Size = row.Size,
        AllBold = row.AllBold,
        Left = row.Left,
        Right = row.Right,
        Top = row.Top,
        Bottom = row.Bottom,
        Item = item,
    };

    // A step well over the usual line step, with a gap, is a paragraph break; double-spaced text has no such jump.
    private static bool Continues(ExPara p, ExRow row, double blockLeft, double blockRight, double pitch)
    {
        if (row.Before != TextBreak.Line) return false;
        var prev = p.Last;
        double size = prev.Size;
        if (Math.Abs(row.Size - size) > 0.12 * size) return false;
        double gap = row.Top - prev.Bottom;
        if (pitch > 0 ? row.Top - prev.Top > 1.4 * pitch && gap > 0.2 * size : gap > 0.4 * size) return false;
        if (p.Lines == 1 && p.AllBold != row.AllBold) return false;
        if (p.Item is { } item && row.Left < item.MarkerLeft + 0.3 * size) return false;
        if (p.Item is null && row.Left - blockLeft > 0.8 * size && prev.Left - blockLeft <= 0.3 * size) return false;
        double shortBy = blockRight - prev.Right;
        return shortBy <= Math.Max(0.25 * (blockRight - blockLeft), 3 * size);
    }

    private static void Append(ExPara p, ExRow row)
    {
        var next = row.Runs();
        string tail = p.Runs[^1].Text, head = next[0].Text;
        bool letters = tail.Length >= 2 && char.IsLetter(tail[^2]) && head.Length > 0 && char.IsLetter(head[0]);
        if (letters && tail[^1] == '\u00AD') p.Runs[^1] = p.Runs[^1] with { Text = tail[..^1] };
        else if (letters && tail[^1] == '-' && char.IsLower(head[0])) p.Runs[^1] = p.Runs[^1] with { Text = tail[..^1] };
        else if (!(letters && tail[^1] == '-')) p.Runs[^1] = p.Runs[^1] with { Text = tail + " " };
        p.Runs.AddRange(next);
        p.Last = row;
        p.Lines++;
        p.Right = Math.Max(p.Right, row.Right);
        p.Bottom = Math.Max(p.Bottom, row.Bottom);
    }

    private static ExPara? Item(ExRow row)
    {
        string first = row.Cells[0].Text;
        if (row.Cells.Count >= 2 && first.Length > 0 && (first.Length == 1 && Bullets.Contains(first[0]) || NumberOnly.IsMatch(first)))
        {
            var rest = new ExRow();
            rest.Cells.AddRange(row.Cells.Skip(1));
            var tail = rest.Runs();
            return New(row, tail, Marker(first, row));
        }
        if (first.Length >= 3 && Bullets.Contains(first[0]) && char.IsWhiteSpace(first[1]))
            return New(row, Strip(row.Runs(), 1), Marker(first[..1], row));
        if (NumberThenText.Match(first) is { Success: true } m)
            return New(row, Strip(row.Runs(), m.Length), Marker(first.Substring(0, m.Length).Trim(), row));
        return null;
    }

    private static (bool, int, double) Marker(string marker, ExRow row) =>
        char.IsAsciiDigit(marker[0]) ? (true, int.Parse(marker.TrimEnd('.', ')')), row.Left) : (false, 0, row.Left);

    private static List<ExportRun> Strip(List<ExportRun> runs, int count)
    {
        while (count > 0 && runs.Count > 0)
        {
            string text = runs[0].Text;
            if (text.Length <= count)
            {
                count -= text.Length;
                runs.RemoveAt(0);
            }
            else
            {
                runs[0] = runs[0] with { Text = text[count..].TrimStart() };
                count = 0;
            }
        }
        if (runs.Count > 0) runs[0] = runs[0] with { Text = runs[0].Text.TrimStart() };
        return runs;
    }

    /// <summary>Adjacent runs in one style become one.</summary>
    public static List<ExportRun> Merge(IEnumerable<ExportRun> runs)
    {
        var merged = new List<ExportRun>();
        foreach (var run in runs)
        {
            if (run.Text.Length == 0) continue;
            if (merged.Count > 0 && merged[^1].Bold == run.Bold && merged[^1].Italic == run.Italic && Math.Abs(merged[^1].Size - run.Size) <= 0.6)
                merged[^1] = merged[^1] with { Text = merged[^1].Text + run.Text };
            else
                merged.Add(run);
        }
        return merged;
    }
}
