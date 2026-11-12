using System.Globalization;
using System.Text;
using LazyPDF.Core;
using LazyPDF.Core.Office;

namespace LazyPDF.Core.Tests;

// Reads xlsx-input.txt, the cases of Tests/Fixtures/golden/office-xlsx, into packages and dumps what the reader made of them.
// Mirrored by Tests/LazyPDFKitTests/Office, which reads the same file.
//
//   > name                  starts a case
//   @workbook               the lines that follow are the inside of the workbook element (sheets, definedNames, workbookPr)
//   @sheet1, @sheet2 ...    the inside of the worksheet elements; sheetN is the part the relationship rIdN points at
//   @styles, @strings, @theme   the inside of styleSheet, sst and a:theme
//   @part path              a whole part, written out
//   @relationships          extra relationships of the workbook
internal static class XlsxSpec
{
    private const string Main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main";
    private const string Rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/";
    private const string Sheet = "application/vnd.openxmlformats-officedocument.spreadsheetml.";

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
            Add(path, $"<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><{root} xmlns=\"{Main}\" xmlns:r=\"{Rel[..^1]}\" xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\">{Get(key)}</{root}>");
            relationships.Append($"<Relationship Id=\"{id}\" Type=\"{Rel}{relationType}\" Target=\"{path[3..]}\"/>");
            types.Append($"<Override PartName=\"/{path}\" ContentType=\"{contentType}\"/>");
        }

        foreach (string key in parts.Keys.Where(k => k.StartsWith("sheet", StringComparison.Ordinal)).ToList())
        {
            string n = key[5..];
            Wrapped(key, $"xl/worksheets/sheet{n}.xml", "worksheet", $"rId{n}", "worksheet", Sheet + "worksheet+xml");
        }
        Wrapped("styles", "xl/styles.xml", "styles", "rIdS", "styleSheet", Sheet + "styles+xml");
        Wrapped("strings", "xl/sharedStrings.xml", "sharedStrings", "rIdSS", "sst", Sheet + "sharedStrings+xml");
        Wrapped("theme", "xl/theme/theme1.xml", "theme", "rIdT", "a:theme", "application/vnd.openxmlformats-officedocument.theme+xml");
        relationships.Append(Get("relationships"));
        foreach (var (key, text) in parts)
        {
            if (key.StartsWith("part ", StringComparison.Ordinal)) Add(key[5..], text.ToString());
        }
        Add("xl/workbook.xml", $"<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><workbook xmlns=\"{Main}\" xmlns:r=\"{Rel[..^1]}\">{Get("workbook")}</workbook>");
        Add("[Content_Types].xml",
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">" +
            "<Default Extension=\"xml\" ContentType=\"application/xml\"/>" +
            $"<Override PartName=\"/xl/workbook.xml\" ContentType=\"{Sheet}sheet.main+xml\"/>{types}</Types>");
        Add("_rels/.rels",
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">" +
            $"<Relationship Id=\"rId1\" Type=\"{Rel}officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>");
        Add("xl/_rels/workbook.xml.rels",
            $"<?xml version=\"1.0\" encoding=\"UTF-8\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">{relationships}</Relationships>");
        return ExportZip.Make(entries);
    }

    private static string Num(double value) => (Math.Round(value * 100, MidpointRounding.AwayFromZero) / 100 + 0.0).ToString("0.00", CultureInfo.InvariantCulture);

    private static string Rgb(int? color) => color is { } c ? c.ToString("x6", CultureInfo.InvariantCulture) : "-";

    private static string Edge(XlsxBorderEdge? e) => e is null ? "-" : $"{e.Style}:{Rgb(e.Color)}";

    private static string Name(int column)
    {
        var letters = new StringBuilder();
        for (int c = column; c > 0; c = (c - 1) / 26) letters.Insert(0, (char)('A' + (c - 1) % 26));
        return letters.ToString();
    }

    private static string Cells(XlsxRange r) => $"{Name(r.FirstColumn)}{r.FirstRow}:{Name(r.LastColumn)}{r.LastRow}";

    private static string Font(XlsxFont f, string separator) =>
        $"{f.Name.Replace(' ', '_')}{separator}{Num(f.Size)}{separator}{Rgb(f.Color)}{(f.Bold ? separator + "b" : "")}{(f.Italic ? separator + "i" : "")}{(f.Underline ? separator + "u" : "")}{(f.Strike ? separator + "s" : "")}";

    public static string Dump(XlsxWorkbook workbook)
    {
        var o = new StringBuilder();
        var styles = workbook.Styles;
        o.Append($"workbook{(workbook.Date1904 ? " date1904" : "")} mdw={styles.MaxDigitWidth}\n");
        if (styles.Xfs.Count > 1 || styles.Fonts.Count > 1)
        {
            for (int i = 0; i < styles.Fonts.Count; i++) o.Append($"font {i} {Font(styles.Fonts[i], " ")}\n");
            for (int i = 0; i < styles.Fills.Count; i++) o.Append($"fill {i} {Rgb(styles.Fills[i].Color)}{(styles.Fills[i].Unsupported ? " unsupported" : "")}\n");
            for (int i = 0; i < styles.Borders.Count; i++)
            {
                var b = styles.Borders[i];
                o.Append($"border {i} {Edge(b.Left)} {Edge(b.Right)} {Edge(b.Top)} {Edge(b.Bottom)}\n");
            }
            for (int i = 0; i < styles.Xfs.Count; i++)
            {
                var x = styles.Xfs[i];
                o.Append($"xf {i} font={x.Font} fill={x.Fill} border={x.Border} fmt={x.NumberFormatId} {x.Horizontal.ToString().ToLowerInvariant()} {x.Vertical.ToString().ToLowerInvariant()} indent={x.Indent}{(x.Wrap ? " wrap" : "")}{(x.Rotated ? " rotated" : "")}\n");
            }
        }
        foreach (var sheet in workbook.Sheets)
        {
            o.Append($"sheet \"{OfficeLayoutSpec.Escape(sheet.Name)}\" col={Num(sheet.DefaultColumnWidth)} row={Num(sheet.DefaultRowHeight)}\n");
            foreach (var c in sheet.Columns) o.Append($"  cols {c.First}-{c.Last} {Num(c.Width)}{(c.Hidden ? " hidden" : "")}\n");
            foreach (var row in sheet.Rows)
            {
                o.Append($"  row {row.Index}{(row.Height is { } h ? " h=" + Num(h) : "")}{(row.Hidden ? " hidden" : "")}\n");
                foreach (var c in row.Cells)
                {
                    char kind = c.Kind switch { XlsxCellKind.Number => 'n', XlsxCellKind.Text => 't', XlsxCellKind.Bool => 'b', XlsxCellKind.Error => 'e', _ => '-' };
                    o.Append($"    {Name(c.Column)}{row.Index} {kind} s={c.Style} \"{OfficeLayoutSpec.Escape(c.Text)}\"");
                    if (c.Color is { } color) o.Append($" color={Rgb(color)}");
                    if (c.RichFont is { } f) o.Append($" rich={Font(f, ",")}");
                    o.Append('\n');
                }
            }
            foreach (var m in sheet.Merges) o.Append($"  merge {Cells(m)}\n");
            if (sheet.PrintArea.Count > 0) o.Append($"  printarea {string.Join(',', sheet.PrintArea.Select(Cells))}\n");
            if (sheet.TitleRows is { } tr) o.Append($"  titlerows {tr.First}:{tr.Last}\n");
            if (sheet.TitleColumns is { } tc) o.Append($"  titlecols {Name(tc.First)}:{Name(tc.Last)}\n");
        }
        foreach (var s in workbook.Skipped) o.Append($"skipped {s.Kind} {s.Count}\n");
        return o.ToString();
    }
}
