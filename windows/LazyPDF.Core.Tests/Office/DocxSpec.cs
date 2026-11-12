using System.Globalization;
using System.Text;
using LazyPDF.Core;
using LazyPDF.Core.Office;

namespace LazyPDF.Core.Tests;

// Reads docx-input.txt, the cases of Tests/Fixtures/golden/office-docx, into packages and dumps what the reader made of them.
// Mirrored by Tests/LazyPDFKitTests/Office, which reads the same file.
//
//   > name                  starts a case
//   @document               the lines that follow are the inside of w:body
//   @styles, @numbering, @header, @footer, @theme   the inside of w:styles, w:numbering, w:hdr, w:ftr, a:theme
//   @part path              a whole part, written out
internal static class DocxSpec
{
    private const string Namespaces =
        "xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" " +
        "xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" " +
        "xmlns:mc=\"http://schemas.openxmlformats.org/markup-compatibility/2006\" " +
        "xmlns:m=\"http://schemas.openxmlformats.org/officeDocument/2006/math\" " +
        "xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" " +
        "xmlns:wp=\"http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing\" " +
        "xmlns:wps=\"http://schemas.microsoft.com/office/word/2010/wordprocessingShape\" " +
        "xmlns:pic=\"http://schemas.openxmlformats.org/drawingml/2006/picture\" " +
        "xmlns:c=\"http://schemas.openxmlformats.org/drawingml/2006/chart\" " +
        "xmlns:v=\"urn:schemas-microsoft-com:vml\"";

    private const string Rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/";
    private const string Main = "application/vnd.openxmlformats-officedocument.wordprocessingml.";

    public static List<(string Name, byte[] Package)> Read(string input)
    {
        var cases = new List<(string, byte[])>();
        string? name = null;
        var parts = new Dictionary<string, StringBuilder>();
        string? current = null;

        void Flush()
        {
            if (name is not null) cases.Add((name, Package(parts)));
            parts = [];
            current = null;
        }

        foreach (string line in input.Split('\n'))
        {
            if (line.StartsWith("> ", StringComparison.Ordinal))
            {
                Flush();
                name = line[2..];
            }
            else if (line.StartsWith("@", StringComparison.Ordinal))
            {
                current = line[1..];
                parts[current] = new StringBuilder();
            }
            else if (current is not null && !line.StartsWith("# ", StringComparison.Ordinal))
            {
                parts[current].Append(line).Append('\n');
            }
        }
        Flush();
        return cases;
    }

    /// <summary>The package of a case, with the boilerplate around the parts the case wrote.</summary>
    public static byte[] Package(Dictionary<string, StringBuilder> parts)
    {
        string Get(string key) => parts.TryGetValue(key, out var text) ? text.ToString() : "";
        var entries = new List<ExportZipEntry>();
        var relationships = new StringBuilder();
        var types = new StringBuilder();

        void Add(string path, string xml) => entries.Add(new ExportZipEntry(path, Encoding.UTF8.GetBytes(xml)));

        void Wrapped(string key, string path, string relationType, string id, string root, string contentType)
        {
            if (!parts.ContainsKey(key)) return;
            Add(path, $"<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><{root} {Namespaces}>{Get(key)}</{root}>");
            relationships.Append($"<Relationship Id=\"{id}\" Type=\"{Rel}{relationType}\" Target=\"{path[5..]}\"/>");
            types.Append($"<Override PartName=\"/{path}\" ContentType=\"{contentType}\"/>");
        }

        Add("word/document.xml", $"<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><w:document {Namespaces}><w:body>{Get("document")}</w:body></w:document>");
        Wrapped("styles", "word/styles.xml", "styles", "rIdS", "w:styles", Main + "styles+xml");
        Wrapped("numbering", "word/numbering.xml", "numbering", "rIdN", "w:numbering", Main + "numbering+xml");
        Wrapped("theme", "word/theme/theme1.xml", "theme", "rIdT", "a:theme", "application/vnd.openxmlformats-officedocument.theme+xml");
        Wrapped("header", "word/header1.xml", "header", "rIdH", "w:hdr", Main + "header+xml");
        Wrapped("footer", "word/footer1.xml", "footer", "rIdF", "w:ftr", Main + "footer+xml");
        foreach (var (key, text) in parts)
        {
            if (key.StartsWith("part ", StringComparison.Ordinal)) Add(key[5..], text.ToString());
        }
        Add("[Content_Types].xml",
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">" +
            "<Default Extension=\"xml\" ContentType=\"application/xml\"/>" +
            $"<Override PartName=\"/word/document.xml\" ContentType=\"{Main}document.main+xml\"/>{types}</Types>");
        Add("_rels/.rels",
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">" +
            $"<Relationship Id=\"rId1\" Type=\"{Rel}officeDocument\" Target=\"word/document.xml\"/></Relationships>");
        Add("word/_rels/document.xml.rels",
            $"<?xml version=\"1.0\" encoding=\"UTF-8\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">{relationships}</Relationships>");
        return ExportZip.Make(entries);
    }

    private static string Num(double value) => (Math.Round(value * 100, MidpointRounding.AwayFromZero) / 100 + 0.0).ToString("0.00", CultureInfo.InvariantCulture);

    public static string Dump(LayoutDocument document)
    {
        var o = new StringBuilder();
        foreach (var section in document.Sections)
        {
            var g = section.Page;
            o.Append($"section {Num(g.Width)} {Num(g.Height)} {Num(g.Top)} {Num(g.Right)} {Num(g.Bottom)} {Num(g.Left)} {Num(g.HeaderDistance)} {Num(g.FooterDistance)}\n");
            foreach (var p in section.Header) Paragraph(o, "header", p);
            foreach (var p in section.Footer) Paragraph(o, "footer", p);
            foreach (var block in section.Blocks)
            {
                if (block is LayoutParagraph p) Paragraph(o, "p", p);
                else if (block is LayoutTable t) Table(o, t);
                else o.Append("pagebreak\n");
            }
        }
        foreach (var s in document.Skipped) o.Append($"skipped {s.Kind} {s.Count}\n");
        return o.ToString();
    }

    private static string Edge(LayoutBorder? b) => b is null ? "-" : $"{Num(b.Width)}:{b.Color:x6}";

    private static void Table(StringBuilder o, LayoutTable t)
    {
        o.Append($"table {string.Join(',', t.Columns.Select(Num))} indent={Num(t.Indent)} {t.Align.ToString().ToLowerInvariant()}\n");
        foreach (var row in t.Rows)
        {
            o.Append("row");
            if (row.Header) o.Append(" header");
            if (row.CantSplit) o.Append(" cantsplit");
            if (row.Height > 0) o.Append($" height={Num(row.Height)}{(row.HeightExact ? " exact" : "")}");
            o.Append('\n');
            foreach (var c in row.Cells)
            {
                o.Append($"cell {c.Column} {c.Span} {c.RowSpan} fill={(c.Fill is { } f ? f.ToString("x6") : "-")} margin={Num(c.MarginTop)},{Num(c.MarginRight)},{Num(c.MarginBottom)},{Num(c.MarginLeft)} valign={c.VAlign.ToString().ToLowerInvariant()}");
                o.Append($" edges={Edge(c.Top)},{Edge(c.Right)},{Edge(c.Bottom)},{Edge(c.Left)}\n");
                foreach (var p in c.Paragraphs) Paragraph(o, "cp", p);
            }
        }
    }

    private static void Paragraph(StringBuilder o, string band, LayoutParagraph p)
    {
        o.Append($"{band} {p.Align.ToString().ToLowerInvariant()} {Num(p.Left)} {Num(p.Right)} {Num(p.FirstLine)} {Num(p.Before)} {Num(p.After)} {Num(p.LineSpacing)} {p.Rule.ToString().ToLowerInvariant()}");
        if (p.KeepWithNext) o.Append(" keep");
        if (p.PageBreakBefore) o.Append(" break");
        if (p.LabelTab is { } tab) o.Append($" labeltab={Num(tab)}");
        if (!p.WidowControl) o.Append(" nowidow");
        o.Append('\n');
        foreach (var r in p.Runs)
        {
            o.Append($"  run {r.Family.Replace(' ', '_')} {Num(r.Size)} {r.Color:x6}");
            if (r.Bold) o.Append(" b");
            if (r.Italic) o.Append(" i");
            if (r.Underline) o.Append(" u");
            if (r.Strike) o.Append(" s");
            if (r.Highlight is { } hl) o.Append($" hl={hl:x6}");
            if (r.Shift != 0) o.Append($" shift={Num(r.Shift)}");
            if (r.Field != LayoutField.None) o.Append($" field={r.Field.ToString().ToLowerInvariant()}");
            o.Append(" \"").Append(OfficeLayoutSpec.Escape(r.Text)).Append("\"\n");
        }
    }
}
