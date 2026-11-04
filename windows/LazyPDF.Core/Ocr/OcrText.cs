using System.Text;

namespace LazyPDF.Core;

// From Lazy Scan's OcrText.cs. Boxes are pixels with the origin top-left here, so nothing is
// flipped or scaled, and the input is words that are first joined into lines.

/// <summary>A line of recognized text: the words on one row, left to right, with the box around them.</summary>
public sealed record OcrLine(string Text, OcrBox Box, float Confidence, IReadOnlyList<OcrWord> Words)
{
    public static OcrLine Of(OcrWord word) => new(word.Text, word.Box, word.Confidence, [word]);
}

/// <summary>The recognized lines of one page, in reading order, and the page's size in the same unit as the boxes.</summary>
public sealed record OcrPage(IReadOnlyList<OcrLine> Lines, double Width, double Height)
{
    public static OcrPage Of(IReadOnlyList<OcrWord> words, int pixelWidth, int pixelHeight) =>
        new(OcrText.Lines(words), pixelWidth, pixelHeight);
}

/// <summary>Lines of text that belong together.</summary>
public sealed record OcrParagraph(IReadOnlyList<OcrLine> Lines, double PageWidth)
{
    public string Text => OcrText.ParagraphText(Lines, PageWidth);
}

/// <summary>
/// Turns the words an OCR engine found into lines in reading order, and into paragraphs.
///
/// Reading order: the page is cut along an empty gap, across or down, again and again (a
/// recursive X-Y cut): along the widest gap across the page when it is at least
/// <see cref="BlockGap"/> line heights tall, else along the widest gap down the page when it is at
/// least <see cref="ColumnGap"/> line heights wide and both sides are columns of two items or more,
/// else along any gap across the page. Two sides that share their rows are a table and are read
/// row by row. Items on one row become one line, a tab across a wide gap.
///
/// Paragraphs: a new one starts where the text jumps up, where the gap above a line is clearly
/// wider than the usual one, where the left edge moves by a fifth of the page, and where a line is
/// indented. Lines centred on each other are neither indented nor moved.
/// </summary>
public static class OcrText
{
    public const double ColumnGap = 2.0;
    public const double BlockGap = 1.5;
    public const double TableGapShare = 1.0;
    public const double SameRowOverlap = 0.5;
    public const double ParagraphGap = 0.75;
    public const double ParagraphGapFactor = 1.5;
    public const double IndentLines = 1.0;
    public const double LeftEdgeShift = 0.2;
    /// <summary>A line ending this share of the page width before the paragraph's longest line keeps its line break.</summary>
    public const double ShortLineShare = 0.15;
    public const double CentredLines = 0.25;
    public const double JumpLines = 0.5;
    public const string CellSeparator = "\t";

    private const int MaxDepth = 200;

    /// <summary>The words as lines in reading order.</summary>
    public static IReadOnlyList<OcrLine> Lines(IReadOnlyList<OcrWord> words) => ReadingOrder([.. words.Select(OcrLine.Of)]);

    /// <summary>
    /// The lines in reading order. Lines of one row become one line (its box is theirs together, its
    /// confidence their lowest); empty lines and empty boxes are dropped.
    /// </summary>
    public static IReadOnlyList<OcrLine> ReadingOrder(IReadOnlyList<OcrLine> lines)
    {
        var items = new List<Item>();
        foreach (var line in lines)
        {
            string text = CleanLine(line.Text);
            var box = line.Box;
            if (text.Length == 0 || !(box.Width > 0) || !(box.Height > 0)) continue;
            items.Add(new Item(line with { Text = text }, items.Count, box.X, box.Y, box.Right, box.Bottom));
        }
        var output = new List<OcrLine>();
        Cut(items, output, 0);
        return output;
    }

    public static IReadOnlyList<OcrParagraph> Paragraphs(OcrPage page) => Paragraphs(ReadingOrder(page.Lines), page.Width);

    /// <summary><paramref name="ordered"/> (as <see cref="ReadingOrder"/> returns it) split into paragraphs.</summary>
    public static IReadOnlyList<OcrParagraph> Paragraphs(IReadOnlyList<OcrLine> ordered, double pageWidth)
    {
        var items = new List<Item>();
        foreach (var line in ordered) items.Add(new Item(line, items.Count, line.Box.X, line.Box.Y, line.Box.Right, line.Box.Bottom));
        var paragraphs = new List<OcrParagraph>();
        if (items.Count == 0) return paragraphs;

        double lineHeight = Median(items.Select(i => i.Height));
        // gaps[i] runs from line i - 1 down to line i.
        var gaps = new double[items.Count];
        for (int i = 1; i < items.Count; i++) gaps[i] = items[i].Top - items[i - 1].Bottom;
        var positive = gaps.Skip(1).Where(g => g > 0).ToList();
        double pageGap = positive.Count > 0 ? Median(positive) : 0;

        var current = new List<OcrLine> { items[0].Line };
        for (int i = 1; i < items.Count; i++)
        {
            var previous = items[i - 1];
            var item = items[i];
            // A page of short paragraphs has a median gap as wide as a break, so the gaps next to this one count too.
            double usualGap = pageGap;
            if (i > 1 && gaps[i - 1] > 0) usualGap = Math.Min(usualGap, gaps[i - 1]);
            if (i + 1 < items.Count && gaps[i + 1] > 0) usualGap = Math.Min(usualGap, gaps[i + 1]);
            double breakGap = Math.Max(ParagraphGap * lineHeight, ParagraphGapFactor * usualGap);
            bool centred = Math.Abs((item.Left + item.Right) - (previous.Left + previous.Right)) / 2 <= CentredLines * lineHeight;
            bool starts = item.Top < previous.Top - JumpLines * lineHeight
                          || gaps[i] > breakGap
                          || (!centred && Math.Abs(item.Left - previous.Left) > LeftEdgeShift * pageWidth)
                          || (!centred && item.Left - previous.Left > IndentLines * lineHeight);
            if (starts)
            {
                paragraphs.Add(new OcrParagraph(current, pageWidth));
                current = [];
            }
            current.Add(item.Line);
        }
        paragraphs.Add(new OcrParagraph(current, pageWidth));
        return paragraphs;
    }

    /// <summary>
    /// A paragraph as text: a line that reaches to within <see cref="ShortLineShare"/> of the page
    /// width of the longest one wraps into the next with a space, or without the hyphen of a broken
    /// word; a short line and a table row keep their line break.
    /// </summary>
    public static string ParagraphText(IReadOnlyList<OcrLine> lines, double pageWidth)
    {
        if (lines.Count == 0) return "";
        double right = lines.Max(l => l.Box.Right);
        var sb = new StringBuilder();
        string? previous = null;
        double previousRight = 0;
        foreach (var line in lines)
        {
            string text = line.Text.Trim();
            if (text.Length == 0) continue;
            if (previous is null)
            {
                sb.Append(text);
            }
            else if (previous.Contains(CellSeparator, StringComparison.Ordinal)
                     || text.Contains(CellSeparator, StringComparison.Ordinal)
                     || previousRight < right - ShortLineShare * pageWidth)
            {
                sb.Append('\n').Append(text);
            }
            else if (sb.Length >= 2 && sb[^1] == '-' && char.IsLetter(sb[^2]) && char.IsLower(text[0]))
            {
                sb.Length -= 1;
                sb.Append(text);
            }
            else
            {
                sb.Append(' ').Append(text);
            }
            previous = text;
            previousRight = line.Box.Right;
        }
        return sb.ToString();
    }

    /// <summary>One line of text per line on the page, a blank line between paragraphs; empty when nothing was recognized.</summary>
    public static string PageText(OcrPage page) =>
        string.Join("\n\n", Paragraphs(page).Select(p => string.Join("\n", p.Lines.Select(l => l.Text))));

    /// <summary>Pages joined by two blank lines, a line break at the end; empty when no page has text.</summary>
    public static string PlainText(IReadOnlyList<OcrPage> pages)
    {
        var texts = pages.Select(PageText).ToList();
        if (texts.All(t => t.Length == 0)) return "";
        return string.Join("\n\n\n", texts) + "\n";
    }

    /// <summary>Control characters become spaces (a tab stays), runs of spaces one space, none at either end.</summary>
    public static string CleanLine(string text)
    {
        var sb = new StringBuilder(text.Length);
        foreach (char c in text)
        {
            if (c == '\t') sb.Append(c);
            else if (char.IsControl(c) || c == '\u2028' || c == '\u2029') sb.Append(' ');
            else sb.Append(c);
        }
        var cleaned = new StringBuilder(sb.Length);
        foreach (char c in sb.ToString())
        {
            if (c == ' ' && (cleaned.Length == 0 || cleaned[^1] == ' ')) continue;
            cleaned.Append(c);
        }
        return cleaned.ToString().Trim(' ', '\t');
    }

    private readonly record struct Item(OcrLine Line, int Index, double Left, double Top, double Right, double Bottom)
    {
        public double Height => Bottom - Top;
    }

    private static void Cut(List<Item> items, List<OcrLine> output, int depth)
    {
        if (items.Count == 0) return;
        if (items.Count == 1 || IsOneRow(items))
        {
            output.Add(JoinRow(items));
            return;
        }
        var byTop = items.OrderBy(i => i.Top).ThenBy(i => i.Left).ThenBy(i => i.Index).ToList();
        if (depth >= MaxDepth)
        {
            foreach (var row in Rows(byTop)) output.Add(JoinRow(row));
            return;
        }
        double lineHeight = Median(items.Select(i => i.Height));

        var (gapY, splitY) = WidestGap(byTop, i => i.Top, i => i.Bottom);
        var byLeft = items.OrderBy(i => i.Left).ThenBy(i => i.Top).ThenBy(i => i.Index).ToList();
        var (gapX, splitX) = WidestGap(byLeft, i => i.Left, i => i.Right);

        if (gapY >= BlockGap * lineHeight)
        {
            Cut(byTop.GetRange(0, splitY), output, depth + 1);
            Cut(byTop.GetRange(splitY, byTop.Count - splitY), output, depth + 1);
            return;
        }
        if (gapX >= ColumnGap * lineHeight)
        {
            var left = byLeft.GetRange(0, splitX);
            var right = byLeft.GetRange(splitX, byLeft.Count - splitX);
            // A lone item on one side is a heading's neighbour or a cell, not a column.
            if (left.Count >= 2 && right.Count >= 2 && !IsTable(left, right, gapX))
            {
                Cut(left, output, depth + 1);
                Cut(right, output, depth + 1);
                return;
            }
        }
        if (gapY > 0)
        {
            Cut(byTop.GetRange(0, splitY), output, depth + 1);
            Cut(byTop.GetRange(splitY, byTop.Count - splitY), output, depth + 1);
            return;
        }

        // No gap across the page: rows that touch, or a slanted page.
        foreach (var row in Rows(byTop)) output.Add(JoinRow(row));
    }

    /// <summary>The widest empty gap along one axis of <paramref name="sorted"/> and the index of the first item after it; (0, 0) when the items overlap throughout.</summary>
    private static (double Gap, int Split) WidestGap(List<Item> sorted, Func<Item, double> start, Func<Item, double> end)
    {
        double best = 0;
        int split = 0;
        double reach = end(sorted[0]);
        for (int i = 1; i < sorted.Count; i++)
        {
            double gap = start(sorted[i]) - reach;
            if (gap > best)
            {
                best = gap;
                split = i;
            }
            reach = Math.Max(reach, end(sorted[i]));
        }
        return (best, split);
    }

    /// <summary>
    /// More than half the items on each side share their row with one on the other, and the gap is
    /// at least <see cref="TableGapShare"/> of the narrower side's typical width: a table, not two columns.
    /// </summary>
    private static bool IsTable(List<Item> left, List<Item> right, double gap)
    {
        static bool MostlyPaired(List<Item> side, List<Item> other) =>
            2 * side.Count(item => other.Any(o => SameRow(item, o))) > side.Count;
        double narrower = Math.Min(Median(left.Select(i => i.Right - i.Left)), Median(right.Select(i => i.Right - i.Left)));
        return MostlyPaired(left, right) && MostlyPaired(right, left) && gap >= TableGapShare * narrower;
    }

    private static bool SameRow(Item a, Item b) =>
        Math.Min(a.Bottom, b.Bottom) - Math.Max(a.Top, b.Top) >= SameRowOverlap * Math.Min(a.Height, b.Height);

    private static bool IsOneRow(List<Item> items)
    {
        double top = items.Max(i => i.Top);
        double bottom = items.Min(i => i.Bottom);
        double lowest = items.Min(i => i.Height);
        return bottom - top >= SameRowOverlap * lowest;
    }

    private static List<List<Item>> Rows(List<Item> byTop)
    {
        var rows = new List<List<Item>>();
        foreach (var item in byTop)
        {
            var home = rows.FirstOrDefault(row => row.All(other =>
                SameRow(other, item) && (item.Right <= other.Left || item.Left >= other.Right)));
            if (home is null) rows.Add([item]);
            else home.Add(item);
        }
        return [.. rows.OrderBy(r => r.Min(i => i.Top)).ThenBy(r => r[0].Index)];
    }

    private static OcrLine JoinRow(List<Item> row)
    {
        if (row.Count == 1) return row[0].Line;
        var sorted = row.OrderBy(i => i.Left).ThenBy(i => i.Index).ToList();
        double lineHeight = Median(sorted.Select(i => i.Height));
        var sb = new StringBuilder(sorted[0].Line.Text);
        double reach = sorted[0].Right;
        for (int i = 1; i < sorted.Count; i++)
        {
            sb.Append(sorted[i].Left - reach >= ColumnGap * lineHeight ? CellSeparator : " ");
            sb.Append(sorted[i].Line.Text);
            reach = Math.Max(reach, sorted[i].Right);
        }
        double left = sorted.Min(i => i.Left), top = sorted.Min(i => i.Top);
        var box = new OcrBox(left, top, sorted.Max(i => i.Right) - left, sorted.Max(i => i.Bottom) - top);
        return new OcrLine(sb.ToString(), box, sorted.Min(i => i.Line.Confidence), [.. sorted.SelectMany(i => i.Line.Words)]);
    }

    private static double Median(IEnumerable<double> values)
    {
        var sorted = values.OrderBy(v => v).ToList();
        if (sorted.Count == 0) return 0;
        int mid = sorted.Count / 2;
        return sorted.Count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
    }
}
