namespace LazyPDF.Core;

/// <summary>A field the detector suggests. Nothing is added until the caller accepts it with <see cref="PdfForm.AddField"/>.</summary>
/// <param name="Name">A name from the label next to the blank, unique among the form's fields and the other proposals.</param>
/// <param name="Cells">The number of boxes of a comb field, 0 for any other.</param>
public sealed record FieldProposal(int PageIndex, PdfRect Rect, FieldKind Kind, string Name, string? Label)
{
    public int Cells { get; init; }
    public bool Multiline { get; init; }

    /// <summary>Read from the pixels of a scanned page, which is a better guess than a ruling in the file but still a guess.</summary>
    public bool FromPixels { get; init; }

    /// <summary>The proposal as a spec for <see cref="PdfForm.AddField"/>.</summary>
    public FieldSpec ToSpec() => new(Kind, Name, PageIndex, Rect)
    {
        Tooltip = Label,
        Flags = (Cells > 0 ? FieldFlags.Comb : 0) | (Multiline ? FieldFlags.Multiline : 0),
        MaxLength = Cells,
        BorderColor = Kind is FieldKind.Text && Cells == 0 ? null : [0],
    };
}

/// <summary>
/// Finds blanks on a page that look like they are meant to be filled in: ruled lines and underscore
/// runs with nothing written on them, small empty squares and circles, empty boxes, rows of boxes
/// (comb fields), and a gap after a label that ends with a colon. It reads the page through the content
/// interpreter, so lines and text inside form XObjects count; scanned pages with no vector content give nothing.
/// </summary>
public static class FieldDetector
{
    private const double MinBlank = 36;
    private const double LabelReach = 150;
    private const double Overlap = 0.3;

    private sealed record Candidate(PdfRect Rect, FieldKind Kind, bool LabelRight, string? Label = null, int Cells = 0, bool Multiline = false);

    public static IReadOnlyList<FieldProposal> Detect(PdfDocument document)
    {
        var form = PdfForm.Read(document);
        var names = form.Fields.Select(f => f.Name).ToHashSet();
        return [.. document.Pages.SelectMany(p => Detect(document, p, form, names))];
    }

    public static IReadOnlyList<FieldProposal> Detect(PdfDocument document, int pageIndex)
    {
        var form = PdfForm.Read(document);
        return Detect(document, document.Pages[pageIndex], form, form.Fields.Select(f => f.Name).ToHashSet());
    }

    /// <summary>
    /// As <see cref="Detect(PdfDocument)"/>; a page that is a scan, with or without a text layer from OCR, is also
    /// drawn through <paramref name="renderer"/> and read from its pixels (<see cref="ScanFieldDetector"/>).
    /// </summary>
    public static IReadOnlyList<FieldProposal> Detect(PdfDocument document, IPageRenderer renderer, CancellationToken cancellation = default)
    {
        var form = PdfForm.Read(document);
        var names = form.Fields.Select(f => f.Name).ToHashSet();
        var kinds = OcrTriage.ClassifyAll(document);
        return [.. document.Pages.SelectMany(p =>
        {
            cancellation.ThrowIfCancellationRequested();
            return Detect(document, p, form, names, renderer, kinds[p.Index]);
        })];
    }

    /// <summary>As above for one page.</summary>
    public static IReadOnlyList<FieldProposal> Detect(PdfDocument document, int pageIndex, IPageRenderer renderer)
    {
        var form = PdfForm.Read(document);
        var page = document.Pages[pageIndex];
        return Detect(document, page, form, form.Fields.Select(f => f.Name).ToHashSet(), renderer, OcrTriage.Classify(document, page));
    }

    private static List<FieldProposal> Detect(PdfDocument document, PdfPage page, PdfForm form, HashSet<string> names, IPageRenderer renderer, OcrPageKind kind)
    {
        var found = Detect(document, page, form, names);
        if (kind is OcrPageKind.Picture or OcrPageKind.OwnLayer or OcrPageKind.ForeignLayer) found.AddRange(ScanFieldDetector.Detect(document, page, form, names, renderer, found));
        return found;
    }

    private static List<FieldProposal> Detect(PdfDocument document, PdfPage page, PdfForm form, HashSet<string> names)
    {
        var scan = new PageScan();
        try
        {
            new ContentInterpreter(document).Run(page, scan);
        }
        catch (PdfReadException)
        {
        }
        var runs = scan.Runs();
        var crop = page.CropBox;
        var taken = form.Fields.SelectMany(f => f.Widgets).Where(w => w.PageIndex == page.Index).Select(w => w.Rect).ToList();

        var candidates = new List<Candidate>();
        Boxes(scan, crop, candidates);
        foreach (var (y, x1, x2) in scan.Horizontal.OrderByDescending(l => l.Y))
        {
            if (x2 - x1 < MinBlank || x2 - x1 > 0.95 * crop.Width || Closed(scan, y, x1, x2)) continue;
            var label = LabelFor(runs, new PdfRect(x1, y, x2, y + 14), toRight: false);
            if (label is null && x2 - x1 > 300) continue;
            double height = label is null ? 16 : Math.Clamp(label.Box.Height * 1.3, 14, 22);
            candidates.Add(new Candidate(new PdfRect(x1, y + 1, x2, y + 1 + height), FieldKind.Text, false));
        }
        Underscores(runs, candidates);
        Colons(runs, crop, candidates);

        var accepted = new List<FieldProposal>();
        var rects = new List<PdfRect>(taken);
        foreach (var c in candidates)
        {
            if (rects.Any(r => Covers(r, c.Rect)) || Occupied(scan, c.Rect, c.Kind)) continue;
            rects.Add(c.Rect);
            string? label = c.Label ?? LabelFor(runs, c.Rect, c.LabelRight)?.Text;
            accepted.Add(new FieldProposal(page.Index, c.Rect, c.Kind, Unique(names, label, c.Kind), Clean(label))
            {
                Cells = c.Cells,
                Multiline = c.Multiline,
            });
        }
        return [.. accepted.OrderByDescending(p => p.Rect.Top).ThenBy(p => p.Rect.Left)];
    }

    private static void Boxes(PageScan scan, PdfRect crop, List<Candidate> candidates)
    {
        var boxes = scan.Boxes.Where(b => b.Width <= 0.95 * crop.Width && b.Height <= 0.6 * crop.Height).ToList();
        var combs = CombRows(boxes);
        foreach (var (rect, cells, _) in combs) candidates.Add(new Candidate(rect, FieldKind.Text, false, Cells: cells));
        var used = combs.SelectMany(c => c.Members).ToHashSet();
        foreach (var box in boxes.Where(b => !used.Contains(b)))
        {
            double max = Math.Max(box.Width, box.Height);
            if (max <= 30 && Math.Abs(box.Width - box.Height) <= 0.3 * max) candidates.Add(new Candidate(box, FieldKind.CheckBox, true));
            else if (box.Width >= 24 && box.Height >= 9)
            {
                int cells = InnerCells(scan, box);
                candidates.Add(new Candidate(box, FieldKind.Text, false, Cells: cells, Multiline: box.Height >= 36));
            }
        }
        foreach (var circle in scan.Circles) candidates.Add(new Candidate(circle, FieldKind.Radio, true));
    }

    // Three or more boxes of one size side by side are the cells of one comb field.
    private static List<(PdfRect Rect, int Cells, List<PdfRect> Members)> CombRows(List<PdfRect> boxes)
    {
        var rows = new List<(PdfRect, int, List<PdfRect>)>();
        var small = boxes.Where(b => b.Width is >= 6 and <= 30 && b.Height is >= 8 and <= 40).OrderBy(b => b.Bottom).ThenBy(b => b.Left).ToList();
        var run = new List<PdfRect>();
        void End()
        {
            if (run.Count >= 3) rows.Add((new PdfRect(run[0].Left, run[0].Bottom, run[^1].Right, run[0].Top), run.Count, [.. run]));
            run.Clear();
        }
        foreach (var b in small)
        {
            if (run.Count > 0)
            {
                var last = run[^1];
                bool next = Math.Abs(b.Bottom - last.Bottom) <= 0.8 && Math.Abs(b.Top - last.Top) <= 0.8 && Math.Abs(b.Width - last.Width) <= 1
                    && b.Left - last.Right is >= -1.5 and <= 3;
                if (!next) End();
            }
            run.Add(b);
        }
        End();
        return rows;
    }

    // Vertical rules standing evenly inside a wide box divide it into cells.
    private static int InnerCells(PageScan scan, PdfRect box)
    {
        var inside = scan.Vertical.Where(v => v.X > box.Left + 2 && v.X < box.Right - 2 && v.Y1 <= box.Bottom + 2 && v.Y2 >= box.Top - 2).Select(v => v.X).Order().ToList();
        if (inside.Count < 2) return 0;
        double cell = box.Width / (inside.Count + 1);
        return inside.Select((x, i) => Math.Abs(x - (box.Left + cell * (i + 1)))).All(d => d <= 0.15 * cell) ? inside.Count + 1 : 0;
    }

    // A ruled line closed in on both sides is the bottom of a cell, not an underline.
    private static bool Closed(PageScan scan, double y, double x1, double x2) =>
        scan.Vertical.Any(v => Math.Abs(v.X - x1) <= 2 && v.Y1 <= y + 2 && v.Y2 >= y + 8)
        && scan.Vertical.Any(v => Math.Abs(v.X - x2) <= 2 && v.Y1 <= y + 2 && v.Y2 >= y + 8);

    private static void Underscores(List<ScanRun> runs, List<Candidate> candidates)
    {
        foreach (var run in runs)
        {
            for (int i = 0; i < run.Glyphs.Count;)
            {
                char mark = run.Glyphs[i].Text[0];
                int j = i;
                while (j < run.Glyphs.Count && run.Glyphs[j].Text == run.Glyphs[i].Text) j++;
                if (mark is '_' && j - i >= 4 || mark is '.' && j - i >= 8)
                {
                    var first = run.Glyphs[i].Box;
                    var rect = new PdfRect(first.Left, first.Bottom, run.Glyphs[j - 1].Box.Right, first.Bottom + Math.Max(14, first.Height));
                    string before = string.Concat(run.Glyphs.Take(i).Select(g => g.Text));
                    candidates.Add(new Candidate(rect, FieldKind.Text, false, before.Trim().Length > 0 ? before : null));
                }
                i = j;
            }
        }
    }

    private static void Colons(List<ScanRun> runs, PdfRect crop, List<Candidate> candidates)
    {
        foreach (var run in runs)
        {
            string text = run.Text.Trim();
            if (!text.EndsWith(':') || text.Length > 32 || text.Count(c => c == ' ') > 3) continue;
            var next = runs.Where(r => r.Box.Left > run.Box.Right && Vertical(r.Box, run.Box)).OrderBy(r => r.Box.Left).FirstOrDefault();
            double start = run.Box.Right + 4;
            double end = next is null ? Math.Min(crop.Right - 24, start + 200) : next.Box.Left - 4;
            if (end - start < MinBlank) continue;
            double height = Math.Max(14, run.Box.Height + 2);
            candidates.Add(new Candidate(new PdfRect(start, run.Box.Bottom - 1, end, run.Box.Bottom - 1 + height), FieldKind.Text, false, run.Text));
        }
    }

    internal static bool Vertical(PdfRect a, PdfRect b) => Math.Min(a.Top, b.Top) - Math.Max(a.Bottom, b.Bottom) >= 0.4 * Math.Min(a.Height, b.Height);

    // The text a blank belongs to: on its own line before it (after it for a check box or radio button), else just above it.
    private static ScanRun? LabelFor(List<ScanRun> runs, PdfRect rect, bool toRight)
    {
        var beside = runs.Where(r => Vertical(r.Box, rect) && r.Text.Trim().Length > 0 && !r.Text.Contains("____"))
            .Select(r => (Run: r, Gap: toRight ? r.Box.Left - rect.Right : rect.Left - r.Box.Right))
            .Where(p => p.Gap is >= -2 and <= LabelReach).OrderBy(p => p.Gap).Select(p => p.Run).FirstOrDefault();
        if (beside is not null) return beside;
        return runs.Where(r => r.Box.Bottom >= rect.Top - 2 && r.Box.Bottom - rect.Top <= 18 && r.Box.Left >= rect.Left - 10 && r.Box.Left <= rect.Right && r.Text.Trim().Length > 0)
            .OrderBy(r => r.Box.Bottom).FirstOrDefault();
    }

    internal static bool Covers(PdfRect existing, PdfRect candidate)
    {
        var common = existing.Intersect(candidate);
        if (common.IsEmpty) return false;
        return common.Width * common.Height > Overlap * Math.Min(existing.Width * existing.Height, candidate.Width * candidate.Height);
    }

    // Text printed in the blank means it is already filled, or that this is not a blank at all.
    private static bool Occupied(PageScan scan, PdfRect rect, FieldKind kind)
    {
        var inner = new PdfRect(rect.Left + 1, rect.Bottom + 1, rect.Right - 1, rect.Top - 1);
        if (inner.IsEmpty) return false;
        return scan.Glyphs.Any(g => g.Text.Trim().Length > 0 && g.Text[0] is not ('_' or '.') && inner.Left <= (g.Box.Left + g.Box.Right) / 2
            && (g.Box.Left + g.Box.Right) / 2 <= inner.Right && inner.Bottom <= (g.Box.Bottom + g.Box.Top) / 2 && (g.Box.Bottom + g.Box.Top) / 2 <= inner.Top);
    }

    internal static string? Clean(string? label)
    {
        if (label is null) return null;
        string text = string.Join(' ', label.Replace('_', ' ').Trim().Trim(':', '.', ' ').Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
        return text.Length == 0 ? null : text.Length > 60 ? text[..60] : text;
    }

    internal static string Unique(HashSet<string> names, string? label, FieldKind kind)
    {
        string baseName = Clean(label)?.Replace('.', ' ') ?? kind switch { FieldKind.CheckBox => "Check", FieldKind.Radio => "Radio", _ => "Text" };
        string name = baseName;
        for (int n = 2; !names.Add(name); n++) name = baseName + n.ToString(System.Globalization.CultureInfo.InvariantCulture);
        return name;
    }
}
