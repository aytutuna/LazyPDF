using System.Text;
using static LazyPDF.Core.ExportXml;

namespace LazyPDF.Core;

/// <summary>The plain text of an <see cref="ExportDocument"/>: paragraphs apart by a blank line, list items marked, table cells joined by tabs, a form feed after each page.</summary>
public static class PlainTextWriter
{
    public static string Make(ExportDocument document)
    {
        var sb = new StringBuilder();
        var counters = new Dictionary<(int List, int Level), int>();
        foreach (var page in document.Pages)
        {
            ExportParagraph? previous = null;
            foreach (var block in page.Blocks)
            {
                CheckLength(sb);
                switch (block)
                {
                    case ExportParagraph { Item: { } item } listed:
                        if (previous?.Item is { } before && before.ListId != item.ListId) sb.Append('\n');
                        foreach (var key in counters.Keys.Where(k => k.List == item.ListId && k.Level > item.Level).ToList()) counters.Remove(key);
                        int number = counters.TryGetValue((item.ListId, item.Level), out int next) ? next : item.Level == 0 ? Math.Max(1, item.Number) : 1;
                        counters[(item.ListId, item.Level)] = number + 1;
                        sb.Append(' ', 2 * item.Level).Append(item.Ordered ? I(number) + ". " : "- ").Append(listed.Text).Append('\n');
                        previous = listed;
                        continue;
                    case ExportParagraph paragraph:
                        if (previous is not null) sb.Append('\n');
                        sb.Append(paragraph.Text).Append('\n');
                        break;
                    case ExportTable table:
                        if (previous is not null) sb.Append('\n');
                        foreach (var row in table.Rows)
                        {
                            CheckLength(sb);
                            sb.Append(string.Join('\t', row.Select(c => c.Replace('\t', ' ').Replace('\n', ' ')))).Append('\n');
                        }
                        break;
                    default:
                        continue;
                }
                previous = null;
                sb.Append('\n');
            }
            if (previous is not null) sb.Append('\n');
            sb.Append('\f');
        }
        CheckLength(sb);
        return sb.ToString();
    }
}
