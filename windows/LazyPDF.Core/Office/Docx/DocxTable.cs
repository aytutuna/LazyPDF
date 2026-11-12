using System.Globalization;

namespace LazyPDF.Core.Office;

// Tables: grid, spans, vertical merges, borders, shading, margins, and the table styles that supply them.
internal sealed partial class DocxReader
{
    private const int MaxTableColumns = 63;
    private const int MaxTableRows = 5000;
    private const int MaxTableCells = 100_000;

    private bool _inCell;
    private string _tableKey = "";
    private IReadOnlyList<XmlElement> _tableLayers = [];
    private int _tableCells;

    private readonly record struct Edge(bool Set, LayoutBorder? Border);

    private readonly record struct Candidate(bool Explicit, LayoutBorder? Border);

    /// <summary>The six border slots of a table or the four of a cell; a later layer replaces only the slots it names.</summary>
    private sealed class Edges
    {
        public Edge Top, Left, Bottom, Right, InsideH, InsideV;

        public void Apply(XmlElement? borders, DocxTheme theme)
        {
            if (borders is null) return;
            foreach (var e in borders.Elements())
            {
                if (e.Uri != W || e.Attribute(W, "val") is not { } val) continue;
                Edge edge;
                if (val is "nil" or "none") edge = new Edge(true, null);
                else
                {
                    double width = Number(e.Attribute(W, "sz")) is { } eighths ? Math.Clamp(eighths / 8, 0.25, 12) : 0.5;
                    int color = Hex(e.Attribute(W, "color")) ?? (e.Attribute(W, "themeColor") is { } tc ? theme.Color(tc) : null) ?? 0;
                    edge = new Edge(true, new LayoutBorder(width, color));
                }
                switch (e.Name)
                {
                    case "top": Top = edge; break;
                    case "left": case "start": Left = edge; break;
                    case "bottom": Bottom = edge; break;
                    case "right": case "end": Right = edge; break;
                    case "insideH": InsideH = edge; break;
                    case "insideV": InsideV = edge; break;
                }
            }
        }
    }

    private sealed class Margins
    {
        public double Top, Right = 5.4, Bottom, Left = 5.4;

        public void Apply(XmlElement? mar)
        {
            if (mar is null) return;
            foreach (var e in mar.Elements())
            {
                if (e.Uri != W || Number(e.Attribute(W, "w")) is not { } twips) continue;
                double points = Math.Clamp(twips / 20, 0, 144);
                switch (e.Name)
                {
                    case "top": Top = points; break;
                    case "left": case "start": Left = points; break;
                    case "bottom": Bottom = points; break;
                    case "right": case "end": Right = points; break;
                }
            }
        }
    }

    private sealed class CellInfo
    {
        public required LayoutCell Cell { get; init; }
        public required int Row { get; init; }
        public required Edges Table { get; init; }
        public required Edges Own { get; init; }
        /// <summary>The edges of the last cell that continues this one downward; its bottom is the merged cell's bottom.</summary>
        public (Edges Table, Edges Own, int Row)? Continued { get; set; }
        public Candidate Top, Right, Bottom, Left;
    }

    private readonly record struct Look(bool FirstRow, bool LastRow, bool FirstColumn, bool LastColumn, bool BandRows, bool BandColumns);

    private void Table(XmlElement tbl)
    {
        var rows = tbl.Elements(W, "tr").ToList();
        int columns = tbl.Child(W, "tblGrid")?.Elements(W, "gridCol").Count() ?? 0, cellCount = 0;
        foreach (var tr in rows)
        {
            int at = GridBefore(tr);
            foreach (var tc in tr.Elements(W, "tc"))
            {
                at += Span(tc.Child(W, "tcPr"));
                cellCount++;
            }
            columns = Math.Max(columns, at);
        }
        if (_inCell || _inBand || rows.Count is 0 or > MaxTableRows || columns is 0 or > MaxTableColumns || _tableCells + cellCount > MaxTableCells)
        {
            // A table inside a table or a band is read as its paragraphs in order.
            Skip("table");
            foreach (var cell in rows.SelectMany(row => row.Elements(W, "tc"))) Blocks(cell);
            return;
        }
        _tableCells += cellCount;

        var tblPr = tbl.Child(W, "tblPr");
        var chain = _styles.Table(tblPr?.Child(W, "tblStyle")?.Attribute(W, "val"));
        string styleKey = chain.Count == 0 ? "" : chain[^1].Id;
        var look = ReadLook(tblPr);
        int rowBand = Math.Max(1, (int)Math.Min(Number(tblPr?.Child(W, "tblStyleRowBandSize")?.Attribute(W, "val")) ?? 1, 1000));
        int columnBand = Math.Max(1, (int)Math.Min(Number(tblPr?.Child(W, "tblStyleColBandSize")?.Attribute(W, "val")) ?? 1, 1000));

        var widths = new double[columns];
        int gridColumns = 0;
        foreach (var g in tbl.Child(W, "tblGrid")?.Elements(W, "gridCol") ?? [])
        {
            if (gridColumns < columns) widths[gridColumns++] = Math.Clamp((Number(g.Attribute(W, "w")) ?? 0) / 20, 0, 14400);
        }
        var preferred = new List<(int Column, int Span, double Width)>();

        var outRows = new List<LayoutRow>();
        var infos = new List<CellInfo>();
        var open = new CellInfo?[columns];
        for (int r = 0; r < rows.Count; r++)
        {
            var tr = rows[r];
            var trPr = tr.Child(W, "trPr");
            var cells = new List<LayoutCell>();
            var carried = new CellInfo?[columns];
            int column = GridBefore(tr);
            foreach (var tc in tr.Elements(W, "tc"))
            {
                _cancellation.ThrowIfCancellationRequested();
                var tcPr = tc.Child(W, "tcPr");
                int span = Math.Min(Span(tcPr), columns - column);
                if (span <= 0) break;

                var conditions = Conditions(look, r, rows.Count, column, span, columns, rowBand, columnBand);
                var layers = Layers(chain, conditions);
                var format = new CellFormat(this, layers, tblPr, tcPr);
                if (tcPr?.Child(W, "tcW") is { } tcW && tcW.Attribute(W, "type") is null or "dxa" && Number(tcW.Attribute(W, "w")) is { } width && width > 0)
                {
                    preferred.Add((column, span, width / 20));
                }

                var merge = tcPr?.Child(W, "vMerge");
                bool continues = merge is not null && merge.Attribute(W, "val") is null or "continue";
                if (continues && open[column] is { } above && above.Cell.Column == column && above.Cell.Span == span)
                {
                    above.Cell.RowSpan++;
                    above.Continued = (format.Table, format.Own, r);
                    for (int c = column; c < column + span; c++) carried[c] = above;
                    column += span;
                    continue;
                }

                var paragraphs = CellContent(tc, styleKey + "|" + string.Join(',', conditions), layers);
                var cell = new LayoutCell
                {
                    Column = column,
                    Span = span,
                    Paragraphs = paragraphs,
                    Fill = format.Fill,
                    MarginTop = format.Margin.Top,
                    MarginRight = format.Margin.Right,
                    MarginBottom = format.Margin.Bottom,
                    MarginLeft = format.Margin.Left,
                    VAlign = format.VAlign,
                };
                var info = new CellInfo { Cell = cell, Row = r, Table = format.Table, Own = format.Own };
                cells.Add(cell);
                infos.Add(info);
                if (merge is not null)
                {
                    for (int c = column; c < column + span; c++) carried[c] = info;
                }
                column += span;
            }
            open = carried;

            double height = 0;
            bool exact = false;
            if (trPr?.Child(W, "trHeight") is { } trHeight && Number(trHeight.Attribute(W, "val")) is { } twips)
            {
                height = Math.Clamp(twips / 20, 0, 1584);
                exact = trHeight.Attribute(W, "hRule") == "exact";
            }
            outRows.Add(new LayoutRow
            {
                Cells = cells,
                Header = trPr?.Child(W, "tblHeader") is { } header && On(header),
                CantSplit = trPr?.Child(W, "cantSplit") is { } cant && On(cant),
                Height = height,
                HeightExact = exact,
            });
        }

        if (gridColumns == 0)
        {
            foreach (var (column, span, width) in preferred)
            {
                if (Enumerable.Range(column, span).All(c => widths[c] == 0))
                {
                    for (int c = column; c < column + span; c++) widths[c] = width / span;
                }
            }
        }
        ResolveBorders(infos, outRows.Count, columns);

        double indent = Number(tblPr?.Child(W, "tblInd")?.Attribute(W, "w")) is { } ind ? Math.Clamp(ind / 20, -1584, 1584) : 0;
        var align = tblPr?.Child(W, "jc")?.Attribute(W, "val") switch
        {
            "center" => LayoutAlign.Center,
            "right" or "end" => LayoutAlign.Right,
            _ => LayoutAlign.Left,
        };
        _blocks.Add(new LayoutTable { Columns = [.. widths], Indent = indent, Align = align, Rows = outRows });
    }

    private static int GridBefore(XmlElement tr) =>
        (int)Math.Clamp(Number(tr.Child(W, "trPr")?.Child(W, "gridBefore")?.Attribute(W, "val")) ?? 0, 0, MaxTableColumns);

    private static int Span(XmlElement? tcPr) =>
        (int)Math.Clamp(Number(tcPr?.Child(W, "gridSpan")?.Attribute(W, "val")) ?? 1, 1, MaxTableColumns);

    private static Look ReadLook(XmlElement? tblPr)
    {
        var e = tblPr?.Child(W, "tblLook");
        if (e is null) return default;
        int mask = int.TryParse(e.Attribute(W, "val"), NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture, out int v) ? v : 0;
        bool Flag(string name, int bit)
        {
            return e.Attribute(W, name) is { } text ? text is "1" or "true" or "on" : (mask & bit) != 0;
        }
        return new Look(Flag("firstRow", 0x20), Flag("lastRow", 0x40), Flag("firstColumn", 0x80), Flag("lastColumn", 0x100),
            !Flag("noHBand", 0x200), !Flag("noVBand", 0x400));
    }

    // The conditional parts of a table style that apply to a cell, in the order they are laid on: later ones win.
    private static List<string> Conditions(Look look, int row, int rows, int column, int span, int columns, int rowBand, int columnBand)
    {
        bool firstRow = look.FirstRow && row == 0, lastRow = look.LastRow && row == rows - 1;
        bool firstColumn = look.FirstColumn && column == 0, lastColumn = look.LastColumn && column + span == columns;
        var list = new List<string>();
        if (look.BandColumns && !firstColumn && !lastColumn)
        {
            list.Add((column - (look.FirstColumn ? 1 : 0)) / columnBand % 2 == 0 ? "band1Vert" : "band2Vert");
        }
        if (look.BandRows && !firstRow && !lastRow)
        {
            list.Add((row - (look.FirstRow ? 1 : 0)) / rowBand % 2 == 0 ? "band1Horz" : "band2Horz");
        }
        if (lastColumn) list.Add("lastCol");
        if (firstColumn) list.Add("firstCol");
        if (lastRow) list.Add("lastRow");
        if (firstRow) list.Add("firstRow");
        return list;
    }

    private static List<XmlElement> Layers(IReadOnlyList<DocxStyle> chain, List<string> conditions)
    {
        var layers = chain.Select(s => s.Source).ToList();
        foreach (string condition in conditions)
        {
            foreach (var style in chain)
            {
                layers.AddRange(style.Source.Elements(W, "tblStylePr").Where(e => e.Attribute(W, "type") == condition));
            }
        }
        return layers;
    }

    /// <summary>What a cell takes from the table style layers, the table's own properties and its own, in that order.</summary>
    private sealed class CellFormat
    {
        public Edges Table { get; } = new();
        public Edges Own { get; } = new();
        public Margins Margin { get; } = new();
        public int? Fill { get; private set; }
        public LayoutVAlign VAlign { get; private set; }

        public CellFormat(DocxReader reader, List<XmlElement> layers, XmlElement? tblPr, XmlElement? tcPr)
        {
            foreach (var layer in layers)
            {
                Table.Apply(layer.Child(W, "tblPr")?.Child(W, "tblBorders"), reader._theme);
                Margin.Apply(layer.Child(W, "tblPr")?.Child(W, "tblCellMar"));
                Cell(layer.Child(W, "tcPr"), reader._theme);
            }
            Table.Apply(tblPr?.Child(W, "tblBorders"), reader._theme);
            Margin.Apply(tblPr?.Child(W, "tblCellMar"));
            Shade(tblPr?.Child(W, "shd"), reader._theme);
            Cell(tcPr, reader._theme);
        }

        private void Cell(XmlElement? tcPr, DocxTheme theme)
        {
            if (tcPr is null) return;
            Own.Apply(tcPr.Child(W, "tcBorders"), theme);
            Margin.Apply(tcPr.Child(W, "tcMar"));
            Shade(tcPr.Child(W, "shd"), theme);
            VAlign = tcPr.Child(W, "vAlign")?.Attribute(W, "val") switch
            {
                "center" => LayoutVAlign.Center,
                "bottom" => LayoutVAlign.Bottom,
                "top" => LayoutVAlign.Top,
                _ => VAlign,
            };
        }

        // A solid pattern paints with its color; any other pattern is taken as its fill alone.
        private void Shade(XmlElement? shd, DocxTheme theme)
        {
            if (shd?.Attribute(W, "val") is not { } val) return;
            if (val == "nil") Fill = null;
            else if (val == "solid") Fill = Hex(shd.Attribute(W, "color")) ?? Fill;
            else if (Hex(shd.Attribute(W, "fill")) is { } rgb) Fill = rgb;
            else if (shd.Attribute(W, "themeFill") is { } name && theme.Color(name) is { } themed) Fill = themed;
            else if (shd.Attribute(W, "fill") == "auto") Fill = null;
        }
    }

    private List<LayoutParagraph> CellContent(XmlElement tc, string key, IReadOnlyList<XmlElement> layers)
    {
        var blocks = _blocks;
        _blocks = [];
        (_inCell, _tableKey, _tableLayers) = (true, key, layers);
        Blocks(tc);
        var paragraphs = _blocks.OfType<LayoutParagraph>().ToList();
        (_inCell, _tableKey, _tableLayers) = (false, "", []);
        _blocks = blocks;
        return paragraphs;
    }

    // ---- borders ----

    private static Candidate Pick(Edges table, Edges own, int side, bool outer)
    {
        var explicitEdge = side switch { 0 => own.Top, 1 => own.Right, 2 => own.Bottom, _ => own.Left };
        if (explicitEdge.Set) return new Candidate(true, explicitEdge.Border);
        var edge = side switch
        {
            0 => outer ? table.Top : table.InsideH,
            1 => outer ? table.Right : table.InsideV,
            2 => outer ? table.Bottom : table.InsideH,
            _ => outer ? table.Left : table.InsideV,
        };
        return new Candidate(false, edge.Border);
    }

    // Two cells share an edge; the one named in the cell's own borders wins over the table's, then the wider, then the darker.
    // The cell above or to the left is passed first so that both cells agree on a tie.
    private static LayoutBorder? Resolve(Candidate first, Candidate second)
    {
        if (first.Explicit != second.Explicit) return first.Explicit ? first.Border : second.Border;
        var a = first.Border;
        var b = second.Border;
        if (a is null) return b;
        if (b is null) return a;
        if (a.Width != b.Width) return a.Width > b.Width ? a : b;
        return Brightness(b.Color) < Brightness(a.Color) ? b : a;
    }

    private static int Brightness(int rgb) => (rgb >> 16 & 0xFF) + (rgb & 0xFF) + 2 * (rgb >> 8 & 0xFF);

    // The neighbor across an edge is the cell at the edge's first row or column, so a cell facing two smaller ones
    // compares itself with the first.
    private static void ResolveBorders(List<CellInfo> infos, int rows, int columns)
    {
        var grid = new CellInfo?[rows, columns];
        foreach (var info in infos)
        {
            for (int r = info.Row; r < Math.Min(rows, info.Row + info.Cell.RowSpan); r++)
            {
                for (int c = info.Cell.Column; c < info.Cell.Column + info.Cell.Span; c++) grid[r, c] = info;
            }
        }
        foreach (var info in infos)
        {
            var cell = info.Cell;
            int end = info.Row + cell.RowSpan, right = cell.Column + cell.Span;
            var below = info.Continued is { } c1 ? (c1.Table, c1.Own) : (info.Table, info.Own);
            info.Top = Pick(info.Table, info.Own, 0, info.Row == 0);
            info.Right = Pick(info.Table, info.Own, 1, right == columns);
            info.Bottom = Pick(below.Item1, below.Item2, 2, end == rows);
            info.Left = Pick(info.Table, info.Own, 3, cell.Column == 0);
        }
        foreach (var info in infos)
        {
            var cell = info.Cell;
            int end = info.Row + cell.RowSpan, right = cell.Column + cell.Span;
            cell.Top = info.Row > 0 && grid[info.Row - 1, cell.Column] is { } up ? Resolve(up.Bottom, info.Top) : info.Top.Border;
            cell.Bottom = end < rows && grid[end, cell.Column] is { } down ? Resolve(info.Bottom, down.Top) : info.Bottom.Border;
            cell.Left = cell.Column > 0 && grid[info.Row, cell.Column - 1] is { } before ? Resolve(before.Right, info.Left) : info.Left.Border;
            cell.Right = right < columns && grid[info.Row, right] is { } after ? Resolve(info.Right, after.Left) : info.Right.Border;
        }
    }
}
