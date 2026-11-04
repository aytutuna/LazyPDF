using System.Text;
using static LazyPDF.Core.ExportXml;

namespace LazyPDF.Core;

/// <summary>The Rich Text Format file of an <see cref="ExportDocument"/>: text outside ASCII as \u escapes, so Turkish and every other script survive.</summary>
public static class RtfWriter
{
    public static string Make(ExportDocument document)
    {
        var (width, height) = DocxWriter.PaperTwips(document);
        var (top, right, bottom, left) = DocxWriter.MarginsTwips(document, width, height);
        int content = width - left - right;
        var sb = new StringBuilder(@"{\rtf1\ansi\ansicpg1252\uc1\deff0{\fonttbl{\f0\fswiss Calibri;}}");
        if (document.Title is { Length: > 0 } title) sb.Append(@"{\info{\title ").Append(Text(title)).Append("}}");
        sb.Append(@"\paperw").Append(I(width)).Append(@"\paperh").Append(I(height));
        if (width > height) sb.Append(@"\landscape");
        sb.Append(@"\margl").Append(I(left)).Append(@"\margr").Append(I(right)).Append(@"\margt").Append(I(top)).Append(@"\margb").Append(I(bottom)).Append('\n');

        var counters = new Dictionary<(int List, int Level), int>();
        foreach (var page in document.Pages)
        {
            if (page.Index != document.Pages[0].Index) sb.Append(@"\page").Append('\n');
            foreach (var block in page.Blocks)
            {
                CheckLength(sb, Encoded(block, true));
                switch (block)
                {
                    case ExportParagraph paragraph:
                        Paragraph(sb, paragraph, counters);
                        break;
                    case ExportTable table:
                        Table(sb, table, content);
                        break;
                    case ExportPicture picture:
                        Picture(sb, picture, content);
                        break;
                }
            }
        }
        sb.Append('}');
        CheckLength(sb);
        return sb.ToString();
    }

    private static void Paragraph(StringBuilder sb, ExportParagraph paragraph, Dictionary<(int, int), int> counters)
    {
        sb.Append(@"\pard");
        if (paragraph.Heading > 0) sb.Append(@"\sb240\sa80");
        else sb.Append(@"\sa120");
        if (paragraph.Item is { } item)
        {
            sb.Append(@"\li").Append(I(720 + 360 * item.Level)).Append(@"\fi-360 ");
            foreach (var key in counters.Keys.Where(k => k.Item1 == item.ListId && k.Item2 > item.Level).ToList()) counters.Remove(key);
            int number = counters.TryGetValue((item.ListId, item.Level), out int next) ? next : item.Level == 0 ? Math.Max(1, item.Number) : 1;
            counters[(item.ListId, item.Level)] = number + 1;
            sb.Append(item.Ordered ? I(number) + "." : @"\u8226?").Append(@"\tab ");
        }
        foreach (var run in paragraph.Runs)
        {
            double size = paragraph.Heading > 0 ? Math.Max(run.Size, 12) : run.Size;
            sb.Append(@"{\fs").Append(I((long)Math.Round(size * 2)));
            if (run.Bold || paragraph.Heading > 0) sb.Append(@"\b");
            if (run.Italic) sb.Append(@"\i");
            sb.Append(' ').Append(Text(run.Text)).Append('}');
        }
        sb.Append(@"\par").Append('\n');
    }

    private static void Table(StringBuilder sb, ExportTable table, int content)
    {
        int columns = Math.Min(table.Columns, DocxWriter.MaxTableColumns);
        if (columns == 0) return;
        var share = DocxWriter.Shares(table, columns);
        double total = share.Sum();
        foreach (var row in table.Rows)
        {
            CheckLength(sb);
            sb.Append(@"\trowd\trgaph108");
            double edge = 0;
            for (int c = 0; c < columns; c++)
            {
                edge += share[c] / total * content;
                sb.Append(@"\clbrdrt\brdrs\brdrw10\clbrdrl\brdrs\brdrw10\clbrdrb\brdrs\brdrw10\clbrdrr\brdrs\brdrw10\cellx").Append(I((long)Math.Round(edge)));
            }
            for (int c = 0; c < columns; c++)
            {
                string cell = c == columns - 1 && columns < row.Count ? string.Join(" ", row.Skip(c).Where(t => t.Length > 0)) : row[c];
                sb.Append(@"\pard\intbl\fs20 ").Append(Text(cell)).Append(@"\cell");
            }
            sb.Append(@"\row").Append('\n');
        }
        sb.Append(@"\pard\par").Append('\n');
    }

    private static void Picture(StringBuilder sb, ExportPicture picture, int content)
    {
        double widthTwips = picture.Bounds.Width * 20, heightTwips = picture.Bounds.Height * 20;
        if (widthTwips > content)
        {
            heightTwips *= content / widthTwips;
            widthTwips = content;
        }
        sb.Append(@"\pard{\pict").Append(picture.Image.IsJpeg ? @"\jpegblip" : @"\pngblip").Append(@"\picw").Append(I(picture.Image.Width)).Append(@"\pich").Append(I(picture.Image.Height))
            .Append(@"\picwgoal").Append(I((long)Math.Round(widthTwips))).Append(@"\pichgoal").Append(I((long)Math.Round(heightTwips))).Append('\n')
            .Append(Convert.ToHexStringLower(picture.Image.Data)).Append(@"}\par").Append('\n');
    }

    private static string Text(string text)
    {
        var sb = new StringBuilder(text.Length);
        foreach (char c in text)
        {
            switch (c)
            {
                case '\\' or '{' or '}': sb.Append('\\').Append(c); break;
                case '\t': sb.Append(@"\tab "); break;
                case '\n': sb.Append(@"\line "); break;
                case '\r': break;
                case >= ' ' and < '\u007f': sb.Append(c); break;
                case < ' ': break;
                default: sb.Append(@"\u").Append(I((short)c)).Append('?'); break;
            }
        }
        return sb.ToString();
    }
}
