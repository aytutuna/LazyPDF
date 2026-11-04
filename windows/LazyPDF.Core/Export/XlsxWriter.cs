using System.Globalization;
using System.Text;
using static LazyPDF.Core.ExportXml;

namespace LazyPDF.Core;

/// <summary>
/// The Excel workbook (.xlsx) of an <see cref="ExportDocument"/>. Each table is a sheet; a document
/// with no table gets one sheet per page holding the page's text laid out in rows and columns by
/// position. Cells that read as numbers are numbers.
/// </summary>
public static class XlsxWriter
{
    private const string Main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main";
    private const string OfficeRel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships";
    private const int MaxSheets = 1000;
    private const int MaxColumns = 64;
    private const double ColumnGap = 6;
    private const int MaxSheetRows = 1048576, MaxSheetColumns = 16384, MaxCellChars = 32767;

    public static byte[] Make(ExportDocument document)
    {
        var sheets = new List<(string Name, List<List<string>> Rows)>();
        bool tables = document.Tables.Any();
        foreach (var page in document.Pages)
        {
            if (tables)
            {
                int n = 0;
                foreach (var table in page.Blocks.OfType<ExportTable>())
                    sheets.Add((ExportText.Table(++n, page.Index + 1), [.. table.Rows.Select(r => r.ToList())]));
            }
            else if (page.Lines.Count > 0)
            {
                sheets.Add((ExportText.Page(page.Index + 1), Grid(page.Lines)));
            }
            if (sheets.Count >= MaxSheets) break;
        }
        if (sheets.Count == 0) sheets.Add(("Sheet1", []));

        var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var unique = sheets.Select(s => Unique(SheetName(s.Name), names)).ToList();

        var types = new StringBuilder(Header);
        types.Append("<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">")
            .Append("<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/>")
            .Append("<Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>")
            .Append("<Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/>");
        for (int i = 0; i < sheets.Count; i++)
            types.Append("<Override PartName=\"/xl/worksheets/sheet").Append(I(i + 1)).Append(".xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>");
        types.Append("</Types>");

        var book = new StringBuilder(Header);
        book.Append("<workbook xmlns=\"").Append(Main).Append("\" xmlns:r=\"").Append(OfficeRel).Append("\"><sheets>");
        var rels = new StringBuilder(Header);
        rels.Append("<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">");
        for (int i = 0; i < sheets.Count; i++)
        {
            book.Append("<sheet name=\"").Append(Escape(unique[i])).Append("\" sheetId=\"").Append(I(i + 1)).Append("\" r:id=\"rId").Append(I(i + 1)).Append("\"/>");
            rels.Append("<Relationship Id=\"rId").Append(I(i + 1)).Append("\" Type=\"").Append(OfficeRel).Append("/worksheet\" Target=\"worksheets/sheet").Append(I(i + 1)).Append(".xml\"/>");
        }
        book.Append("</sheets></workbook>");
        rels.Append("<Relationship Id=\"rId").Append(I(sheets.Count + 1)).Append("\" Type=\"").Append(OfficeRel).Append("/styles\" Target=\"styles.xml\"/></Relationships>");

        const string rootRels = Header + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
            + "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>";
        const string styles = Header + "<styleSheet xmlns=\"" + Main + "\"><fonts count=\"1\"><font><sz val=\"11\"/><name val=\"Calibri\"/></font></fonts>"
            + "<fills count=\"2\"><fill><patternFill patternType=\"none\"/></fill><fill><patternFill patternType=\"gray125\"/></fill></fills>"
            + "<borders count=\"1\"><border><left/><right/><top/><bottom/><diagonal/></border></borders>"
            + "<cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs>"
            + "<cellXfs count=\"2\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\"/>"
            + "<xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyAlignment=\"1\"><alignment wrapText=\"1\" vertical=\"top\"/></xf></cellXfs>"
            + "<cellStyles count=\"1\"><cellStyle name=\"Normal\" xfId=\"0\" builtinId=\"0\"/></cellStyles></styleSheet>";

        var entries = new List<ExportZipEntry>
        {
            new("[Content_Types].xml", Utf8(types.ToString())),
            new("_rels/.rels", Utf8(rootRels)),
            new("xl/workbook.xml", Utf8(book.ToString())),
            new("xl/_rels/workbook.xml.rels", Utf8(rels.ToString())),
            new("xl/styles.xml", Utf8(styles)),
        };
        for (int i = 0; i < sheets.Count; i++) entries.Add(new($"xl/worksheets/sheet{i + 1}.xml", Utf8(Sheet(sheets[i].Rows))));
        return ExportZip.Make(entries);
    }

    private static string Sheet(List<List<string>> all)
    {
        var rows = all.Count > MaxSheetRows ? all.GetRange(0, MaxSheetRows) : all;
        int columns = rows.Count == 0 ? 1 : Math.Clamp(rows.Max(r => r.Count), 1, MaxSheetColumns);
        var sb = new StringBuilder(Header);
        sb.Append("<worksheet xmlns=\"").Append(Main).Append("\"><dimension ref=\"A1:").Append(Column(columns - 1)).Append(I(Math.Max(1, rows.Count))).Append("\"/><cols>");
        for (int c = 0; c < columns; c++)
        {
            int longest = rows.Where(r => c < r.Count).Select(r => r[c].Split('\n').Max(l => l.Length)).DefaultIfEmpty(0).Max();
            sb.Append("<col min=\"").Append(I(c + 1)).Append("\" max=\"").Append(I(c + 1)).Append("\" width=\"").Append(I(Math.Clamp(longest + 2, 8, 60))).Append("\" customWidth=\"1\"/>");
        }
        sb.Append("</cols><sheetData>");
        for (int r = 0; r < rows.Count; r++)
        {
            sb.Append("<row r=\"").Append(I(r + 1)).Append("\">");
            for (int c = 0; c < Math.Min(rows[r].Count, columns); c++)
            {
                string text = rows[r][c];
                if (text.Length == 0) continue;
                if (text.Length > MaxCellChars) text = text[..MaxCellChars];
                string at = Column(c) + I(r + 1);
                if (TryNumber(text, out double number))
                    sb.Append("<c r=\"").Append(at).Append("\"><v>").Append(number.ToString("R", CultureInfo.InvariantCulture)).Append("</v></c>");
                else
                    sb.Append("<c r=\"").Append(at).Append("\" t=\"inlineStr\"").Append(text.Contains('\n') ? " s=\"1\"" : "").Append("><is><t xml:space=\"preserve\">").Append(Escape(text)).Append("</t></is></c>");
            }
            sb.Append("</row>");
        }
        sb.Append("</sheetData></worksheet>");
        return sb.ToString();
    }

    // Lines on one row of the page share a spreadsheet row; their left edges, clustered, are the columns.
    private static List<List<string>> Grid(IReadOnlyList<ExportTextLine> lines)
    {
        var ordered = lines.Where(l => l.Text.Trim().Length > 0).OrderBy(l => l.Bounds.Y + l.Bounds.Height / 2).ToList();
        var rows = new List<List<ExportTextLine>>();
        foreach (var line in ordered)
        {
            double middle = line.Bounds.Y + line.Bounds.Height / 2;
            var last = rows.Count == 0 ? null : rows[^1];
            if (last is not null && Math.Abs(middle - (last[0].Bounds.Y + last[0].Bounds.Height / 2)) <= 0.5 * line.Bounds.Height) last.Add(line);
            else rows.Add([line]);
        }

        var starts = new List<double>();
        foreach (double left in ordered.Select(l => l.Bounds.X).Order())
        {
            if (starts.Count == 0 || left - starts[^1] > ColumnGap) starts.Add(left);
        }
        bool aligned = starts.Count <= MaxColumns;
        var grid = new List<List<string>>();
        foreach (var row in rows)
        {
            var cells = new List<string>();
            int index = 0;
            foreach (var line in row.OrderBy(l => l.Bounds.X))
            {
                int column = aligned ? starts.FindLastIndex(s => s <= line.Bounds.X + ColumnGap / 2) : Math.Min(index, MaxSheetColumns - 1);
                while (cells.Count <= Math.Max(column, 0)) cells.Add("");
                column = Math.Max(column, 0);
                if (cells[column].Length == 0) cells[column] = line.Text.Trim();
                else if (cells[column].Length < MaxCellChars) cells[column] += " " + line.Text.Trim();
                index++;
            }
            grid.Add(cells);
        }
        return grid;
    }

    /// <summary>
    /// A cell that is a number: optional sign, digits with thousands separators and a decimal
    /// separator, either "1,234.56" or "1.234,56". A single comma before exactly three digits is a
    /// thousands separator, a single dot a decimal one. A whole number with a leading zero ("007")
    /// is text, like anything over 15 digits.
    /// </summary>
    internal static bool TryNumber(string text, out double value)
    {
        value = 0;
        string t = text.Trim();
        int start = t.Length > 0 && t[0] is '-' or '+' ? 1 : 0;
        if (t.Length - start is < 1 or > 24 || !t.Skip(start).All(c => char.IsAsciiDigit(c) || c is '.' or ',') || !char.IsAsciiDigit(t[^1]) || !char.IsAsciiDigit(t[start])) return false;
        string body = t[start..];
        int dots = body.Count(c => c == '.'), commas = body.Count(c => c == ',');
        char? mark = null, group = null;
        if (dots > 0 && commas > 0)
        {
            mark = body.LastIndexOf('.') > body.LastIndexOf(',') ? '.' : ',';
            group = mark == '.' ? ',' : '.';
        }
        else if (dots == 1) mark = '.';
        else if (commas == 1 && IsGrouped(body, ',')) group = ',';
        else if (commas == 1) mark = ',';
        else if (dots > 1) group = '.';
        else if (commas > 1) group = ',';

        string integer = body, fraction = "";
        if (mark is { } m)
        {
            integer = body[..body.LastIndexOf(m)];
            fraction = body[(body.LastIndexOf(m) + 1)..];
        }
        if (group is { } g)
        {
            if (!IsGrouped(integer, g)) return false;
            integer = integer.Replace(g.ToString(), "");
        }
        if (!integer.All(char.IsAsciiDigit) || !fraction.All(char.IsAsciiDigit) || integer.Length + fraction.Length > 15) return false;
        if (mark is null && integer.Length > 1 && integer[0] == '0') return false;
        if (!double.TryParse(fraction.Length > 0 ? integer + "." + fraction : integer, NumberStyles.Float, CultureInfo.InvariantCulture, out value)) return false;
        if (t[0] == '-') value = -value;
        return true;
    }

    // One to three digits, then groups of exactly three.
    private static bool IsGrouped(string text, char mark)
    {
        string[] parts = text.Split(mark);
        return parts.Length > 1 && parts[0].Length is >= 1 and <= 3 && parts.Skip(1).All(p => p.Length == 3);
    }

    private static string Column(int index)
    {
        var letters = new StringBuilder();
        for (int n = index + 1; n > 0; n = (n - 1) / 26) letters.Insert(0, (char)('A' + (n - 1) % 26));
        return letters.ToString();
    }

    private static string SheetName(string name)
    {
        string clean = string.Concat(name.Select(c => "[]:*?/\\".Contains(c) ? ' ' : c)).Trim().Trim('\'');
        if (clean.Length > 31) clean = clean[..31];
        return clean.Length == 0 ? "Sheet" : clean;
    }

    private static string Unique(string name, HashSet<string> taken)
    {
        string candidate = name;
        for (int n = 2; !taken.Add(candidate); n++)
        {
            string suffix = " " + I(n);
            candidate = name[..Math.Min(name.Length, 31 - suffix.Length)] + suffix;
        }
        return candidate;
    }
}
