namespace LazyPDF.Core;

/// <summary>
/// Finds blanks on a scanned page from its pixels, where <see cref="FieldDetector"/> has no vector content to
/// read. The page is drawn by the renderer and cut to black and white; long horizontal runs of ink become ruled
/// lines, and two lines of one length with ink running down both ends become a box. Boxes split at the rules
/// inside them; empty ones are proposed, as are lines with nothing written above them. The words beside a blank
/// come from the page's text layer when OCR has put one there. There is no deskew, so a page turned by more than
/// about a fifth of a degree loses its longer lines.
/// </summary>
internal static class ScanFieldDetector
{
    private const double Dpi = 150;
    private const double MinBlank = 36;
    private const double MinSide = 6;
    private const double LabelReach = 150;
    private const int Slack = 3;
    private const int MaxGap = 2;
    private const int MaxSegments = 4_000;
    private const int MaxProposals = 200;
    private const double MaxInk = 0.03;

    private readonly record struct Seg(int X1, int X2, int Y1, int Y2)
    {
        public int Width => X2 - X1 + 1;
        public int Thick => Y2 - Y1 + 1;
    }

    private sealed class Ink(int width, int height, bool[] dark)
    {
        public int Width { get; } = width;
        public int Height { get; } = height;
        public bool this[int x, int y] => dark[y * Width + x];

        /// <summary>The share of the pixels of the rectangle (ends included) that are ink.</summary>
        public double Share(int x1, int y1, int x2, int y2)
        {
            x1 = Math.Max(0, x1);
            y1 = Math.Max(0, y1);
            x2 = Math.Min(Width - 1, x2);
            y2 = Math.Min(Height - 1, y2);
            if (x2 < x1 || y2 < y1) return 1;
            int count = 0;
            for (int y = y1; y <= y2; y++)
            {
                for (int x = x1; x <= x2; x++)
                {
                    if (this[x, y]) count++;
                }
            }
            return (double)count / ((x2 - x1 + 1) * (y2 - y1 + 1));
        }

        /// <summary>The share of rows of y1 to y2 with ink within two pixels of x: a vertical rule that may waver.</summary>
        public double Down(int x, int y1, int y2)
        {
            int rows = 0;
            for (int y = y1; y <= y2; y++)
            {
                for (int d = -2; d <= 2; d++)
                {
                    if (x + d >= 0 && x + d < Width && this[x + d, y])
                    {
                        rows++;
                        break;
                    }
                }
            }
            return (double)rows / Math.Max(1, y2 - y1 + 1);
        }

        public double Column(int x, int y1, int y2) => Share(x, y1, x, y2);
    }

    private sealed record Candidate(Seg Where, FieldKind Kind, int Cells = 0, bool Multiline = false, bool OnLine = false);

    public static List<FieldProposal> Detect(PdfDocument document, PdfPage page, PdfForm form, HashSet<string> names, IPageRenderer renderer, IReadOnlyList<FieldProposal> vector)
    {
        if (renderer.Render(page.Index, Dpi) is not { Width: >= 16, Height: >= 16 } image) return [];
        var geometry = new PageGeometry(page);
        double scale = image.Width / geometry.Width;
        var ink = Cut(image);
        int thickest = Math.Max(4, ink.Width / 150);
        var segments = Merge(Segments(ink, (int)Math.Round(MinSide * scale), thickest), thickest);
        if (segments.Count == 0 || segments.Count > MaxSegments) return [];

        var edges = new HashSet<Seg>();
        var found = new List<Candidate>();
        Boxes(ink, segments, scale, edges, found);
        Lines(ink, segments, scale, edges, found);

        TextPage? text = null;
        try
        {
            text = TextPage.Create(document, page);
        }
        catch (PdfReadException)
        {
        }
        var taken = form.Fields.SelectMany(f => f.Widgets).Where(w => w.PageIndex == page.Index).Select(w => w.Rect).Concat(vector.Select(p => p.Rect)).ToList();
        var accepted = new List<FieldProposal>();
        foreach (var c in found.OrderBy(c => c.Where.Y1).ThenBy(c => c.Where.X1))
        {
            if (accepted.Count >= MaxProposals) break;
            var w = c.Where;
            PageLine? label;
            PdfRect rect;
            if (c.OnLine)
            {
                // The field stands a point above its line, as tall as the label's text suggests.
                PdfRect Above(double height) => UserRect(geometry, scale, w.X1, w.Y1 - (int)Math.Round((height + 1) * scale), w.X2 + 1, w.Y1 - (int)Math.Round(scale));
                label = Label(text, Above(14), false);
                rect = Above(Math.Clamp((label?.Bounds.Height ?? 0) * 1.3, 14, 22));
            }
            else
            {
                rect = UserRect(geometry, scale, w.X1, w.Y1, w.X2 + 1, w.Y2 + 1);
                label = Label(text, rect, c.Kind == FieldKind.CheckBox);
            }
            if (taken.Any(r => FieldDetector.Covers(r, rect))) continue;
            taken.Add(rect);
            accepted.Add(new FieldProposal(page.Index, rect, c.Kind, FieldDetector.Unique(names, label?.Text, c.Kind), FieldDetector.Clean(label?.Text))
            {
                Cells = c.Cells,
                Multiline = c.Multiline,
                FromPixels = true,
            });
        }
        return accepted;
    }

    private static PdfRect UserRect(PageGeometry geometry, double scale, int x1, int y1, int x2, int y2) =>
        geometry.ToUser(new DisplayRect(x1 / scale, y1 / scale, (x2 - x1) / scale, (y2 - y1) / scale));

    // Otsu's threshold, kept between 100 and 190 so that a nearly blank page does not turn its noise into ink.
    private static Ink Cut(PdfRgbaImage image)
    {
        int count = image.Width * image.Height;
        var gray = new byte[count];
        var histogram = new int[256];
        for (int i = 0; i < count; i++)
        {
            int o = i * 4;
            gray[i] = (byte)((image.Rgba[o] * 299 + image.Rgba[o + 1] * 587 + image.Rgba[o + 2] * 114) / 1000);
            histogram[gray[i]]++;
        }
        double sum = 0;
        for (int t = 0; t < 256; t++) sum += t * (double)histogram[t];
        double below = 0, best = -1;
        int weightBelow = 0, threshold = 128;
        for (int t = 0; t < 256; t++)
        {
            weightBelow += histogram[t];
            if (weightBelow == 0 || weightBelow == count) continue;
            below += t * (double)histogram[t];
            double a = below / weightBelow, b = (sum - below) / (count - weightBelow);
            double between = (double)weightBelow * (count - weightBelow) * (a - b) * (a - b);
            if (between > best)
            {
                best = between;
                threshold = t;
            }
        }
        threshold = Math.Clamp(threshold, 100, 190);
        var dark = new bool[count];
        for (int i = 0; i < count; i++) dark[i] = gray[i] <= threshold;
        return new Ink(image.Width, image.Height, dark);
    }

    private static IEnumerable<(int X1, int X2)> Runs(Ink ink, int y, int minLength)
    {
        int x = 0;
        while (x < ink.Width)
        {
            if (!ink[x, y])
            {
                x++;
                continue;
            }
            int start = x, end = x, gap = 0;
            while (x < ink.Width)
            {
                if (ink[x, y])
                {
                    end = x;
                    gap = 0;
                }
                else if (++gap > MaxGap) break;
                x++;
            }
            if (end - start + 1 >= minLength) yield return (start, end);
            x = end + 1;
        }
    }

    // Runs on neighbouring rows that begin and end together are the rows of one line; one that gets thick is a bar or a picture.
    private static List<Seg> Segments(Ink ink, int minLength, int thickest)
    {
        var done = new List<Seg>();
        var open = new List<Seg>();
        for (int y = 0; y < ink.Height && done.Count <= MaxSegments; y++)
        {
            var next = new List<Seg>();
            foreach (var (x1, x2) in Runs(ink, y, minLength))
            {
                int at = open.FindIndex(s => Math.Abs(s.X1 - x1) <= Slack && Math.Abs(s.X2 - x2) <= Slack);
                if (at < 0)
                {
                    next.Add(new Seg(x1, x2, y, y));
                    continue;
                }
                var s = open[at];
                open.RemoveAt(at);
                next.Add(new Seg(Math.Min(s.X1, x1), Math.Max(s.X2, x2), s.Y1, y));
            }
            done.AddRange(open.Where(s => s.Thick <= thickest));
            open = next;
        }
        done.AddRange(open.Where(s => s.Thick <= thickest));
        return done;
    }

    // A line drawn thick, or a little off level, breaks into pieces on neighbouring rows; they are one line. Pieces
    // that still abut after that are the steps of a line too slanted to follow, and give nothing.
    private static List<Seg> Merge(List<Seg> segments, int thickest)
    {
        var sorted = segments.OrderBy(s => s.Y1).ThenBy(s => s.X1).ToList();
        for (int i = 0; i < sorted.Count; i++)
        {
            for (int j = i + 1; j < sorted.Count && sorted[j].Y1 <= sorted[i].Y2 + 2; j++)
            {
                var a = sorted[i];
                var b = sorted[j];
                int overlap = Math.Min(a.X2, b.X2) - Math.Max(a.X1, b.X1) + 1;
                bool same = overlap >= 0.7 * Math.Min(a.Width, b.Width);
                bool step = !same && overlap >= -Slack - 1;
                var joined = new Seg(Math.Min(a.X1, b.X1), Math.Max(a.X2, b.X2), Math.Min(a.Y1, b.Y1), Math.Max(a.Y2, b.Y2));
                if (!(same || step) || joined.Thick > thickest) continue;
                sorted[i] = joined;
                sorted.RemoveAt(j--);
            }
        }
        return [.. sorted.Where(a => !sorted.Any(b => b != a && Math.Abs(a.Y1 - b.Y1) <= thickest + 1 && Math.Min(a.X2, b.X2) - Math.Max(a.X1, b.X1) >= -Slack - 1 && a.Y1 != b.Y1))];
    }

    private static void Boxes(Ink ink, List<Seg> segments, double scale, HashSet<Seg> edges, List<Candidate> found)
    {
        int minHeight = (int)Math.Round(MinSide * scale), maxHeight = ink.Height / 2;
        for (int i = 0; i < segments.Count; i++)
        {
            var top = segments[i];
            if (top.Width > 0.95 * ink.Width) continue;
            for (int j = i + 1; j < segments.Count; j++)
            {
                var bottom = segments[j];
                int height = bottom.Y1 - top.Y2;
                if (height > maxHeight) break;
                if (height < minHeight || Math.Abs(top.X1 - bottom.X1) > Slack || Math.Abs(top.X2 - bottom.X2) > Slack) continue;
                if (ink.Down(top.X1 + 1, top.Y2, bottom.Y1) < 0.9 || ink.Down(top.X2 - 1, top.Y2, bottom.Y1) < 0.9) continue;
                edges.Add(top);
                edges.Add(bottom);
                Cells(ink, top, bottom, scale, found);
                break;
            }
        }
    }

    // The box between two lines, cut at the vertical rules inside it. Cells with ink in them are filled in already.
    private static void Cells(Ink ink, Seg top, Seg bottom, double scale, List<Candidate> found)
    {
        int x1 = Math.Min(top.X1, bottom.X1), x2 = Math.Max(top.X2, bottom.X2);
        int y1 = top.Y1, y2 = bottom.Y2;
        int inner1 = top.Y2 + 1, inner2 = bottom.Y1 - 1;
        var cuts = new List<int> { x1 };
        for (int x = x1 + Slack + 1; x < x2 - Slack - 1; x++)
        {
            if (ink.Column(x, inner1, inner2) < 0.85) continue;
            int end = x;
            while (end + 1 < x2 - Slack - 1 && ink.Column(end + 1, inner1, inner2) >= 0.85) end++;
            cuts.Add((x + end) / 2);
            x = end;
        }
        cuts.Add(x2);

        var spans = new List<(Seg Cell, bool Empty)>();
        for (int c = 0; c + 1 < cuts.Count; c++)
        {
            // The rule on each side is part of the cell's border, not of what is written in it.
            int left = cuts[c] + Slack + 1, right = cuts[c + 1] - Slack - 1;
            bool empty = right - left >= 2 && ink.Share(left, inner1 + 1, right, inner2 - 1) <= MaxInk;
            spans.Add((new Seg(cuts[c], cuts[c + 1], y1, y2), empty));
        }

        double mean = spans.Average(s => s.Cell.Width);
        if (spans.Count >= 3 && spans.All(s => s.Empty) && mean / scale <= 30 && spans.All(s => Math.Abs(s.Cell.Width - mean) <= 0.15 * mean))
        {
            found.Add(new Candidate(new Seg(x1, x2, y1, y2), FieldKind.Text, Cells: spans.Count));
            return;
        }
        foreach (var (cell, empty) in spans)
        {
            if (!empty) continue;
            double w = cell.Width / scale, h = cell.Thick / scale;
            if (Math.Max(w, h) <= 30 && Math.Min(w, h) >= MinSide && Math.Max(w, h) <= 1.35 * Math.Min(w, h)) found.Add(new Candidate(cell, FieldKind.CheckBox));
            else if (w >= 24 && h >= 9) found.Add(new Candidate(cell, FieldKind.Text, Multiline: h >= 36));
        }
    }

    // A ruled line that is not the side of a box, with nothing above it where a person would write.
    private static void Lines(Ink ink, List<Seg> segments, double scale, HashSet<Seg> edges, List<Candidate> found)
    {
        int reach = (int)Math.Round(12 * scale);
        foreach (var line in segments)
        {
            double width = line.Width / scale;
            if (edges.Contains(line) || width < MinBlank || line.Width > 0.8 * ink.Width || line.Thick > 3 * scale) continue;
            int from = line.Y1 - reach, to = line.Y1 - 2;
            if (from < 0 || ink.Share(line.X1 + 2, from, line.X2 - 2, to) > 0.02) continue;
            found.Add(new Candidate(line, FieldKind.Text, OnLine: true));
        }
    }

    private static PageLine? Label(TextPage? text, PdfRect rect, bool toRight)
    {
        if (text is null) return null;
        var beside = text.Lines.Where(l => l.Text.Trim().Length > 0 && FieldDetector.Vertical(l.Bounds, rect))
            .Select(l => (Line: l, Gap: toRight ? l.Bounds.Left - rect.Right : rect.Left - l.Bounds.Right))
            .Where(p => p.Gap is >= -2 and <= LabelReach).OrderBy(p => p.Gap).Select(p => p.Line).FirstOrDefault();
        if (beside is not null) return beside;
        return text.Lines.Where(l => l.Text.Trim().Length > 0 && l.Bounds.Bottom >= rect.Top - 2 && l.Bounds.Bottom - rect.Top <= 18
                && l.Bounds.Left >= rect.Left - 10 && l.Bounds.Left <= rect.Right)
            .OrderBy(l => l.Bounds.Bottom).FirstOrDefault();
    }
}
