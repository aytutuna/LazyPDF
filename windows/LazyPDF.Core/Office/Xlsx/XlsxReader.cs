using System.Globalization;
using System.Text;

namespace LazyPDF.Core.Office;

/// <summary>
/// Reads an .xlsx package into an <see cref="XlsxWorkbook"/>: the visible sheets with cell text already formatted by the number
/// formats, column widths and row heights in points, merged cells and print setup names. Formulas are never calculated; the value
/// the file cached is shown. What it does not carry over is counted in <see cref="XlsxWorkbook.Skipped"/>.
/// </summary>
internal sealed class XlsxReader
{
    public const string M = "http://schemas.openxmlformats.org/spreadsheetml/2006/main";
    private const string R = "http://schemas.openxmlformats.org/officeDocument/2006/relationships";

    private sealed record SharedString(string Text, XmlElement? FirstRun, bool Rich);

    private readonly OpcPackage _package;
    private readonly XlsxLimits _limits;
    private readonly CancellationToken _cancellation;
    private readonly SortedDictionary<string, int> _skipped = new(StringComparer.Ordinal);
    private readonly List<SharedString> _strings = [];
    private DocxTheme _theme = new();
    private XlsxStyles _styles = new();
    private bool _date1904;
    private int _cells;
    private long _totalText;

    private XlsxReader(OpcPackage package, XlsxLimits limits, CancellationToken cancellation)
    {
        _package = package;
        _limits = limits;
        _cancellation = cancellation;
    }

    public static XlsxWorkbook Read(byte[] data, XlsxLimits? limits = null, CancellationToken cancellation = default)
    {
        if (data.Length >= 4 && data[0] == 0xD0 && data[1] == 0xCF && data[2] == 0x11 && data[3] == 0xE0)
        {
            throw new PdfReadException(PdfReadProblem.Unsupported, "This is an Excel 97-2003 file. Save it as .xlsx first.");
        }
        return new XlsxReader(OpcPackage.Open(data), limits ?? XlsxLimits.Default, cancellation).Run();
    }

    private XlsxWorkbook Run()
    {
        string main = _package.Relationships("").FirstOrDefault(r => r.Type == OpcPackage.OfficeDocument)?.Target
            ?? throw PdfReadException.Damaged("The file has no main workbook part.");
        if (!_package.Contains(main)) throw PdfReadException.Damaged($"The package has no part {main}.");
        string type = _package.ContentType(main) ?? "";
        if (type.Contains("binary", StringComparison.Ordinal)) throw new PdfReadException(PdfReadProblem.Unsupported, "This is an Excel binary (.xlsb) file. Save it as .xlsx first.");
        if (!type.Contains("spreadsheetml", StringComparison.Ordinal) && !type.Contains("ms-excel", StringComparison.Ordinal))
        {
            throw new PdfReadException(PdfReadProblem.Unsupported, "The file is not an Excel workbook.");
        }
        var root = _package.Xml(main);
        if (root.Uri != M || root.Name != "workbook") throw new PdfReadException(PdfReadProblem.Unsupported, "The workbook is not in the Excel 2007 format.");

        var relationships = _package.Relationships(main);
        _theme = DocxTheme.Read(Part(relationships, R + "/theme"));
        _styles = XlsxStylesReader.Read(Part(relationships, R + "/styles"), _theme, _limits);
        _date1904 = XlsxParse.Flag(root.Child(M, "workbookPr")?.Attribute("date1904"), false);
        ReadSharedStrings(Part(relationships, R + "/sharedStrings"));

        var workbook = new XlsxWorkbook { Date1904 = _date1904, Styles = _styles };
        var byIndex = new Dictionary<int, XlsxSheet>();
        var entries = root.Child(M, "sheets")?.Elements(M, "sheet").ToList() ?? [];
        if (entries.Count > _limits.MaxSheets) throw new PdfReadException(PdfReadProblem.Unsupported, $"The workbook has more than {_limits.MaxSheets} sheets.");
        for (int i = 0; i < entries.Count; i++)
        {
            _cancellation.ThrowIfCancellationRequested();
            var entry = entries[i];
            string state = entry.Attribute("state") ?? "visible";
            if (state is "hidden" or "veryHidden")
            {
                Skip(XlsxSkipped.HiddenSheet);
                continue;
            }
            var relationship = relationships.FirstOrDefault(r => r.Id == entry.Attribute(R, "id"));
            if (relationship is null || !_package.Contains(relationship.Target))
            {
                Skip(XlsxSkipped.OtherSheet);
                continue;
            }
            if (relationship.Type.EndsWith("/chartsheet", StringComparison.Ordinal))
            {
                Skip(XlsxSkipped.ChartSheet);
                continue;
            }
            if (!relationship.Type.EndsWith("/worksheet", StringComparison.Ordinal))
            {
                Skip(XlsxSkipped.OtherSheet);
                continue;
            }
            var sheet = ReadSheet(entry.Attribute("name") ?? $"Sheet{i + 1}", relationship.Target);
            workbook.Sheets.Add(sheet);
            byIndex[i] = sheet;
        }
        ReadNames(root.Child(M, "definedNames"), byIndex);
        foreach (var (kind, count) in _skipped) workbook.Skipped.Add(new SkippedFeature(kind, count));
        return workbook;
    }

    private XmlElement? Part(IReadOnlyList<OpcRelationship> relationships, string type) =>
        relationships.FirstOrDefault(r => r.Type == type) is { } r && _package.Contains(r.Target) ? _package.Xml(r.Target) : null;

    private void Skip(string kind, int count = 1)
    {
        if (count > 0) _skipped[kind] = _skipped.GetValueOrDefault(kind) + count;
    }

    // Text

    /// <summary>Replaces the _xHHHH_ escapes Excel writes for characters XML cannot hold; escapes that stand for half a surrogate pair stay as written.</summary>
    private static string Unescape(string s)
    {
        if (!s.Contains("_x", StringComparison.Ordinal)) return s;
        var o = new StringBuilder(s.Length);
        for (int i = 0; i < s.Length; i++)
        {
            if (s[i] == '_' && i + 6 < s.Length && s[i + 1] == 'x' && s[i + 6] == '_'
                && int.TryParse(s.AsSpan(i + 2, 4), NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture, out int code)
                && code is < 0xD800 or > 0xDFFF)
            {
                o.Append((char)code);
                i += 6;
            }
            else
            {
                o.Append(s[i]);
            }
        }
        return o.ToString();
    }

    private string Limited(string text)
    {
        text = Unescape(text);
        if (text.Length > _limits.MaxTextLength)
        {
            int cut = _limits.MaxTextLength;
            if (char.IsHighSurrogate(text[cut - 1])) cut--;
            text = text[..cut];
            Skip(XlsxSkipped.LongText);
        }
        _totalText += text.Length;
        if (_totalText > _limits.MaxTotalText) throw new PdfReadException(PdfReadProblem.Unsupported, "The workbook holds too much text.");
        return text;
    }

    private SharedString ReadString(XmlElement si)
    {
        var runs = si.Elements(M, "r").ToList();
        if (runs.Count == 0) return new SharedString(Limited(si.Child(M, "t")?.Text ?? ""), null, false);
        string text = string.Concat(runs.Select(r => r.Child(M, "t")?.Text ?? ""));
        return new SharedString(Limited(text), runs[0].Child(M, "rPr"), true);
    }

    private void ReadSharedStrings(XmlElement? root)
    {
        if (root is not { Uri: M, Name: "sst" }) return;
        foreach (var si in root.Elements(M, "si"))
        {
            if (_strings.Count >= _limits.MaxSharedStrings) throw new PdfReadException(PdfReadProblem.Unsupported, "The workbook has too many shared strings.");
            _strings.Add(ReadString(si));
        }
    }

    // Sheets

    private static double Points(double pixels) => pixels * 0.75;

    private double ColumnPixels(double width)
    {
        int mdw = _styles.MaxDigitWidth;
        return Math.Truncate((256 * width + Math.Truncate(128.0 / mdw)) / 256 * mdw);
    }

    private XlsxSheet ReadSheet(string name, string part)
    {
        var root = _package.Xml(part);
        if (root.Uri != M || root.Name != "worksheet") throw PdfReadException.Damaged($"The part {part} is not a worksheet.");
        var sheet = new XlsxSheet { Name = name };

        var format = root.Child(M, "sheetFormatPr");
        double baseWidth = XlsxParse.Double(format?.Attribute("baseColWidth")) ?? 8;
        sheet.DefaultColumnWidth = Points(XlsxParse.Double(format?.Attribute("defaultColWidth")) is { } stated && stated > 0 && stated <= 255
            ? ColumnPixels(stated)
            : Math.Ceiling((Math.Min(baseWidth, 255) * _styles.MaxDigitWidth + 5) / 8) * 8);
        if (XlsxParse.Double(format?.Attribute("defaultRowHeight")) is { } defaultHeight && defaultHeight > 0 && defaultHeight <= 409.5) sheet.DefaultRowHeight = defaultHeight;

        foreach (var c in root.Child(M, "cols")?.Elements(M, "col") ?? [])
        {
            if (XlsxParse.Int(c.Attribute("min")) is not { } first || XlsxParse.Int(c.Attribute("max")) is not { } last) continue;
            last = Math.Min(last, XlsxLimits.MaxColumn);
            if (first < 1 || first > last || sheet.Columns.Count >= XlsxLimits.MaxColumn) continue;
            double width = XlsxParse.Double(c.Attribute("width")) is { } w && w >= 0 && w <= 255 ? Points(ColumnPixels(w)) : sheet.DefaultColumnWidth;
            sheet.Columns.Add(new XlsxColumns(first, last, width, XlsxParse.Flag(c.Attribute("hidden"), false)));
        }

        var rows = new SortedDictionary<int, XlsxRow>();
        int previousRow = 0;
        foreach (var rowElement in root.Child(M, "sheetData")?.Elements(M, "row") ?? [])
        {
            _cancellation.ThrowIfCancellationRequested();
            int index = XlsxParse.Int(rowElement.Attribute("r")) ?? previousRow + 1;
            if (index < 1 || index > XlsxLimits.MaxRow) throw PdfReadException.Damaged("A row number is outside the sheet.");
            previousRow = index;
            if (!rows.TryGetValue(index, out var row)) rows[index] = row = new XlsxRow { Index = index };
            if (XlsxParse.Double(rowElement.Attribute("ht")) is { } height && height >= 0 && height <= 409.5) row.Height = height;
            if (XlsxParse.Flag(rowElement.Attribute("hidden"), false)) row.Hidden = true;
            ReadCells(rowElement, row);
        }
        foreach (var row in rows.Values)
        {
            if (row.Cells.Count > 0 || row.Height is not null || row.Hidden) sheet.Rows.Add(row);
        }

        ReadMerges(root.Child(M, "mergeCells"), sheet);
        ReadSetup(root, sheet.Setup);
        CountFeatures(root, part);
        return sheet;
    }

    // Page setup

    private static double Inches(string? text, double whenMissing) =>
        XlsxParse.Double(text) is { } v && v >= 0 && v <= 100 ? v * 72 : whenMissing;

    private static string Plain(XmlElement? e)
    {
        string text = e?.Text ?? "";
        if (text.Length <= 1000) return text;
        return text[..(char.IsHighSurrogate(text[999]) ? 999 : 1000)];
    }

    private static void ReadSetup(XmlElement root, XlsxPageSetup setup)
    {
        if (root.Child(M, "sheetPr")?.Child(M, "pageSetUpPr") is { } fit) setup.FitToPage = XlsxParse.Flag(fit.Attribute("fitToPage"), false);
        if (root.Child(M, "pageMargins") is { } margins)
        {
            setup.Left = Inches(margins.Attribute("left"), setup.Left);
            setup.Right = Inches(margins.Attribute("right"), setup.Right);
            setup.Top = Inches(margins.Attribute("top"), setup.Top);
            setup.Bottom = Inches(margins.Attribute("bottom"), setup.Bottom);
            setup.Header = Inches(margins.Attribute("header"), setup.Header);
            setup.Footer = Inches(margins.Attribute("footer"), setup.Footer);
        }
        if (root.Child(M, "pageSetup") is { } page)
        {
            setup.Landscape = page.Attribute("orientation") == "landscape";
            if (XlsxParse.Int(page.Attribute("paperSize")) is { } paper) setup.Paper = paper;
            if (XlsxParse.Int(page.Attribute("scale")) is { } scale && scale is >= 10 and <= 400) setup.Scale = scale;
            if (XlsxParse.Int(page.Attribute("fitToWidth")) is { } w && w <= 32767) setup.FitToWidth = w;
            if (XlsxParse.Int(page.Attribute("fitToHeight")) is { } h && h <= 32767) setup.FitToHeight = h;
            if (XlsxParse.Flag(page.Attribute("useFirstPageNumber"), false) && XlsxParse.Int(page.Attribute("firstPageNumber")) is { } first) setup.FirstPageNumber = first;
        }
        if (root.Child(M, "printOptions") is { } options)
        {
            setup.CenterHorizontally = XlsxParse.Flag(options.Attribute("horizontalCentered"), false);
            setup.CenterVertically = XlsxParse.Flag(options.Attribute("verticalCentered"), false);
            setup.Headings = XlsxParse.Flag(options.Attribute("headings"), false);
            setup.Gridlines = XlsxParse.Flag(options.Attribute("gridLines"), false);
        }
        if (root.Child(M, "headerFooter") is { } hf)
        {
            setup.DifferentOddEven = XlsxParse.Flag(hf.Attribute("differentOddEven"), false);
            setup.DifferentFirst = XlsxParse.Flag(hf.Attribute("differentFirst"), false);
            setup.ScaleWithDocument = XlsxParse.Flag(hf.Attribute("scaleWithDoc"), true);
            setup.AlignWithMargins = XlsxParse.Flag(hf.Attribute("alignWithMargins"), true);
            setup.OddHeader = Plain(hf.Child(M, "oddHeader"));
            setup.OddFooter = Plain(hf.Child(M, "oddFooter"));
            setup.EvenHeader = Plain(hf.Child(M, "evenHeader"));
            setup.EvenFooter = Plain(hf.Child(M, "evenFooter"));
            setup.FirstHeader = Plain(hf.Child(M, "firstHeader"));
            setup.FirstFooter = Plain(hf.Child(M, "firstFooter"));
        }
        Breaks(root.Child(M, "rowBreaks"), setup.RowBreaks, XlsxLimits.MaxRow);
        Breaks(root.Child(M, "colBreaks"), setup.ColumnBreaks, XlsxLimits.MaxColumn);
    }

    private static void Breaks(XmlElement? list, List<int> into, int last)
    {
        foreach (var b in list?.Elements(M, "brk") ?? [])
        {
            if (into.Count >= XlsxLimits.MaxBreaks) break;
            if (XlsxParse.Flag(b.Attribute("man"), false) && XlsxParse.Int(b.Attribute("id")) is { } id && id >= 1 && id < last) into.Add(id);
        }
        into.Sort();
    }

    // What a sheet holds that is not printed: counted, nothing more.

    private static int Count(XmlElement e, string name)
    {
        int count = 0;
        var pending = new Stack<XmlElement>();
        pending.Push(e);
        while (pending.Count > 0)
        {
            foreach (var child in pending.Pop().Elements())
            {
                if (child.Name == name) count++;
                pending.Push(child);
            }
        }
        return count;
    }

    private void CountFeatures(XmlElement root, string part)
    {
        Skip(XlsxSkipped.ConditionalFormat, root.Elements(M, "conditionalFormatting").Count());
        Skip(XlsxSkipped.DataValidation, root.Child(M, "dataValidations")?.Elements(M, "dataValidation").Count() ?? 0);
        if (root.Child(M, "extLst") is { } ext) Skip(XlsxSkipped.Sparkline, Count(ext, "sparkline"));
        foreach (var r in _package.Relationships(part))
        {
            if (!_package.Contains(r.Target)) continue;
            if (r.Type.EndsWith("/comments", StringComparison.Ordinal))
            {
                Skip(XlsxSkipped.Comment, Count(_package.Xml(r.Target), "comment"));
            }
            else if (r.Type.EndsWith("/drawing", StringComparison.Ordinal))
            {
                foreach (var anchor in _package.Xml(r.Target).Elements())
                {
                    foreach (var shape in anchor.Elements())
                    {
                        if (shape.Name == "pic") Skip(XlsxSkipped.Picture);
                        else if (shape.Name == "graphicFrame") Skip(Count(shape, "chart") > 0 ? XlsxSkipped.Chart : XlsxSkipped.Shape);
                        else if (shape.Name is "sp" or "cxnSp" or "grpSp") Skip(XlsxSkipped.Shape);
                    }
                }
            }
        }
    }

    private void ReadCells(XmlElement rowElement, XlsxRow row)
    {
        int previous = 0;
        bool sorted = true;
        foreach (var c in rowElement.Elements(M, "c"))
        {
            int column = XlsxRef.Cell(c.Attribute("r"))?.Column ?? previous + 1;
            previous = column;
            if (column < 1 || column > XlsxLimits.MaxColumn)
            {
                Skip(XlsxSkipped.CellOutsideGrid);
                continue;
            }
            if (ReadCell(c, column) is not { } cell) continue;
            if (++_cells > _limits.MaxCells) throw new PdfReadException(PdfReadProblem.Unsupported, $"The workbook has more than {_limits.MaxCells} cells.");
            if (row.Cells.Count > 0 && row.Cells[^1].Column >= column) sorted = false;
            row.Cells.Add(cell);
        }
        if (sorted) return;
        var ordered = row.Cells.OrderBy(c => c.Column).ToList();
        row.Cells.Clear();
        foreach (var cell in ordered)
        {
            if (row.Cells.Count > 0 && row.Cells[^1].Column == cell.Column) row.Cells[^1] = cell;
            else row.Cells.Add(cell);
        }
    }

    /// <summary>The cell, or null for an empty one with nothing to draw.</summary>
    private XlsxCell? ReadCell(XmlElement c, int column)
    {
        int style = XlsxParse.Int(c.Attribute("s")) is { } s && s < _styles.Xfs.Count ? s : 0;
        var xf = _styles.Xf(style);
        string type = c.Attribute("t") ?? "n";
        string? value = c.Child(M, "v")?.Text;
        bool formula = c.Child(M, "f") is not null;

        var kind = XlsxCellKind.Blank;
        string text = "";
        int? color = null;
        XlsxFont? rich = null;
        var numberFormat = _styles.Format(xf.NumberFormatId);

        void Number(double v)
        {
            var result = numberFormat.Format(v, _date1904);
            (kind, text, color) = (XlsxCellKind.Number, result.Text, result.Color);
        }

        void Text(string raw)
        {
            var result = numberFormat.FormatText(raw);
            (kind, text, color) = (XlsxCellKind.Text, result.Text, result.Color);
        }

        switch (type)
        {
            case "s" when value is not null:
                if (XlsxParse.Int(XlsxParse.Trim(value)) is { } at && at < _strings.Count) Shared(_strings[at]);
                break;
            case "inlineStr" when c.Child(M, "is") is { } inline:
                Shared(ReadString(inline));
                break;
            case "str" when value is not null:
                Text(Limited(value));
                break;
            case "b" when value is not null:
                (kind, text) = (XlsxCellKind.Bool, XlsxParse.Trim(value) == "1" ? "TRUE" : "FALSE");
                break;
            case "e" when value is not null:
                (kind, text) = (XlsxCellKind.Error, Limited(value));
                break;
            case "d" when value is not null:
                if (IsoDate(XlsxParse.Trim(value)) is { } serial) Number(serial);
                else Text(Limited(value));
                break;
            case "n" when value is not null:
                if (XlsxParse.Double(XlsxParse.Trim(value)) is { } number) Number(number);
                break;
        }

        void Shared(SharedString shared)
        {
            Text(shared.Text);
            if (!shared.Rich) return;
            Skip(XlsxSkipped.RichText);
            rich = XlsxStylesReader.RunFont(shared.FirstRun, _styles.Fonts[Math.Min(xf.Font, _styles.Fonts.Count - 1)], _theme);
        }

        if (formula && kind == XlsxCellKind.Blank && value is null && type != "inlineStr") Skip(XlsxSkipped.FormulaWithoutValue);
        if (kind == XlsxCellKind.Blank)
        {
            var fill = xf.Fill < _styles.Fills.Count ? _styles.Fills[xf.Fill] : null;
            var border = xf.Border < _styles.Borders.Count ? _styles.Borders[xf.Border] : null;
            bool visible = fill?.Color is not null || border is { } b && (b.Left ?? b.Right ?? b.Top ?? b.Bottom) is not null;
            if (!visible) return null;
        }
        else if (xf.Rotated)
        {
            Skip(XlsxSkipped.TextRotation);
        }
        if (xf.Fill < _styles.Fills.Count && _styles.Fills[xf.Fill].Unsupported) Skip(XlsxSkipped.FillPattern);
        return new XlsxCell { Column = column, Style = style, Kind = kind, Text = text, Color = color, RichFont = rich };
    }

    /// <summary>The serial number of an ISO 8601 date, time or date and time (t="d" cells), in the workbook's date system.</summary>
    private double? IsoDate(string s)
    {
        if (s.EndsWith('Z')) s = s[..^1];
        string[] halves = s.Split('T');
        if (halves.Length > 2) return null;
        string? date = halves.Length == 2 ? halves[0] : halves[0].Contains(':') ? null : halves[0];
        string? time = halves.Length == 2 ? halves[1] : date is null ? halves[0] : null;
        double days = 0;
        if (date is not null)
        {
            string[] d = date.Split('-');
            if (d.Length != 3 || d[0].Length != 4 || d[1].Length != 2 || d[2].Length != 2) return null;
            if (XlsxParse.Int(d[0]) is not { } year || XlsxParse.Int(d[1]) is not { } month || XlsxParse.Int(d[2]) is not { } day) return null;
            if (month is < 1 or > 12 || day is < 1 or > 31) return null;
            long y = month <= 2 ? year - 1 : year;
            long era = (y >= 0 ? y : y - 399) / 400;
            long yoe = y - era * 400;
            long doy = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1;
            long doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
            days = era * 146097 + doe - 719468 + (_date1904 ? 24107 : 25569);
            if (!_date1904 && days < 61) days -= 1;
            if (days < 0) return null;
        }
        if (time is null) return days;
        string[] t = time.Split(':');
        if (t.Length is < 2 or > 3 || XlsxParse.Int(t[0]) is not { } h || XlsxParse.Int(t[1]) is not { } m) return null;
        double sec = t.Length == 3 ? XlsxParse.Double(t[2]) ?? -1 : 0;
        if (h > 23 || m > 59 || sec < 0 || sec >= 60) return null;
        return days + (h * 3600 + m * 60 + sec) / 86400;
    }

    private void ReadMerges(XmlElement? merges, XlsxSheet sheet)
    {
        foreach (var m in merges?.Elements(M, "mergeCell") ?? [])
        {
            if (XlsxRef.Range(m.Attribute("ref")) is not { } range) continue;
            if (range.FirstRow == range.LastRow && range.FirstColumn == range.LastColumn) continue;
            if (sheet.Merges.Count >= _limits.MaxMergedRanges) throw new PdfReadException(PdfReadProblem.Unsupported, "The sheet has too many merged cells.");
            sheet.Merges.Add(range);
        }
    }

    // Print areas and titles

    private void ReadNames(XmlElement? names, Dictionary<int, XlsxSheet> sheets)
    {
        int seen = 0;
        foreach (var n in names?.Elements(M, "definedName") ?? [])
        {
            if (++seen > _limits.MaxDefinedNames) break;
            string? name = n.Attribute("name");
            if (name is not ("_xlnm.Print_Area" or "_xlnm.Print_Titles")) continue;
            if (XlsxParse.Int(n.Attribute("localSheetId")) is not { } id || !sheets.TryGetValue(id, out var sheet)) continue;
            foreach (string part in XlsxRef.SplitList(n.Text))
            {
                string reference = XlsxRef.AfterSheet(part);
                if (name == "_xlnm.Print_Area")
                {
                    if (XlsxRef.Range(reference) is { } range) sheet.PrintArea.Add(range);
                }
                else if (XlsxRef.Columns(reference) is { } columns) sheet.TitleColumns = columns;
                else if (XlsxRef.Rows(reference) is { } rows) sheet.TitleRows = rows;
            }
        }
    }
}

/// <summary>Cell references in A1 style, with or without the dollar signs.</summary>
internal static class XlsxRef
{
    private static (int Column, int Row)? Split(string text, out bool hasRow, out bool hasColumn)
    {
        hasRow = hasColumn = false;
        int i = 0;
        if (i < text.Length && text[i] == '$') i++;
        int letters = 0, column = 0;
        while (i < text.Length && (text[i] is >= 'A' and <= 'Z' || text[i] is >= 'a' and <= 'z') && letters < 4)
        {
            column = column * 26 + (text[i] & 0x1F);
            i++;
            letters++;
        }
        hasColumn = letters > 0;
        if (i < text.Length && text[i] == '$') i++;
        int start = i;
        while (i < text.Length && text[i] is >= '0' and <= '9') i++;
        hasRow = i > start;
        if (i != text.Length || (!hasRow && !hasColumn) || i - start > 7 || letters > 3) return null;
        int row = hasRow ? int.Parse(text[start..i], CultureInfo.InvariantCulture) : 0;
        if (column > XlsxLimits.MaxColumn || row > XlsxLimits.MaxRow || (hasRow && row < 1)) return null;
        return (column, row);
    }

    /// <summary>A single cell such as B12; null if the text is anything else.</summary>
    public static (int Column, int Row)? Cell(string? text)
    {
        if (text is null || Split(text, out bool row, out bool column) is not { } cell || !row || !column) return null;
        return cell;
    }

    public static XlsxRange? Range(string? text)
    {
        if (text is null) return null;
        int colon = text.IndexOf(':');
        var first = Cell(colon < 0 ? text : text[..colon]);
        var last = colon < 0 ? first : Cell(text[(colon + 1)..]);
        if (first is not { } a || last is not { } b) return null;
        return new XlsxRange(Math.Min(a.Row, b.Row), Math.Min(a.Column, b.Column), Math.Max(a.Row, b.Row), Math.Max(a.Column, b.Column));
    }

    /// <summary>A column span such as $A:$C.</summary>
    public static (int First, int Last)? Columns(string text)
    {
        int colon = text.IndexOf(':');
        if (colon < 0 || Split(text[..colon], out bool r1, out bool c1) is not { } a || Split(text[(colon + 1)..], out bool r2, out bool c2) is not { } b) return null;
        return r1 || r2 || !c1 || !c2 ? null : (Math.Min(a.Column, b.Column), Math.Max(a.Column, b.Column));
    }

    /// <summary>A row span such as $1:$2.</summary>
    public static (int First, int Last)? Rows(string text)
    {
        int colon = text.IndexOf(':');
        if (colon < 0 || Split(text[..colon], out bool r1, out bool c1) is not { } a || Split(text[(colon + 1)..], out bool r2, out bool c2) is not { } b) return null;
        return c1 || c2 || !r1 || !r2 ? null : (Math.Min(a.Row, b.Row), Math.Max(a.Row, b.Row));
    }

    /// <summary>The comma separated parts of a name's formula, leaving alone commas inside a quoted sheet name.</summary>
    public static List<string> SplitList(string text)
    {
        var parts = new List<string>();
        var current = new StringBuilder();
        bool quoted = false;
        foreach (char c in text)
        {
            if (c == '\'') quoted = !quoted;
            if (c == ',' && !quoted)
            {
                parts.Add(current.ToString());
                current.Clear();
            }
            else
            {
                current.Append(c);
            }
        }
        parts.Add(current.ToString());
        return parts;
    }

    /// <summary>What follows the sheet name and the exclamation mark.</summary>
    public static string AfterSheet(string part)
    {
        bool quoted = false;
        int bang = -1;
        for (int i = 0; i < part.Length; i++)
        {
            if (part[i] == '\'') quoted = !quoted;
            else if (part[i] == '!' && !quoted) bang = i;
        }
        return XlsxParse.Trim(part[(bang + 1)..]);
    }
}
