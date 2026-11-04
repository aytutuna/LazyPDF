using System.Text;
using static LazyPDF.Core.ExportXml;

namespace LazyPDF.Core;

/// <summary>One self-contained HTML file of an <see cref="ExportDocument"/>: pictures inline as data URIs, styles in the head.</summary>
public static class HtmlWriter
{
    private const string Head = "<!DOCTYPE html>\n<html>\n<head>\n<meta charset=\"utf-8\">\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n<title>";

    /// <summary>
    /// The text reflowed: headings, paragraphs with <c>strong</c> and <c>em</c>, nested lists,
    /// tables and figures, one <c>section</c> a page.
    /// </summary>
    public static string Reflowed(ExportDocument document)
    {
        var sb = new StringBuilder(Head);
        sb.Append(Escape(document.Title ?? ExportText.Page(1))).Append("</title>\n<style>\n")
            .Append("body{font-family:Georgia,'Times New Roman',serif;line-height:1.5;max-width:46em;margin:2em auto;padding:0 1em}\n")
            .Append("section+section{border-top:1px solid #ccc;margin-top:2em;padding-top:1em}\n")
            .Append("table{border-collapse:collapse;margin:1em 0}td{border:1px solid #999;padding:.2em .5em;vertical-align:top}\n")
            .Append("img{max-width:100%;height:auto}\n</style>\n</head>\n<body>\n");
        var lists = new Stack<string>();
        int listId = 0;
        void CloseLists(int to)
        {
            while (lists.Count > to) sb.Append("</li>\n</").Append(lists.Pop()).Append(">\n");
        }

        foreach (var page in document.Pages)
        {
            sb.Append("<section id=\"page-").Append(I(page.Index + 1)).Append("\">\n");
            foreach (var block in page.Blocks)
            {
                CheckLength(sb, Encoded(block, false));
                if (block is ExportParagraph { Item: { } item } listed)
                {
                    if (lists.Count > 0 && item.ListId != listId) CloseLists(0);
                    listId = item.ListId;
                    int target = lists.Count == 0 ? 1 : Math.Min(item.Level + 1, lists.Count + 1);
                    if (lists.Count >= target)
                    {
                        CloseLists(target);
                        sb.Append("</li>\n");
                    }
                    while (lists.Count < target)
                    {
                        string tag = item.Ordered ? "ol" : "ul";
                        lists.Push(tag);
                        sb.Append('<').Append(tag);
                        if (item.Ordered && lists.Count == 1 && item.Number > 1) sb.Append(" start=\"").Append(I(item.Number)).Append('"');
                        sb.Append(">\n");
                    }
                    sb.Append("<li>");
                    Runs(sb, listed.Runs);
                    continue;
                }
                CloseLists(0);
                switch (block)
                {
                    case ExportParagraph paragraph:
                        string tag = paragraph.Heading > 0 ? "h" + I(paragraph.Heading) : "p";
                        sb.Append('<').Append(tag).Append('>');
                        Runs(sb, paragraph.Runs, paragraph.Heading > 0);
                        sb.Append("</").Append(tag).Append(">\n");
                        break;
                    case ExportTable table:
                        sb.Append("<table>\n");
                        foreach (var row in table.Rows)
                        {
                            CheckLength(sb);
                            sb.Append("<tr>");
                            foreach (string cell in row) sb.Append("<td>").Append(Escape(cell)).Append("</td>");
                            sb.Append("</tr>\n");
                        }
                        sb.Append("</table>\n");
                        break;
                    case ExportPicture picture:
                        sb.Append("<p><img src=\"data:").Append(picture.Image.MimeType).Append(";base64,").Append(Convert.ToBase64String(picture.Image.Data))
                            .Append("\" width=\"").Append(I((long)Math.Round(picture.Bounds.Width * 96 / 72))).Append("\" height=\"").Append(I((long)Math.Round(picture.Bounds.Height * 96 / 72)))
                            .Append("\" alt=\"\"></p>\n");
                        break;
                }
            }
            CloseLists(0);
            sb.Append("</section>\n");
        }
        sb.Append("</body>\n</html>\n");
        CheckLength(sb);
        return sb.ToString();
    }

    /// <summary>
    /// A file that looks like the pages: every text line a <c>span</c> at its position in points on
    /// a page-sized box, and nothing else. No pictures.
    /// </summary>
    public static string Fixed(ExportDocument document)
    {
        var sb = new StringBuilder(Head);
        sb.Append(Escape(document.Title ?? ExportText.Page(1))).Append("</title>\n<style>\n")
            .Append("body{background:#888;margin:0;padding:1em 0;font-family:Arial,'Helvetica Neue',sans-serif}\n")
            .Append(".page{position:relative;background:#fff;margin:0 auto 1em;overflow:hidden}\n")
            .Append(".page span{position:absolute;white-space:pre}\n</style>\n</head>\n<body>\n");
        foreach (var page in document.Pages)
        {
            sb.Append("<div class=\"page\" id=\"page-").Append(I(page.Index + 1)).Append("\" style=\"width:").Append(D(page.Width)).Append("pt;height:").Append(D(page.Height)).Append("pt\">\n");
            foreach (var line in page.Lines)
            {
                double size = line.Runs.OrderByDescending(r => r.Text.Length).First().Size;
                double top = line.Bounds.Y + (line.Bounds.Height - size) / 2;
                sb.Append("<span style=\"left:").Append(D(line.Bounds.X)).Append("pt;top:").Append(D(top)).Append("pt;font-size:").Append(D(size)).Append("pt;line-height:").Append(D(size)).Append("pt\">");
                foreach (var run in line.Runs)
                {
                    bool style = run.Bold || run.Italic || Math.Abs(run.Size - size) > 0.6;
                    if (style)
                    {
                        sb.Append("<span style=\"position:static");
                        if (run.Bold) sb.Append(";font-weight:bold");
                        if (run.Italic) sb.Append(";font-style:italic");
                        if (Math.Abs(run.Size - size) > 0.6) sb.Append(";font-size:").Append(D(run.Size)).Append("pt");
                        sb.Append("\">");
                    }
                    sb.Append(Escape(run.Text));
                    if (style) sb.Append("</span>");
                }
                sb.Append("</span>\n");
                CheckLength(sb);
            }
            sb.Append("</div>\n");
        }
        return sb.Append("</body>\n</html>\n").ToString();
    }

    private static void Runs(StringBuilder sb, IReadOnlyList<ExportRun> runs, bool heading = false)
    {
        foreach (var run in runs)
        {
            string text = Escape(run.Text).Replace("\t", "&emsp;");
            if (text.Trim().Length == 0)
            {
                sb.Append(text);
                continue;
            }
            // Spaces at the edges stay outside the tags.
            string lead = text[..(text.Length - text.TrimStart().Length)], trail = text[text.TrimEnd().Length..];
            sb.Append(lead);
            bool bold = run.Bold && !heading;
            if (bold) sb.Append("<strong>");
            if (run.Italic) sb.Append("<em>");
            sb.Append(text.Trim());
            if (run.Italic) sb.Append("</em>");
            if (bold) sb.Append("</strong>");
            sb.Append(trail);
        }
    }
}
