namespace LazyPDF.Core;

/// <summary>Lays out the summary of a comparison on A4 pages and puts them in front of a document.</summary>
internal static class SummaryPages
{
    private const double Width = 595, Height = 842, Margin = 50;
    private const double Body = 10, Head = 16;
    private const int MaxPages = 20;

    private readonly record struct Line(string Text, bool Heading, double[]? Swatch = null);

    public static void Insert(PdfDocument document, ComparisonResult result, string oldName, string newName, bool truncated, IFontSource? fonts)
    {
        var lines = Lines(result, oldName, newName, truncated);
        var embedder = new PdfFontEmbedder(document, fonts);
        var regular = embedder.Add("Helvetica", FontStyles.Regular, lines.Select(l => l.Text));
        var bold = embedder.Add("Helvetica", FontStyles.Bold, lines.Select(l => l.Text));
        if (regular is null || bold is null)
        {
            lines = [.. lines.Select(l => l with { Text = Latin1(l.Text) })];
            regular = embedder.Add("Helvetica", FontStyles.Regular, lines.Select(l => l.Text))!;
            bold = embedder.Add("Helvetica", FontStyles.Bold, lines.Select(l => l.Text))!;
        }

        lines = [.. lines.SelectMany(l => (l.Heading ? bold : regular).Wrap(l.Text, l.Heading ? Head : Body, Width - 2 * Margin - 32)
            .Select((text, i) => l with { Text = text, Swatch = i == 0 ? l.Swatch : null }))];

        var pages = new List<List<(Line Line, double Y)>>();
        double y = Height - Margin;
        foreach (var line in lines)
        {
            double size = line.Heading ? Head : Body;
            if (pages.Count == 0 || y - regular.LineHeight(size) < Margin)
            {
                if (pages.Count == MaxPages) break;
                pages.Add([]);
                y = Height - Margin;
            }
            y -= regular.LineHeight(size);
            pages[^1].Add((line, y));
        }

        for (int k = 0; k < pages.Count; k++)
        {
            PageOperations.InsertBlank(document, k, Width, Height);
            var page = document.Pages[k];
            var resources = ContentResources.ForEdit(document, page);
            string regularName = ContentResources.Add(document, resources, "Font", regular.Reference, "F");
            string boldName = ContentResources.Add(document, resources, "Font", bold.Reference, "F");
            var writer = new ContentWriter();
            foreach (var (line, top) in pages[k])
            {
                var font = line.Heading ? bold : regular;
                double size = line.Heading ? Head : Body;
                double x = Margin;
                if (line.Swatch is { } c)
                {
                    writer.Save().FillRgb(c[0], c[1], c[2]).Rect(Margin, top - 1, 24, size).Fill().Restore();
                    x += 32;
                }
                writer.BeginText().FillGray(0).Font(line.Heading ? boldName : regularName, size).MoveText(x, top)
                    .Show(font.Encode(line.Text)).EndText();
            }
            page.Dictionary["Contents"] = document.Add(new PdfStream(new PdfDictionary(), writer.ToArray()));
        }
    }

    private static List<Line> Lines(ComparisonResult result, string oldName, string newName, bool truncated)
    {
        var s = result.Summary;
        var lines = new List<Line>
        {
            new(CompareText.Title, true),
            new(oldName, false),
            new(newName, false),
            new(CompareText.PageCounts(result.OldPageCount, result.NewPageCount), false),
            new("", false),
        };
        if (result.IsIdentical)
        {
            lines.Add(new Line(CompareText.NoDifferences, false));
            return lines;
        }
        lines.Add(new Line(CompareText.ChangeCount(s.Total), true));
        lines.Add(new Line($"{CompareText.KindName(ChangeKind.Added)}: {s.Added}", false, ComparisonReport.Green));
        lines.Add(new Line($"{CompareText.KindName(ChangeKind.Removed)}: {s.Removed}", false, ComparisonReport.Red));
        lines.Add(new Line($"{CompareText.KindName(ChangeKind.Changed)}: {s.Changed}", false, ComparisonReport.Amber));
        lines.Add(new Line($"{CompareText.KindName(ChangeKind.Moved)}: {s.Moved}", false, ComparisonReport.Amber));
        lines.Add(new Line("", false));
        lines.Add(new Line($"{CompareText.AreaName(ChangeArea.Text)} {s.Text}, {CompareText.AreaName(ChangeArea.Format)} {s.Format}, {CompareText.AreaName(ChangeArea.Image)} {s.Images}, "
            + $"{CompareText.AreaName(ChangeArea.Annotation)} {s.Annotations}, {CompareText.AreaName(ChangeArea.Page)} {s.Pages}, {CompareText.AreaName(ChangeArea.Document)} {s.Document}", false));
        lines.Add(new Line(CompareText.Legend, false));

        var removed = result.Pages.Where(p => p.IsRemoved).ToList();
        var others = result.Changes.Where(c => c.Area == ChangeArea.Document).ToList();
        if (removed.Count > 0 || others.Count > 0) lines.Add(new Line("", false));
        foreach (var p in removed) lines.Add(new Line($"{CompareText.PageRemoved}: {p.OldIndex + 1}", false));
        foreach (var c in others.Take(60)) lines.Add(new Line(ComparisonReport.Line(c), false));
        if (others.Count > 60) lines.Add(new Line($"... {others.Count - 60}", false));
        if (truncated) lines.Add(new Line(CompareText.MarksCapped, false));
        return lines;
    }

    private static string Latin1(string text) =>
        string.Concat(text.Select(c => c is >= ' ' and <= '~' or >= ' ' and <= 'ÿ' ? c : '?'));
}
