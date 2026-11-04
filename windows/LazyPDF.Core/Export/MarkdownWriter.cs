using System.Text;
using static LazyPDF.Core.ExportXml;

namespace LazyPDF.Core;

/// <summary>The Markdown (CommonMark with GFM tables) of an <see cref="ExportDocument"/>. A rule separates the pages.</summary>
public static class MarkdownWriter
{
    /// <param name="embedImages">Write pictures as data URIs; otherwise they are left out, Markdown having no place for the file.</param>
    public static string Make(ExportDocument document, bool embedImages = false)
    {
        var sb = new StringBuilder();
        var counters = new Dictionary<(int List, int Level), int>();
        bool firstPage = true;
        foreach (var page in document.Pages)
        {
            if (!firstPage) sb.Append("---\n\n");
            firstPage = false;
            ExportParagraph? previous = null;
            foreach (var block in page.Blocks)
            {
                CheckLength(sb, embedImages ? Encoded(block, false) : 0);
                if (previous?.Item is { } before && !(block is ExportParagraph { Item: { } now } && now.ListId == before.ListId)) sb.Append('\n');
                switch (block)
                {
                    case ExportParagraph { Item: { } item } listed:
                        Item(sb, listed, item, counters);
                        previous = listed;
                        continue;
                    case ExportParagraph paragraph:
                        if (previous?.Item is not null) sb.Append('\n');
                        Paragraph(sb, paragraph);
                        break;
                    case ExportTable table:
                        if (previous?.Item is not null) sb.Append('\n');
                        Table(sb, table);
                        break;
                    case ExportPicture picture when embedImages:
                        if (previous?.Item is not null) sb.Append('\n');
                        sb.Append("![").Append(ExportText.Image(1)).Append("](data:").Append(picture.Image.MimeType).Append(";base64,").Append(Convert.ToBase64String(picture.Image.Data)).Append(")\n\n");
                        break;
                    default:
                        continue;
                }
                previous = block as ExportParagraph;
            }
            if (previous?.Item is not null) sb.Append('\n');
        }
        CheckLength(sb);
        return sb.ToString().TrimEnd('\n') + (sb.Length > 0 ? "\n" : "");
    }

    private static void Paragraph(StringBuilder sb, ExportParagraph paragraph)
    {
        if (paragraph.Heading > 0)
        {
            sb.Append('#', paragraph.Heading).Append(' ').Append(Escape(paragraph.Text.Replace('\t', ' ').Trim())).Append("\n\n");
            return;
        }
        sb.Append(Guard(Inline(paragraph.Runs))).Append("\n\n");
    }

    private static void Item(StringBuilder sb, ExportParagraph paragraph, ExportListItem item, Dictionary<(int, int), int> counters)
    {
        foreach (var key in counters.Keys.Where(k => k.Item1 == item.ListId && k.Item2 > item.Level).ToList()) counters.Remove(key);
        int number = counters.TryGetValue((item.ListId, item.Level), out int next) ? next : item.Level == 0 ? Math.Max(1, item.Number) : 1;
        counters[(item.ListId, item.Level)] = number + 1;
        sb.Append(' ', 3 * item.Level).Append(item.Ordered ? I(number) + ". " : "- ").Append(Inline(paragraph.Runs)).Append('\n');
    }

    private static void Table(StringBuilder sb, ExportTable table)
    {
        for (int r = 0; r < table.Rows.Count; r++)
        {
            CheckLength(sb);
            sb.Append('|');
            foreach (string cell in table.Rows[r]) sb.Append(' ').Append(Escape(cell.Replace('\n', ' ').Replace('\t', ' '))).Append(" |");
            sb.Append('\n');
            if (r == 0)
            {
                sb.Append('|');
                for (int c = 0; c < table.Columns; c++) sb.Append(" --- |");
                sb.Append('\n');
            }
        }
        sb.Append('\n');
    }

    private static string Inline(IReadOnlyList<ExportRun> runs)
    {
        var sb = new StringBuilder();
        foreach (var run in runs)
        {
            string text = run.Text.Replace('\t', ' ');
            string core = text.Trim();
            if (core.Length == 0)
            {
                sb.Append(text);
                continue;
            }
            string mark = (run.Bold ? "**" : "") + (run.Italic ? "*" : "");
            sb.Append(text[..(text.Length - text.TrimStart().Length)]).Append(mark).Append(Escape(core)).Append(new string([.. mark.Reverse()])).Append(text[text.TrimEnd().Length..]);
        }
        return sb.ToString().TrimEnd();
    }

    // A line that would start a heading, bullet, rule or numbered item gets its first mark escaped.
    private static string Guard(string text)
    {
        if (text.Length == 0) return text;
        if (text[0] is '#' or '+' or '=' || text.StartsWith("- ") || text.StartsWith("---")) return "\\" + text;
        int digits = text.TakeWhile(char.IsAsciiDigit).Count();
        return digits is > 0 and <= 9 && digits < text.Length && text[digits] is '.' or ')' ? text[..digits] + "\\" + text[digits..] : text;
    }

    private static string Escape(string text)
    {
        var sb = new StringBuilder(text.Length);
        foreach (char c in text)
        {
            if ("\\`*_[]<>|~".Contains(c)) sb.Append('\\');
            sb.Append(c);
        }
        return sb.ToString();
    }
}
