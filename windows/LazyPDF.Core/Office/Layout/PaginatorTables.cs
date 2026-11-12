namespace LazyPDF.Core.Office;

// Tables on pages. Rows go on one group at a time (a group is rows joined by a vertical merge). A group that does not fit
// moves to a fresh page; a single row whose lines do not fit is cut between lines. Header rows come back at the top of
// every page the table continues on.
internal sealed partial class Paginator
{
    private sealed class RowProgress(int cells)
    {
        /// <summary>Lines of each cell already placed.</summary>
        public int[] Taken { get; } = new int[cells];
        /// <summary>Height of the pieces already placed.</summary>
        public double Used { get; set; }
    }

    private void PlaceTable(TableLines table, LayoutSection section)
    {
        // Only a page with something on it gains by starting a fresh one.
        bool movable = _pages[^1].HasContent;
        double body = _pages[^1].Bottom - _pages[^1].Top;
        RowProgress? progress = null;
        int i = 0;
        while (i < table.Rows.Count)
        {
            _cancellation.ThrowIfCancellationRequested();
            var page = _pages[^1];
            double room = page.Bottom - page.Y + Tolerance;
            int next = table.Next[i];
            var row = table.Rows[i];
            if (progress is null)
            {
                double height = table.Height(i, next);
                bool whole = height <= room;
                if (!whole)
                {
                    bool cut = next == i + 1 && row.HasLines && row.Need > room && (!row.Source.CantSplit || !movable || height > body);
                    if (cut) progress = new RowProgress(row.Cells.Count);
                    else if (movable)
                    {
                        AdvanceTable(table, section, i);
                        movable = false;
                        continue;
                    }
                    else whole = true;
                }
                if (whole)
                {
                    PlaceRows(page, table, i, next, section.Page.Left);
                    page.Y += height;
                    page.HasContent = true;
                    movable = true;
                    i = next;
                    continue;
                }
            }

            var take = new int[row.Cells.Count];
            bool any = false;
            for (int c = 0; c < take.Length; c++)
            {
                var cell = row.Cells[c];
                int taken = progress!.Taken[c];
                double used = taken == 0 ? cell.Source.MarginTop : 0;
                int k = 0;
                while (taken + k < cell.Slots.Count && used + cell.Slots[taken + k].Height <= room) used += cell.Slots[taken + k++].Height;
                if (taken + k == cell.Slots.Count && k > 0 && used + cell.Source.MarginBottom > room) k--;
                take[c] = k;
                any |= k > 0;
            }
            if (!any)
            {
                if (movable)
                {
                    AdvanceTable(table, section, i);
                    movable = false;
                    continue;
                }
                // Nothing fits even here, so each cell gives one line to keep the table moving.
                for (int c = 0; c < take.Length; c++) take[c] = progress!.Taken[c] < row.Cells[c].Slots.Count ? 1 : 0;
            }

            bool done = true;
            double piece = 0;
            for (int c = 0; c < take.Length; c++)
            {
                var cell = row.Cells[c];
                int taken = progress!.Taken[c];
                bool finished = taken + take[c] == cell.Slots.Count;
                done &= finished;
                double used = (taken == 0 ? cell.Source.MarginTop : 0) + (finished ? cell.Source.MarginBottom : 0);
                for (int k = 0; k < take[c]; k++) used += cell.Slots[taken + k].Height;
                piece = Math.Max(piece, used);
            }
            if (done) piece = Math.Max(piece, Math.Min(row.Height - progress!.Used, room - Tolerance));
            EmitRowPiece(page, row, section.Page.Left, page.Y, piece, progress!.Taken, take, progress.Used == 0, done);
            page.Y += piece;
            page.HasContent = true;
            progress.Used += piece;
            for (int c = 0; c < take.Length; c++) progress.Taken[c] += take[c];
            if (done)
            {
                progress = null;
                movable = true;
                i = next;
            }
            else
            {
                AdvanceTable(table, section, i);
                movable = false;
            }
        }
    }

    private void AdvanceTable(TableLines table, LayoutSection section, int row)
    {
        NewPage(section, hard: false);
        if (table.Header == 0 || row < table.Header) return;
        var page = _pages[^1];
        PlaceRows(page, table, 0, table.Header, section.Page.Left);
        page.Y += table.Height(0, table.Header);
        page.HasContent = true;
    }

    private static void PlaceRows(Page page, TableLines table, int from, int to, double originX)
    {
        var parts = new CellBoxes();
        double y = page.Y;
        for (int r = from; r < to; r++)
        {
            foreach (var cell in table.Rows[r].Cells)
            {
                double height = table.Height(r, Math.Min(to, r + cell.RowSpan));
                EmitCell(parts, cell, originX, y, height, 0, cell.Slots.Count, true, true);
            }
            y += table.Rows[r].Height;
        }
        parts.AddTo(page.Boxes);
    }

    private static void EmitRowPiece(Page page, RowLines row, double originX, double y, double height, int[] from, int[] count, bool first, bool last)
    {
        var parts = new CellBoxes();
        for (int c = 0; c < row.Cells.Count; c++) EmitCell(parts, row.Cells[c], originX, y, height, from[c], from[c] + count[c], first, last);
        parts.AddTo(page.Boxes);
    }

    private sealed class CellBoxes
    {
        public List<LayoutBox> Fills { get; } = [];
        public List<LayoutBox> Texts { get; } = [];
        public List<LayoutBox> Edges { get; } = [];
        public HashSet<PlacedRect> Seen { get; } = [];

        public void Edge(PlacedRect rect)
        {
            if (Seen.Add(rect)) Edges.Add(rect);
        }

        // Fills go under the text and borders over it; a shared edge is drawn once.
        public void AddTo(List<LayoutBox> boxes)
        {
            boxes.AddRange(Fills);
            boxes.AddRange(Texts);
            boxes.AddRange(Edges);
        }
    }

    // A piece of a cell: its fill, its lines from slot `from` up to `to`, then the borders of the sides it shows. The top
    // border belongs to the first piece of a row and the bottom one to the last.
    private static void EmitCell(CellBoxes boxes, CellLines cell, double originX, double y, double height, int from, int to, bool first, bool last)
    {
        var source = cell.Source;
        double x0 = originX + cell.X, x1 = x0 + cell.Width, y1 = y + height;
        if (source.Fill is { } fill) boxes.Fills.Add(new PlacedRect(x0, y, cell.Width, height, fill));

        double cursor = y + (from == 0 ? source.MarginTop : 0), content = 0;
        for (int k = from; k < to; k++) content += cell.Slots[k].Height;
        if (first && last && source.VAlign != LayoutVAlign.Top)
        {
            double free = height - source.MarginTop - source.MarginBottom - content;
            if (free > 0) cursor += source.VAlign == LayoutVAlign.Center ? free / 2 : free;
        }
        for (int k = from; k < to; k++)
        {
            EmitLine(boxes.Texts, cell.Slots[k].Line, x0 + source.MarginLeft, cursor + cell.Slots[k].Lead);
            cursor += cell.Slots[k].Height;
        }

        if (first && source.Top is { } top) boxes.Edge(new PlacedRect(x0 - top.Width / 2, y - top.Width / 2, cell.Width + top.Width, top.Width, top.Color));
        if (last && source.Bottom is { } bottom) boxes.Edge(new PlacedRect(x0 - bottom.Width / 2, y1 - bottom.Width / 2, cell.Width + bottom.Width, bottom.Width, bottom.Color));
        if (source.Left is { } left) boxes.Edge(new PlacedRect(x0 - left.Width / 2, y - left.Width / 2, left.Width, height + left.Width, left.Color));
        if (source.Right is { } right) boxes.Edge(new PlacedRect(x1 - right.Width / 2, y - right.Width / 2, right.Width, height + right.Width, right.Color));
    }
}
