using System.Globalization;
using System.Text;

namespace LazyPDF.Core.Office;

/// <summary>
/// Sets the sheets of a workbook on pages as Excel prints them: the page setup picks the paper, margins, scale and breaks, a
/// grid of cells is cut into pages by the widths and heights of its columns and rows, and every page gets its cells, gridlines,
/// headings and header and footer. Page numbers run on through the workbook.
/// </summary>
internal sealed class XlsxLayout
{
    private const double Pad = 2;
    private const double VPad = 0.75;
    private const double IndentStep = 7.5;
    private const double Tolerance = 0.01;
    private const double MinArea = 36;
    private const int MaxBoxes = 4_000_000;
    // Past this many boxes dashed borders are drawn solid.
    private const int DashBudget = 500_000;
    private const long MergeBudget = 4_000_000;
    private const long Stride = XlsxLimits.MaxColumn + 1;
    private const double Wide = 1e7;

    private readonly record struct Band(int From, int To, bool Repeat);

    private sealed record Titles(int[] Ids, double[] Sizes, int Last, double Total);

    private sealed class Plan
    {
        public required XlsxSheet Sheet { get; init; }
        public Dictionary<int, XlsxRow> Rows { get; } = [];
        public double[] ColumnWidth { get; } = new double[XlsxLimits.MaxColumn + 2];
        public Dictionary<int, double> RowHeight { get; } = [];
        public Dictionary<long, XlsxRange> Anchors { get; } = [];
        public HashSet<long> Covered { get; } = [];

        public double HeightOf(int row) => RowHeight.TryGetValue(row, out double h) ? h : Sheet.DefaultRowHeight;
    }

    private sealed class Pending
    {
        public required XlsxSheet Sheet { get; init; }
        public required int Number { get; init; }
        public required int IndexInSheet { get; init; }
        public required double Width { get; init; }
        public required double Height { get; init; }
        public required double Scale { get; init; }
        public required List<LayoutBox> Boxes { get; init; }
    }

    private sealed record Item(XlsxCell Cell, int RowId, int Row, int Column, double X, double Y, double W, double H, XlsxRange? Merge);

    private readonly XlsxWorkbook _book;
    private readonly LayoutFonts _fonts;
    private readonly DateTime _now;
    private readonly string _file;
    private readonly CancellationToken _cancellation;
    private readonly List<Pending> _pages = [];
    private int _boxes;
    private int _number = 1;

    private XlsxLayout(XlsxWorkbook book, LayoutFonts fonts, DateTime now, string file, CancellationToken cancellation)
    {
        _book = book;
        _fonts = fonts;
        _now = now;
        _file = file;
        _cancellation = cancellation;
    }

    /// <exception cref="PdfReadException">Nothing to print, the paper leaves no room, or the workbook runs to too many pages or boxes.</exception>
    public static LayoutResult Run(XlsxWorkbook book, LayoutFonts fonts, DateTime now, string fileName, CancellationToken cancellation = default)
    {
        var layout = new XlsxLayout(book, fonts, now, fileName, cancellation);
        foreach (var sheet in book.Sheets) layout.Sheet(sheet);
        if (layout._pages.Count == 0) throw new PdfReadException(PdfReadProblem.Unsupported, "The workbook has nothing to print.");
        return layout.Finish();
    }

    // Paper

    private static (double Width, double Height) Paper(XlsxPageSetup s)
    {
        (double w, double h) = s.Paper switch
        {
            3 or 4 => (792.0, 1224.0),
            5 => (612.0, 1008.0),
            6 => (396.0, 612.0),
            7 => (522.0, 756.0),
            8 => (841.89, 1190.55),
            9 or 10 => (595.28, 841.89),
            11 => (419.53, 595.28),
            12 => (728.5, 1031.81),
            13 => (515.91, 728.5),
            14 => (612.0, 936.0),
            15 => (609.45, 779.53),
            66 => (1190.55, 1683.78),
            70 => (297.64, 419.53),
            _ => (612.0, 792.0),
        };
        return s.Landscape ? (h, w) : (w, h);
    }

    // Sheet plan

    private static int LowerBound<T>(List<T> list, Func<T, int> key, int value)
    {
        int lo = 0, hi = list.Count;
        while (lo < hi)
        {
            int mid = (lo + hi) / 2;
            if (key(list[mid]) < value) lo = mid + 1;
            else hi = mid;
        }
        return lo;
    }

    private static XlsxCell? CellAt(Plan plan, int row, int column)
    {
        if (!plan.Rows.TryGetValue(row, out var r)) return null;
        int at = LowerBound(r.Cells, c => c.Column, column);
        return at < r.Cells.Count && r.Cells[at].Column == column ? r.Cells[at] : null;
    }

    private XlsxFont FontOf(XlsxCell cell)
    {
        var styles = _book.Styles;
        return cell.RichFont ?? styles.Fonts[Math.Min(styles.Xf(cell.Style).Font, styles.Fonts.Count - 1)];
    }

    private Plan MakePlan(XlsxSheet sheet)
    {
        var plan = new Plan { Sheet = sheet };
        foreach (var row in sheet.Rows) plan.Rows[row.Index] = row;

        // The first run that names a column wins; "next" skips the columns that already have a width.
        var next = new int[XlsxLimits.MaxColumn + 3];
        for (int c = 0; c < next.Length; c++) next[c] = c;
        int Find(int c)
        {
            while (next[c] != c)
            {
                next[c] = next[next[c]];
                c = next[c];
            }
            return c;
        }
        foreach (var run in sheet.Columns)
        {
            for (int c = Find(run.First); c <= run.Last; c = Find(c))
            {
                plan.ColumnWidth[c] = run.Hidden ? 0 : run.Width;
                next[c] = c + 1;
            }
        }
        for (int c = 1; c <= XlsxLimits.MaxColumn; c++)
        {
            if (Find(c) == c) plan.ColumnWidth[c] = sheet.DefaultColumnWidth;
        }

        long budget = MergeBudget;
        foreach (var m in sheet.Merges)
        {
            long anchor = m.FirstRow * Stride + m.FirstColumn;
            plan.Anchors.TryAdd(anchor, m);
            for (int i = LowerBound(sheet.Rows, r => r.Index, m.FirstRow); i < sheet.Rows.Count && sheet.Rows[i].Index <= m.LastRow && budget > 0; i++)
            {
                var cells = sheet.Rows[i].Cells;
                budget--;
                for (int k = LowerBound(cells, c => c.Column, m.FirstColumn); k < cells.Count && cells[k].Column <= m.LastColumn && budget > 0; k++)
                {
                    budget--;
                    long key = sheet.Rows[i].Index * Stride + cells[k].Column;
                    if (key != anchor) plan.Covered.Add(key);
                }
            }
        }

        foreach (var row in sheet.Rows)
        {
            _cancellation.ThrowIfCancellationRequested();
            plan.RowHeight[row.Index] = row.Hidden ? 0 : row.Height ?? AutoHeight(plan, row);
        }
        return plan;
    }

    private double Pitch(XlsxFont font)
    {
        var style = (font.Bold ? FontStyles.Bold : 0) | (font.Italic ? FontStyles.Italic : 0);
        var face = _fonts.Find(font.Name, style) ?? _fonts.Find(OfficeFontSource.DefaultFamily, style) ?? throw new InvalidOperationException(ExportText.NoFont);
        return (face.Ascent + face.Descent) * font.Size + 1.5;
    }

    // A row with no stated height grows with the tallest font in it and with the lines a wrapped text takes.
    private double AutoHeight(Plan plan, XlsxRow row)
    {
        double height = plan.Sheet.DefaultRowHeight;
        foreach (var cell in row.Cells)
        {
            if (cell.Kind == XlsxCellKind.Blank) continue;
            var font = FontOf(cell);
            double pitch = Pitch(font);
            long key = row.Index * Stride + cell.Column;
            var xf = _book.Styles.Xf(cell.Style);
            if (xf.Wrap && cell.Kind == XlsxCellKind.Text && !plan.Covered.Contains(key) && !plan.Anchors.ContainsKey(key))
            {
                double inner = plan.ColumnWidth[cell.Column] - 2 * Pad;
                if (inner > 1 && cell.Text.Length > 0) pitch = Lines(cell.Text, font, Align(cell, xf), inner).Sum(l => l.Height) + 1.5;
            }
            height = Math.Max(height, pitch);
        }
        return Math.Min(height, 409.5);
    }

    private static LayoutAlign Align(XlsxCell cell, XlsxXf xf) => Horizontal(cell, xf) switch
    {
        XlsxHorizontal.Right => LayoutAlign.Right,
        XlsxHorizontal.Center or XlsxHorizontal.CenterContinuous or XlsxHorizontal.Distributed => LayoutAlign.Center,
        XlsxHorizontal.Justify => LayoutAlign.Justify,
        _ => LayoutAlign.Left,
    };

    private static XlsxHorizontal Horizontal(XlsxCell cell, XlsxXf xf)
    {
        if (xf.Horizontal != XlsxHorizontal.General) return xf.Horizontal;
        return cell.Kind switch { XlsxCellKind.Number => XlsxHorizontal.Right, XlsxCellKind.Bool or XlsxCellKind.Error => XlsxHorizontal.Center, _ => XlsxHorizontal.Left };
    }

    private static LayoutRun RunOf(XlsxFont font, string text, int color) => new()
    {
        Text = text,
        Family = font.Name,
        Size = font.Size,
        Bold = font.Bold,
        Italic = font.Italic,
        Underline = font.Underline,
        Strike = font.Strike,
        Color = color,
    };

    private List<LayoutLine> Lines(string text, XlsxFont font, LayoutAlign align, double width, int color = 0) =>
        ParagraphLayout.Run(new LayoutParagraph { Runs = [RunOf(font, text, color)], Align = align }, _fonts, width, Wide).Lines;

    // Used range and areas

    private static XlsxRange? Used(Plan plan)
    {
        int rows = 0, columns = 0;
        foreach (var row in plan.Sheet.Rows)
        {
            if (row.Cells.Count == 0) continue;
            rows = row.Index;
            columns = Math.Max(columns, row.Cells[^1].Column);
        }
        foreach (var m in plan.Anchors.Values)
        {
            if (CellAt(plan, m.FirstRow, m.FirstColumn) is null) continue;
            rows = Math.Max(rows, m.LastRow);
            columns = Math.Max(columns, m.LastColumn);
        }
        return rows == 0 ? null : new XlsxRange(1, 1, rows, columns);
    }

    private void Sheet(XlsxSheet sheet)
    {
        var setup = sheet.Setup;
        var (paperWidth, paperHeight) = Paper(setup);
        if (paperWidth - setup.Left - setup.Right < MinArea || paperHeight - setup.Top - setup.Bottom < MinArea)
        {
            throw new PdfReadException(PdfReadProblem.Unsupported, "The page size or margins leave no room for text.");
        }
        var plan = MakePlan(sheet);
        bool stated = sheet.PrintArea.Count > 0;
        var areas = new List<XlsxRange>();
        if (stated) areas.AddRange(sheet.PrintArea);
        else if (Used(plan) is { } used) areas.Add(used);
        if (areas.Count == 0) return;

        if (setup.FirstPageNumber is { } first) _number = first;
        int index = 0;
        foreach (var area in areas) Area(plan, area, stated, paperWidth, paperHeight, ref index);
    }

    private static (int[] Ids, double[] Sizes) Strip(int first, int last, Func<int, double> size)
    {
        var ids = new List<int>();
        var sizes = new List<double>();
        for (int i = first; i <= last; i++)
        {
            double s = size(i);
            if (s <= 0) continue;
            ids.Add(i);
            sizes.Add(s);
        }
        return (ids.ToArray(), sizes.ToArray());
    }

    private static Titles? TitlesOf(int? first, int? last, Func<int, double> size)
    {
        if (first is null || last is null) return null;
        var ids = new List<int>();
        var sizes = new List<double>();
        double total = 0;
        for (int i = first.Value; i <= last.Value; i++)
        {
            double s = size(i);
            if (s <= 0) continue;
            ids.Add(i);
            sizes.Add(s);
            total += s;
        }
        return ids.Count == 0 ? null : new Titles(ids.ToArray(), sizes.ToArray(), last.Value, total);
    }

    private static bool BreakBetween(List<int> breaks, int after, int before)
    {
        int at = LowerBound(breaks, b => b, after);
        return at < breaks.Count && breaks[at] < before;
    }

    // Cuts a run of rows or columns into pages of at most "capacity". A page holds at least one item; the titles are repeated on
    // the pages that start after them.
    private static List<Band> Split(int[] ids, double[] sizes, double capacity, List<int> breaks, Titles? titles)
    {
        var bands = new List<Band>();
        int i = 0;
        while (i < ids.Length)
        {
            bool repeat = titles is not null && ids[i] > titles.Last;
            double used = repeat ? titles!.Total : 0;
            int j = i;
            do
            {
                used += sizes[j];
                j++;
            }
            while (j < ids.Length && !BreakBetween(breaks, ids[j - 1], ids[j]) && used + sizes[j] <= capacity + Tolerance);
            bands.Add(new Band(i, j - 1, repeat));
            i = j;
        }
        return bands;
    }

    private static int DigitCount(int n) => n.ToString(CultureInfo.InvariantCulture).Length;

    private void Area(Plan plan, XlsxRange area, bool stated, double paperWidth, double paperHeight, ref int index)
    {
        var sheet = plan.Sheet;
        var setup = sheet.Setup;
        var (rowIds, rowSizes) = Strip(area.FirstRow, area.LastRow, plan.HeightOf);
        var (columnIds, columnSizes) = Strip(area.FirstColumn, area.LastColumn, c => plan.ColumnWidth[c]);
        if (rowIds.Length == 0 || columnIds.Length == 0) return;
        var rowTitles = TitlesOf(sheet.TitleRows?.First, sheet.TitleRows?.Last, plan.HeightOf);
        var columnTitles = TitlesOf(sheet.TitleColumns?.First, sheet.TitleColumns?.Last, c => plan.ColumnWidth[c]);

        double headingHeight = setup.Headings ? sheet.DefaultRowHeight : 0;
        double headingWidth = setup.Headings ? Math.Max(2, DigitCount(rowIds[^1])) * _book.Styles.MaxDigitWidth * 0.75 + 6 : 0;
        double availableWidth = paperWidth - setup.Left - setup.Right, availableHeight = paperHeight - setup.Top - setup.Bottom;

        var rowBreaks = setup.FitToPage ? new List<int>() : setup.RowBreaks;
        var columnBreaks = setup.FitToPage ? new List<int>() : setup.ColumnBreaks;
        List<Band> RowBands(int scale) => Split(rowIds, rowSizes, availableHeight * 100 / scale - headingHeight, rowBreaks, rowTitles);
        List<Band> ColumnBands(int scale) => Split(columnIds, columnSizes, availableWidth * 100 / scale - headingWidth, columnBreaks, columnTitles);

        int scale = setup.Scale;
        if (setup.FitToPage)
        {
            int wide = setup.FitToWidth, high = setup.FitToHeight;
            double estimate = 100;
            if (wide > 0) estimate = Math.Min(estimate, availableWidth * wide * 100 / (columnSizes.Sum() + headingWidth));
            if (high > 0) estimate = Math.Min(estimate, availableHeight * high * 100 / (rowSizes.Sum() + headingHeight));
            scale = Math.Clamp((int)Math.Floor(estimate), 10, 100);
            while (scale > 10 && ((wide > 0 && ColumnBands(scale).Count > wide) || (high > 0 && RowBands(scale).Count > high))) scale--;
        }
        var rowBands = RowBands(scale);
        var columnBands = ColumnBands(scale);

        var pairs = new List<(int Row, int Column)>();
        if (stated)
        {
            for (int c = 0; c < columnBands.Count; c++)
            {
                for (int r = 0; r < rowBands.Count; r++)
                {
                    if (pairs.Count + _pages.Count >= Paginator.MaxPages) throw TooManyPages();
                    pairs.Add((r, c));
                }
            }
        }
        else
        {
            var marked = new HashSet<long>();
            foreach (var row in sheet.Rows)
            {
                if (row.Index < rowIds[0] || row.Index > rowIds[^1]) continue;
                int r = BandOf(rowBands, rowIds, row.Index);
                foreach (var cell in row.Cells)
                {
                    if (cell.Column < columnIds[0] || cell.Column > columnIds[^1]) continue;
                    marked.Add(r * (long)columnBands.Count + BandOf(columnBands, columnIds, cell.Column));
                }
            }
            foreach (long key in marked) pairs.Add(((int)(key / columnBands.Count), (int)(key % columnBands.Count)));
        }
        if (setup.OverThenDown) pairs.Sort((a, b) => a.Row != b.Row ? a.Row.CompareTo(b.Row) : a.Column.CompareTo(b.Column));
        else pairs.Sort((a, b) => a.Column != b.Column ? a.Column.CompareTo(b.Column) : a.Row.CompareTo(b.Row));

        var geometry = new PageGeometry(paperWidth, paperHeight, scale / 100.0, headingWidth, headingHeight);
        foreach (var (r, c) in pairs)
        {
            _cancellation.ThrowIfCancellationRequested();
            if (_pages.Count >= Paginator.MaxPages) throw TooManyPages();
            var boxes = new List<LayoutBox>();
            if (Build(plan, geometry, stated, !stated && columnBands[c].To == columnIds.Length - 1 ? availableWidth * 100 / scale : 0, rowIds, rowSizes, columnIds, columnSizes, rowBands[r], columnBands[c], rowTitles, columnTitles, boxes) is not { } size) continue;
            var (width, height) = size;
            _boxes += boxes.Count;
            if (_boxes > MaxBoxes) throw new PdfReadException(PdfReadProblem.Unsupported, "The workbook is too large to convert.");
            _pages.Add(new Pending { Sheet = sheet, Number = _number++, IndexInSheet = index++, Width = paperWidth, Height = paperHeight, Scale = geometry.Scale, Boxes = Place(boxes, setup, geometry, width, height) });
        }
    }

    private static PdfReadException TooManyPages() => new(PdfReadProblem.Unsupported, "The document has too many pages.");

    private static int BandOf(List<Band> bands, int[] ids, int id)
    {
        int lo = 0, hi = bands.Count - 1;
        while (lo < hi)
        {
            int mid = (lo + hi + 1) / 2;
            if (ids[bands[mid].From] <= id) lo = mid;
            else hi = mid - 1;
        }
        return lo;
    }

    private sealed record PageGeometry(double PaperWidth, double PaperHeight, double Scale, double HeadingWidth, double HeadingHeight);

    // The boxes of a page are built in sheet points from the top left of the content; Place scales them and moves them to the margins.
    private static List<LayoutBox> Place(List<LayoutBox> boxes, XlsxPageSetup setup, PageGeometry g, double width, double height)
    {
        double k = g.Scale;
        double x = setup.Left, y = setup.Top;
        if (setup.CenterHorizontally) x += Math.Max(0, (g.PaperWidth - setup.Left - setup.Right - width * k) / 2);
        if (setup.CenterVertically) y += Math.Max(0, (g.PaperHeight - setup.Top - setup.Bottom - height * k) / 2);
        return Move(boxes, k, x, y);
    }

    private static List<LayoutBox> Move(List<LayoutBox> boxes, double k, double x, double y)
    {
        var moved = new List<LayoutBox>(boxes.Count);
        foreach (var box in boxes)
        {
            switch (box)
            {
                case PlacedText t:
                    moved.Add(t with { X = x + t.X * k, Baseline = y + t.Baseline * k, Size = t.Size * k, SpaceExtra = t.SpaceExtra * k });
                    break;
                case PlacedRect r:
                    moved.Add(r with { X = x + r.X * k, Y = y + r.Y * k, Width = r.Width * k, Height = r.Height * k });
                    break;
            }
        }
        return moved;
    }

    // One page

    private (double Width, double Height)? Build(
        Plan plan, PageGeometry g, bool stated, double spill, int[] rowIds, double[] rowSizes, int[] columnIds, double[] columnSizes,
        Band rowBand, Band columnBand, Titles? rowTitles, Titles? columnTitles, List<LayoutBox> boxes)
    {
        var setup = plan.Sheet.Setup;
        var rows = new List<int>();
        var heights = new List<double>();
        var columns = new List<int>();
        var widths = new List<double>();
        if (rowBand.Repeat) { rows.AddRange(rowTitles!.Ids); heights.AddRange(rowTitles.Sizes); }
        int bodyRow = rows.Count;
        for (int i = rowBand.From; i <= rowBand.To; i++) { rows.Add(rowIds[i]); heights.Add(rowSizes[i]); }
        if (columnBand.Repeat) { columns.AddRange(columnTitles!.Ids); widths.AddRange(columnTitles.Sizes); }
        int bodyColumn = columns.Count;
        for (int i = columnBand.From; i <= columnBand.To; i++) { columns.Add(columnIds[i]); widths.Add(columnSizes[i]); }

        var top = new double[rows.Count + 1];
        var left = new double[columns.Count + 1];
        top[0] = g.HeadingHeight;
        for (int i = 0; i < rows.Count; i++) top[i + 1] = top[i] + heights[i];
        left[0] = g.HeadingWidth;
        for (int i = 0; i < columns.Count; i++) left[i + 1] = left[i] + widths[i];
        double width = left[^1], height = top[^1];
        var columnAt = new Dictionary<int, int>();
        for (int i = 0; i < columns.Count; i++) columnAt[columns[i]] = i;

        if (setup.Gridlines)
        {
            for (int i = 0; i < top.Length; i++) boxes.Add(new PlacedRect(g.HeadingWidth, top[i] - 0.25, width - g.HeadingWidth, 0.5, 0x808080));
            for (int i = 0; i < left.Length; i++) boxes.Add(new PlacedRect(left[i] - 0.25, g.HeadingHeight, 0.5, height - g.HeadingHeight, 0x808080));
        }

        var items = new List<Item>();
        bool content = false;
        for (int i = 0; i < rows.Count; i++)
        {
            if (!plan.Rows.TryGetValue(rows[i], out var row)) continue;
            foreach (var cell in row.Cells)
            {
                if (!columnAt.TryGetValue(cell.Column, out int j)) continue;
                long key = row.Index * Stride + cell.Column;
                if (plan.Covered.Contains(key)) continue;
                int lastRow = i, lastColumn = j;
                XlsxRange? merge = null;
                if (plan.Anchors.TryGetValue(key, out var m))
                {
                    merge = m;
                    lastRow = Math.Max(i, LastAtMost(rows, m.LastRow));
                    lastColumn = Math.Max(j, LastAtMost(columns, m.LastColumn));
                }
                var item = new Item(cell, row.Index, i, j, left[j], top[i], left[lastColumn + 1] - left[j], top[lastRow + 1] - top[i], merge);
                items.Add(item);
                if (i >= bodyRow && j >= bodyColumn) content = true;
                var xf = _book.Styles.Xf(cell.Style);
                if (xf.Fill < _book.Styles.Fills.Count && _book.Styles.Fills[xf.Fill].Color is { } fill)
                {
                    boxes.Add(new PlacedRect(item.X, item.Y, item.W, item.H, fill));
                }
            }
        }
        if (!content && !stated) return null;

        foreach (var item in items) Text(plan, item, rows, columns, left, spill, boxes);
        foreach (var item in items) Borders(plan, item, rows, columns, boxes);
        if (setup.Headings) Headings(g, rows, columns, top, left, boxes);
        return (width, height);
    }

    private static int LastAtMost(List<int> ids, int limit)
    {
        int lo = 0, hi = ids.Count - 1, found = -1;
        while (lo <= hi)
        {
            int mid = (lo + hi) / 2;
            if (ids[mid] <= limit) { found = mid; lo = mid + 1; }
            else hi = mid - 1;
        }
        return found;
    }

    // Text

    private bool Empty(Plan plan, XlsxRow row, int column)
    {
        long key = row.Index * Stride + column;
        if (plan.Covered.Contains(key) || plan.Anchors.ContainsKey(key)) return false;
        return CellAt(plan, row.Index, column) is not { } cell || cell.Kind == XlsxCellKind.Blank;
    }

    // How far text may run from a cell: through the empty cells next to it on the page.
    private double Reach(Plan plan, XlsxRow row, List<int> columns, double[] left, int j, int step, double spill)
    {
        int at = j;
        while (true)
        {
            int next = at + step;
            if (next < 0 || next >= columns.Count) break;
            bool adjacent = true;
            for (int id = Math.Min(columns[at], columns[next]) + 1; id < Math.Max(columns[at], columns[next]); id++)
            {
                if (plan.ColumnWidth[id] > 0) adjacent = false;
            }
            if (!adjacent || !Empty(plan, row, columns[next])) break;
            at = next;
        }
        if (step < 0) return left[at];
        double x = left[at + 1];
        // On the last page of a sheet without a print area, text may run on past the columns that are printed, up to the margin.
        if (spill > 0 && at == columns.Count - 1)
        {
            for (int id = columns[at] + 1; id <= XlsxLimits.MaxColumn; id++)
            {
                double w = plan.ColumnWidth[id];
                if (w <= 0) continue;
                if (!Empty(plan, row, id)) break;
                if (x + w > spill) return Math.Max(x, spill);
                x += w;
            }
        }
        return x;
    }

    private void Text(Plan plan, Item item, List<int> rows, List<int> columns, double[] left, double spill, List<LayoutBox> boxes)
    {
        var cell = item.Cell;
        if (cell.Kind == XlsxCellKind.Blank || cell.Text.Length == 0) return;
        var xf = _book.Styles.Xf(cell.Style);
        var font = FontOf(cell);
        int color = cell.Color ?? font.Color ?? 0;
        var horizontal = Horizontal(cell, xf);
        double limitLeft = item.X + Pad, limitRight = item.X + item.W - Pad, span = item.W;
        bool wrap = xf.Wrap && cell.Kind == XlsxCellKind.Text;
        if (!wrap && cell.Kind == XlsxCellKind.Text && item.Merge is null && plan.Rows.TryGetValue(rows[item.Row], out var row))
        {
            // Text spills out of its cell on the side or sides its alignment leaves free.
            if (horizontal is XlsxHorizontal.Left or XlsxHorizontal.Fill or XlsxHorizontal.Justify) limitRight = Math.Max(limitRight, Reach(plan, row, columns, left, item.Column, 1, spill) - Pad);
            else if (horizontal == XlsxHorizontal.Right) limitLeft = Math.Min(limitLeft, Reach(plan, row, columns, left, item.Column, -1, spill) + Pad);
            else if (horizontal == XlsxHorizontal.CenterContinuous)
            {
                // Center Across Selection centers over the empty cells to its right, as one wide cell.
                span = Reach(plan, row, columns, left, item.Column, 1, spill) - item.X;
                limitRight = item.X + span - Pad;
            }
            else
            {
                double extra = Math.Min(Reach(plan, row, columns, left, item.Column, 1, spill) - (item.X + item.W), item.X - Reach(plan, row, columns, left, item.Column, -1, spill));
                limitLeft -= extra;
                limitRight += extra;
            }
        }
        double indent = xf.Indent * IndentStep;
        var align = Align(cell, xf);
        if (wrap) Wrapped(cell.Text, font, color, align, xf.Vertical, indent, item, boxes);
        else Single(cell.Text, font, color, horizontal, xf.Vertical, indent, cell.Kind == XlsxCellKind.Number, item.X, item.Y, span, item.H, limitLeft, limitRight, boxes);
    }

    private static double TopOf(XlsxVertical vertical, double y, double h, double text) => vertical switch
    {
        XlsxVertical.Top or XlsxVertical.Justify or XlsxVertical.Distributed => y + VPad,
        XlsxVertical.Center => y + (h - text) / 2,
        _ => y + h - VPad - text,
    };

    private void Wrapped(string text, XlsxFont font, int color, LayoutAlign align, XlsxVertical vertical, double indent, Item item, List<LayoutBox> boxes)
    {
        double shift = align == LayoutAlign.Left ? indent : 0;
        double inner = item.W - 2 * Pad - (align is LayoutAlign.Left or LayoutAlign.Right ? indent : 0);
        if (inner < 1) return;
        var paragraph = new LayoutParagraph { Runs = [RunOf(font, text.Replace("\r\n", "\n").Replace('\r', '\n'), color)], Align = align };
        var lines = ParagraphLayout.Run(paragraph, _fonts, inner, Wide).Lines;
        double total = lines.Sum(l => l.Height);
        double y = TopOf(vertical, item.Y, item.H, total);
        foreach (var line in lines)
        {
            if (y >= item.Y - 0.5 && y + line.Height <= item.Y + item.H + line.Height * 0.25) Paginator.EmitLine(boxes, line, item.X + Pad + shift, y);
            y += line.Height;
        }
    }

    private void Single(
        string text, XlsxFont font, int color, XlsxHorizontal horizontal, XlsxVertical vertical, double indent, bool number,
        double x, double y, double w, double h, double limitLeft, double limitRight, List<LayoutBox> boxes)
    {
        text = text.Replace("\r\n", " ").Replace('\r', ' ').Replace('\n', ' ');
        var line = Lines(text, font, LayoutAlign.Left, Wide, color)[0];
        double width = Ink(line);
        double room = w - 2 * Pad;
        if (number && width > room + Tolerance)
        {
            double hash = Ink(Lines("#", font, LayoutAlign.Left, Wide)[0]);
            line = Lines(new string('#', Math.Max(1, (int)Math.Floor(room / hash))), font, LayoutAlign.Left, Wide, color)[0];
            width = Ink(line);
        }
        double origin = horizontal switch
        {
            XlsxHorizontal.Right => x + w - Pad - indent - width,
            XlsxHorizontal.Center or XlsxHorizontal.CenterContinuous or XlsxHorizontal.Distributed => x + (w - width) / 2,
            _ => x + Pad + indent,
        };
        line.Atoms.RemoveAll(a => origin + a.X < limitLeft - Tolerance || origin + a.X + a.Width > limitRight + Tolerance);
        if (line.Atoms.All(a => a.IsBlank)) return;
        double top = TopOf(vertical, y, h, line.Height);
        if (top < y - 0.5 || top + line.Height > y + h + line.Height * 0.25) return;
        Paginator.EmitLine(boxes, line, origin, top);
    }

    private static double Ink(LayoutLine line)
    {
        int ink = line.Atoms.FindLastIndex(a => !a.IsBlank);
        return ink < 0 ? 0 : line.Atoms[ink].X + line.Atoms[ink].Width;
    }

    // Borders

    private static (double Width, bool Double, int Pattern) Look(string style) => style switch
    {
        "hair" => (0.5, false, 0),
        "thin" => (0.75, false, 0),
        "medium" => (1.5, false, 0),
        "thick" => (2.25, false, 0),
        "double" => (0.75, true, 0),
        "dotted" => (0.75, false, 2),
        "dashed" or "dashDot" or "dashDotDot" => (0.75, false, 1),
        "mediumDashed" or "mediumDashDot" or "mediumDashDotDot" or "slantDashDot" => (1.5, false, 1),
        _ => (0.75, false, 0),
    };

    private void Edge(List<LayoutBox> boxes, bool horizontal, double at, double from, double to, XlsxBorderEdge edge)
    {
        var (width, twin, pattern) = Look(edge.Style);
        int color = edge.Color ?? 0;
        void Line(double offset, double w)
        {
            double a = from - w / 2, b = to + w / 2;
            double on = pattern == 1 ? width * 3 : width, off = pattern == 1 ? width * 1.5 : width;
            if (pattern == 0 || boxes.Count + _boxes > DashBudget)
            {
                Segment(a, b - a);
                return;
            }
            for (double p = a; p < b - Tolerance; p += on + off) Segment(p, Math.Min(on, b - p));

            void Segment(double start, double length) =>
                boxes.Add(horizontal ? new PlacedRect(start, at + offset - w / 2, length, w, color) : new PlacedRect(at + offset - w / 2, start, w, length, color));
        }
        if (twin)
        {
            Line(-width, width);
            Line(width, width);
        }
        else
        {
            Line(0, width);
        }
    }

    private void Borders(Plan plan, Item item, List<int> rows, List<int> columns, List<LayoutBox> boxes)
    {
        var border = Border(item.Cell);
        if (border is null) return;
        double right = item.X + item.W, bottom = item.Y + item.H;
        int row = item.RowId, column = item.Cell.Column;
        var topEdge = border.Top;
        var leftEdge = border.Left;
        var rightEdge = border.Right;
        var bottomEdge = border.Bottom;
        if (item.Merge is { } m)
        {
            rightEdge = CellAt(plan, m.FirstRow, m.LastColumn) is { } r ? Border(r)?.Right : null;
            bottomEdge = CellAt(plan, m.LastRow, m.FirstColumn) is { } b ? Border(b)?.Bottom : null;
        }
        // A neighbour only hides the shared edge when it is printed right beside this cell on the same page.
        if (leftEdge is not null && item.Column > 0 && columns[item.Column - 1] == column - 1 && CellAt(plan, row, column - 1) is { } l && Border(l)?.Right is not null) leftEdge = null;
        if (topEdge is not null && item.Row > 0 && rows[item.Row - 1] == row - 1 && CellAt(plan, row - 1, column) is { } t && Border(t)?.Bottom is not null) topEdge = null;
        if (topEdge is not null) Edge(boxes, true, item.Y, item.X, right, topEdge);
        if (leftEdge is not null) Edge(boxes, false, item.X, item.Y, bottom, leftEdge);
        if (rightEdge is not null) Edge(boxes, false, right, item.Y, bottom, rightEdge);
        if (bottomEdge is not null) Edge(boxes, true, bottom, item.X, right, bottomEdge);
    }

    private XlsxBorder? Border(XlsxCell cell)
    {
        var styles = _book.Styles;
        int index = styles.Xf(cell.Style).Border;
        return index < styles.Borders.Count ? styles.Borders[index] : null;
    }

    // Headings

    private static string ColumnName(int column)
    {
        var letters = new StringBuilder();
        for (int c = column; c > 0; c = (c - 1) / 26) letters.Insert(0, (char)('A' + (c - 1) % 26));
        return letters.ToString();
    }

    private void Headings(PageGeometry g, List<int> rows, List<int> columns, double[] top, double[] left, List<LayoutBox> boxes)
    {
        var font = _book.Styles.Fonts[0];
        var edge = new XlsxBorderEdge("hair", 0x808080);
        void Box(string text, double x, double y, double w, double h)
        {
            Edge(boxes, true, y, x, x + w, edge);
            Edge(boxes, true, y + h, x, x + w, edge);
            Edge(boxes, false, x, y, y + h, edge);
            Edge(boxes, false, x + w, y, y + h, edge);
            Single(text, font, 0, XlsxHorizontal.Center, XlsxVertical.Center, 0, false, x, y, w, h, x, x + w, boxes);
        }
        for (int j = 0; j < columns.Count; j++) Box(ColumnName(columns[j]), left[j], 0, left[j + 1] - left[j], g.HeadingHeight);
        for (int i = 0; i < rows.Count; i++) Box(rows[i].ToString(CultureInfo.InvariantCulture), 0, top[i], g.HeadingWidth, top[i + 1] - top[i]);
    }

    // Header and footer

    private LayoutResult Finish()
    {
        var pages = new List<LayoutPage>();
        string date = $"{_now.Month}/{_now.Day}/{_now.Year}";
        int hour = _now.Hour % 12 == 0 ? 12 : _now.Hour % 12;
        string time = $"{hour}:{_now.Minute:00} {(_now.Hour < 12 ? "AM" : "PM")}";
        foreach (var page in _pages)
        {
            _cancellation.ThrowIfCancellationRequested();
            var setup = page.Sheet.Setup;
            var context = new HfContext(page.Number, _pages.Count, date, time, _file, page.Sheet.Name);
            bool first = setup.DifferentFirst && page.IndexInSheet == 0;
            bool even = setup.DifferentOddEven && page.Number % 2 == 0;
            string header = first ? setup.FirstHeader : even ? setup.EvenHeader : setup.OddHeader;
            string footer = first ? setup.FirstFooter : even ? setup.EvenFooter : setup.OddFooter;
            var boxes = page.Boxes;
            HeaderBand(boxes, header, context, setup, page, footer: false);
            HeaderBand(boxes, footer, context, setup, page, footer: true);
            pages.Add(new LayoutPage(page.Width, page.Height, boxes));
        }
        return new LayoutResult(pages, _book.Skipped, [.. _fonts.Missing]);
    }

    private void HeaderBand(List<LayoutBox> boxes, string source, HfContext context, XlsxPageSetup setup, Pending page, bool footer)
    {
        if (source.Length == 0) return;
        var sections = XlsxHeaderFooter.Parse(source, context);
        var font = _book.Styles.Fonts[0];
        double k = setup.ScaleWithDocument ? page.Scale : 1;
        double x = setup.AlignWithMargins ? setup.Left : 0;
        double width = (setup.AlignWithMargins ? page.Width - setup.Left - setup.Right : page.Width) / k;

        var local = new List<LayoutBox>();
        double block = 0;
        for (int s = 0; s < 3; s++)
        {
            double y = 0;
            foreach (var line in sections[s])
            {
                var runs = line.Select(r => RunOf(font with { Bold = font.Bold || r.Bold, Italic = font.Italic || r.Italic }, r.Text, 0)).ToList();
                if (runs.Count == 0) runs.Add(RunOf(font, "", 0));
                var laid = ParagraphLayout.Run(new LayoutParagraph { Runs = runs }, _fonts, Wide, Wide).Lines[0];
                double w = Ink(laid);
                Paginator.EmitLine(local, laid, s == 0 ? 0 : s == 1 ? (width - w) / 2 : width - w, y);
                y += laid.Height;
            }
            block = Math.Max(block, y);
        }
        double top = footer ? page.Height - setup.Footer - block * k : setup.Header;
        boxes.AddRange(Move(local, k, x, top));
    }
}
