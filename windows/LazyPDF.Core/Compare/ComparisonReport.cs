using System.Text;

namespace LazyPDF.Core;

/// <summary>
/// Shows a <see cref="ComparisonResult"/>: as a PDF, the new document with a highlight on every
/// difference that has a place in it and a summary in front, and as plain text.
/// </summary>
public static class ComparisonReport
{
    private const int MaxMarks = 5000;
    private const int MaxComment = 500;
    internal static readonly double[] Green = [0.55, 0.85, 0.55];
    internal static readonly double[] Red = [1, 0.55, 0.55];
    internal static readonly double[] Amber = [1, 0.85, 0.35];

    /// <summary>
    /// A copy of <paramref name="after"/> with highlights (green added, red removed, amber changed or
    /// moved) whose comments hold the old text, and the summary pages in front. A removal is marked at the
    /// place it was. <paramref name="after"/> is not changed; the date is the one the annotations carry.
    /// </summary>
    /// <param name="fonts">Only needed when a file name or text of the summary has characters Latin-1 lacks; without it they print as ?.</param>
    public static byte[] Write(PdfDocument after, ComparisonResult result, string oldName, string newName, IFontSource? fonts = null, DateTimeOffset? date = null)
    {
        using var copy = PdfDocument.Open(after.SaveRewrite());
        var writer = new PdfAnnotationWriter(copy, fonts);
        int marks = 0;
        bool truncated = false;
        foreach (var change in result.Changes)
        {
            if (change.NewPage < 0 || change.NewPage >= copy.Pages.Count || change.Area == ChangeArea.Document) continue;
            if (marks >= MaxMarks)
            {
                truncated = true;
                break;
            }
            marks += Mark(writer, copy.Pages[change.NewPage], change, date);
        }
        SummaryPages.Insert(copy, result, oldName, newName, truncated, fonts);
        return copy.SaveRewrite();
    }

    private static int Mark(PdfAnnotationWriter writer, PdfPage page, CompareChange change, DateTimeOffset? date)
    {
        var color = change.Kind switch
        {
            ChangeKind.Added => Green,
            ChangeKind.Removed => Red,
            _ => Amber,
        };
        var info = new AnnotationInfo("Lazy PDF", Comment(change), CompareText.KindName(change.Kind), date);
        if (change.Area == ChangeArea.Page)
        {
            var box = page.CropBox;
            writer.AddNote(page, new PdfRect(box.Left + 8, box.Top - 32, box.Left + 32, box.Top - 8), info, "Comment", color);
            return 1;
        }
        var quads = change.NewQuads.Select(Widen).ToList();
        if (quads.Count == 0) return 0;
        writer.AddTextMarkup(page, AnnotationType.Highlight, quads, info, new AnnotationStyle(color));
        return 1;
    }

    /// <summary>A highlight of no width would not show; take it two points each way across the line.</summary>
    private static MarkupQuad Widen(TextQuad q)
    {
        double dx = q.X1 - q.X0, dy = q.Y1 - q.Y0, length = Math.Sqrt(dx * dx + dy * dy);
        if (length >= 1) return new MarkupQuad(q.X3, q.Y3, q.X2, q.Y2, q.X0, q.Y0, q.X1, q.Y1);
        double ux = q.X3 - q.X0, uy = q.Y3 - q.Y0, height = Math.Sqrt(ux * ux + uy * uy);
        if (height < 1e-9) (ux, uy, height) = (0, 1, 1);
        double rx = uy / height * 2, ry = -ux / height * 2;
        return new MarkupQuad(q.X3 - rx, q.Y3 - ry, q.X2 + rx, q.Y2 + ry, q.X0 - rx, q.Y0 - ry, q.X1 + rx, q.Y1 + ry);
    }

    private static string Comment(CompareChange change)
    {
        string text = change.Area switch
        {
            ChangeArea.Text when change.Kind == ChangeKind.Removed => CompareText.Was + change.OldText,
            ChangeArea.Text when change.Kind == ChangeKind.Changed => CompareText.Was + change.OldText,
            ChangeArea.Text when change.Kind == ChangeKind.Moved => change.Detail ?? "",
            ChangeArea.Text => CompareText.KindName(change.Kind),
            _ => change.Detail ?? CompareText.KindName(change.Kind),
        };
        return text.Length > MaxComment ? text[..MaxComment] + "..." : text;
    }

    /// <summary>The result as lines of text: totals, then the differences page by page, then those of the document.</summary>
    public static string ToText(ComparisonResult result, string oldName, string newName)
    {
        var sb = new StringBuilder();
        sb.Append(CompareText.Title).Append('\n').Append(oldName).Append(" / ").Append(newName).Append('\n');
        sb.Append(CompareText.PageCounts(result.OldPageCount, result.NewPageCount)).Append('\n');
        if (result.IsIdentical) return sb.Append(CompareText.NoDifferences).Append('\n').ToString();
        var s = result.Summary;
        sb.Append(CompareText.ChangeCount(s.Total)).Append(": ")
            .Append(CompareText.KindName(ChangeKind.Added)).Append(' ').Append(s.Added).Append(", ")
            .Append(CompareText.KindName(ChangeKind.Removed)).Append(' ').Append(s.Removed).Append(", ")
            .Append(CompareText.KindName(ChangeKind.Changed)).Append(' ').Append(s.Changed).Append(", ")
            .Append(CompareText.KindName(ChangeKind.Moved)).Append(' ').Append(s.Moved).Append('\n');

        foreach (var page in result.Changes.Where(c => c.Area != ChangeArea.Document).GroupBy(c => (c.NewPage, c.OldPage)))
        {
            sb.Append('\n').Append(PageHeading(page.Key.NewPage, page.Key.OldPage)).Append('\n');
            foreach (var c in page) sb.Append("  ").Append(Line(c)).Append('\n');
        }
        var document = result.Changes.Where(c => c.Area == ChangeArea.Document).ToList();
        if (document.Count > 0)
        {
            sb.Append('\n').Append(CompareText.AreaName(ChangeArea.Document)).Append('\n');
            foreach (var c in document) sb.Append("  ").Append(Line(c)).Append('\n');
        }
        return sb.ToString();
    }

    private static string PageHeading(int newPage, int oldPage) =>
        newPage < 0 ? $"{CompareText.Pages} {oldPage + 1} (old file)" : oldPage == newPage || oldPage < 0 ? $"{CompareText.Pages} {newPage + 1}" : $"{CompareText.Pages} {newPage + 1} (was {oldPage + 1})";

    internal static string Line(CompareChange c)
    {
        string head = $"{CompareText.KindName(c.Kind)} {CompareText.AreaName(c.Area).ToLowerInvariant()}";
        string detail = c.Detail is { Length: > 0 } d ? $" ({d})" : "";
        string words = (c.OldText.Length, c.NewText.Length) switch
        {
            (0, 0) => "",
            (_, 0) => $": {Shorten(c.OldText)}",
            (0, _) => $": {Shorten(c.NewText)}",
            _ when c.OldText == c.NewText => $": {Shorten(c.NewText)}",
            _ => $": {Shorten(c.OldText)} -> {Shorten(c.NewText)}",
        };
        return head + detail + words;
    }

    private static string Shorten(string text) => text.Length > 120 ? text[..120] + "..." : text;
}
