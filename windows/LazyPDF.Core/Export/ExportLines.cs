namespace LazyPDF.Core;

/// <summary>A line of the page text with its box in display points and its characters grouped into styled runs.</summary>
internal sealed class ExLine
{
    public required DisplayRect Box { get; init; }
    public required List<ExportRun> Runs { get; init; }
    public required double Size { get; init; }
    public required bool AllBold { get; init; }
    public required TextBreak Before { get; init; }
    public required int Block { get; init; }

    /// <summary>Every character is marked /Artifact (running heads, page numbers).</summary>
    public bool IsArtifact { get; set; }

    /// <summary>Index of the ruled table that took the line, or -1.</summary>
    public int Table { get; set; } = -1;

    public string Text => string.Concat(Runs.Select(r => r.Text));

    public double Left => Box.X;
    public double Right => Box.X + Box.Width;
    public double Top => Box.Y;
    public double Bottom => Box.Y + Box.Height;
    public double CenterY => Box.Y + Box.Height / 2;

    public static ExLine? From(TextPage page, PageLine line, PageGeometry geometry)
    {
        var runs = new List<ExportRun>();
        var weights = new Dictionary<double, int>();
        int letters = 0, bold = 0, total = 0, artifacts = 0;
        bool isBold = false, isItalic = false;
        double size = 0;
        for (int i = line.Range.Start; i < line.Range.End && i < page.Chars.Count; i++)
        {
            var c = page.Chars[i];
            if (c.Text.Length == 0) continue;
            bool space = c.IsSpace;
            if (!space)
            {
                total++;
                if (c.IsArtifact) artifacts++;
            }
            if (!space && c.Font is { } font)
            {
                (isBold, isItalic, size) = (font.IsBold, font.IsItalic, Math.Round(c.Size * 2) / 2);
                letters++;
                if (isBold) bold++;
                weights[size] = weights.GetValueOrDefault(size) + 1;
            }
            string text = space ? " " : c.Text;
            // Spaces stay in the run they follow, so one bold phrase is not cut at every space.
            if (runs.Count > 0 && (space || (runs[^1].Bold == isBold && runs[^1].Italic == isItalic && Math.Abs(runs[^1].Size - size) <= 0.6)))
            {
                runs[^1] = runs[^1] with { Text = runs[^1].Text + text };
            }
            else if (!space || runs.Count > 0)
            {
                runs.Add(new ExportRun(text, isBold, isItalic, size));
            }
        }
        Trim(runs);
        if (runs.Count == 0) return null;
        return new ExLine
        {
            Box = geometry.ToDisplay(line.Bounds),
            Runs = runs,
            Size = weights.Count == 0 ? runs[0].Size : weights.MaxBy(w => w.Value).Key,
            AllBold = letters > 0 && bold == letters,
            Before = line.Before,
            Block = line.Block,
            IsArtifact = total > 0 && artifacts == total,
        };
    }

    private static void Trim(List<ExportRun> runs)
    {
        while (runs.Count > 0 && runs[^1].Text.TrimEnd() is var end && end != runs[^1].Text)
        {
            if (end.Length == 0) runs.RemoveAt(runs.Count - 1);
            else runs[^1] = runs[^1] with { Text = end };
        }
        while (runs.Count > 0 && runs[0].Text.TrimStart() is var start && start != runs[0].Text)
        {
            if (start.Length == 0) runs.RemoveAt(0);
            else runs[0] = runs[0] with { Text = start };
        }
    }
}
