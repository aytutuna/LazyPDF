namespace LazyPDF.Core.Office;

// Pictures and graphic frames: tables are drawn, charts, diagrams and embedded objects are counted.
internal sealed partial class PptxReader
{
    private const double DefaultCellSide = 7.2, DefaultCellEdge = 3.6;

    private PptxShape? Pic(XmlElement pic, Scope scope, Affine context)
    {
        var spPr = pic.Child(P, "spPr");
        var nvPr = pic.Child(P, "nvPicPr")?.Child(P, "nvPr");
        bool media = nvPr?.Elements().Any(e => e.Name is "audioFile" or "videoFile" or "wavAudioFile" or "quickTimeFile") == true;
        if (media) Skip(PptxSkipped.Media);
        XmlElement? layoutPr = null, masterPr = null;
        if (nvPr?.Child(P, "ph") is { } ph)
        {
            string? type = ph.Attribute("type");
            int index = (int)Math.Clamp(DocxReader.Number(ph.Attribute("idx")) ?? 0, 0, int.MaxValue);
            var layoutPh = scope.Layout is null ? null : Match(scope.Layout.Placeholders, type, index, true);
            var masterPh = Match(scope.Master.Placeholders, layoutPh?.Type ?? type, layoutPh?.Index ?? index, false);
            layoutPr = layoutPh?.Shape.Child(P, "spPr");
            masterPr = masterPh?.Shape.Child(P, "spPr");
        }
        if (ReadXfrm(spPr?.Child(DocxReader.A, "xfrm") ?? layoutPr?.Child(DocxReader.A, "xfrm") ?? masterPr?.Child(DocxReader.A, "xfrm")) is not { } x)
        {
            if (!media) Skip(PptxSkipped.Shape);
            return null;
        }

        var matrix = context.Multiply(Placement(x));
        var frame = Uncover(matrix, x.Width, x.Height);
        PlacedImage? image = null;
        var blipFill = pic.Child(P, "blipFill");
        if (blipFill is null) Skip(SkippedKinds.UnreadablePicture);
        else if (Picture(blipFill, scope.Relationships, frame.Width, frame.Height) is { } source)
        {
            image = new PlacedImage(frame.X, frame.Y, frame.Width, frame.Height, source, frame.Turned ? frame.Rotation : 0, frame.FlipH);
        }

        var paths = new List<PlacedPath>();
        if (LineOf(spPr, layoutPr, masterPr, pic.Child(P, "style"), scope) is { } line)
        {
            paths.Add(new PlacedPath(PptxGeometry.Build("rect", x.Width, x.Height, new Dictionary<string, double>()).Select(c => Place(matrix, c)).ToList(), null, Stroke(line)));
        }
        if (image is null && paths.Count == 0) return null;
        return new PptxShape { X = frame.X, Y = frame.Y, Width = frame.Width, Height = frame.Height, Picture = image, Paths = paths };
    }

    private PptxShape? GraphicFrame(XmlElement frame, Scope scope, Affine context)
    {
        var data = frame.Child(DocxReader.A, "graphic")?.Child(DocxReader.A, "graphicData");
        string uri = data?.Attribute("uri") ?? "";
        if (uri.EndsWith("/table", StringComparison.Ordinal) && data?.Child(DocxReader.A, "tbl") is { } table) return Table(frame, table, scope, context);
        if (uri.Contains("chart", StringComparison.Ordinal)) Skip(PptxSkipped.Chart);
        else if (uri.EndsWith("/diagram", StringComparison.Ordinal)) Skip(PptxSkipped.SmartArt);
        else if (uri.EndsWith("/ole", StringComparison.Ordinal) || Children(data).Any(e => e.Uri == P && e.Name == "oleObj")) Skip(PptxSkipped.EmbeddedObject);
        else Skip(PptxSkipped.Shape);
        return null;
    }

    private PptxShape? Table(XmlElement frame, XmlElement table, Scope scope, Affine context)
    {
        var grid = table.Child(DocxReader.A, "tblGrid")?.Elements(DocxReader.A, "gridCol").ToList() ?? [];
        var rows = table.Elements(DocxReader.A, "tr").ToList();
        if (ReadXfrm(frame.Child(P, "xfrm")) is not { } x || grid.Count == 0 || rows.Count == 0
            || grid.Count > _limits.MaxTableColumns || rows.Count > _limits.MaxTableRows)
        {
            Skip(PptxSkipped.Shape);
            return null;
        }
        if (table.Child(DocxReader.A, "tblPr")?.Child(DocxReader.A, "tableStyleId") is not null) Skip(PptxSkipped.TableStyle);

        // A table keeps its sizes through a group's scale, but not a group's turn.
        double scaleX = Affine.Length(context.A, context.B), scaleY = Affine.Length(context.C, context.D);
        double Size(double? emu, double scale) => Math.Clamp((emu ?? 0) / EmuPerPoint, 0, PptxLimits.MaxSide) * scale;
        var columns = grid.Select(g => Size(DocxReader.Number(g.Attribute("w")), scaleX)).ToList();

        var layout = new LayoutTable { Columns = columns };
        var covered = new LayoutCell?[rows.Count, columns.Count];
        for (int r = 0; r < rows.Count; r++)
        {
            _cancellation.ThrowIfCancellationRequested();
            var row = new LayoutRow { Height = Size(DocxReader.Number(rows[r].Attribute("h")), scaleY) };
            int column = 0;
            foreach (var tc in rows[r].Elements(DocxReader.A, "tc"))
            {
                int at = column++;
                if (at >= columns.Count) break;
                if (tc.Attribute("hMerge") is "1" or "true" || tc.Attribute("vMerge") is "1" or "true") continue;
                // A cell under an earlier span is ignored, as PowerPoint does; this also bounds the work to rows x columns.
                if (covered[r, at] is not null) continue;
                var cell = Cell(tc, at, Math.Min(Count(tc, "gridSpan"), columns.Count - at), Math.Min(Count(tc, "rowSpan"), rows.Count - r), scope);
                row.Cells.Add(cell);
                for (int i = r; i < r + cell.RowSpan; i++)
                {
                    for (int k = at; k < at + cell.Span; k++) covered[i, k] = cell;
                }
            }
            layout.Rows.Add(row);
        }
        Edges(layout, covered);
        // Cells, borders and margins were read from the first column; a right-to-left table puts that column on the right.
        if (PptxRunProps.Flag(table.Child(DocxReader.A, "tblPr")?.Attribute("rtl")) == true)
        {
            layout.Mirror();
        }

        var (left, top) = context.Apply(x.X, x.Y);
        return new PptxShape { X = left, Y = top, Width = columns.Sum(), Table = new PptxTable(left, top, layout) };
    }

    private static int Count(XmlElement tc, string name) => (int)Math.Clamp(DocxReader.Number(tc.Attribute(name)) ?? 1, 1, 1000);

    private LayoutCell Cell(XmlElement tc, int column, int span, int rowSpan, Scope scope)
    {
        var tcPr = tc.Child(DocxReader.A, "tcPr");
        var paragraphs = tc.Child(DocxReader.A, "txBody") is { } txBody
            ? Paragraphs(txBody, [_defaultStyle], scope.Colors, new PptxBodyProps(), null, out _)
            : [];
        var fill = FillOf(tcPr, scope.Colors);
        if (fill is { Gradient: true } && fill.Color is not null) Skip(PptxSkipped.Gradient);
        double Margin(string name, double fallback) => DocxReader.Number(tcPr?.Attribute(name)) is { } emu ? Math.Clamp(emu / EmuPerPoint, 0, PptxLimits.MaxSide) : fallback;
        return new LayoutCell
        {
            Column = column,
            Span = span,
            RowSpan = rowSpan,
            Paragraphs = paragraphs,
            Fill = fill?.Color,
            Left = Border(tcPr?.Child(DocxReader.A, "lnL"), scope.Colors),
            Right = Border(tcPr?.Child(DocxReader.A, "lnR"), scope.Colors),
            Top = Border(tcPr?.Child(DocxReader.A, "lnT"), scope.Colors),
            Bottom = Border(tcPr?.Child(DocxReader.A, "lnB"), scope.Colors),
            MarginLeft = Margin("marL", DefaultCellSide),
            MarginRight = Margin("marR", DefaultCellSide),
            MarginTop = Margin("marT", DefaultCellEdge),
            MarginBottom = Margin("marB", DefaultCellEdge),
            VAlign = tcPr?.Attribute("anchor") switch { "ctr" => LayoutVAlign.Center, "b" => LayoutVAlign.Bottom, _ => LayoutVAlign.Top },
        };
    }

    private static LayoutBorder? Border(XmlElement? ln, PptxColors colors)
    {
        if (ln is null) return null;
        var info = new LineInfo { Width = 1 };
        ApplyLine(info, ln, colors, null);
        return info.None || info.Color is null || info.Width is not > 0 ? null : new LayoutBorder(info.Width.Value, info.Color.Value);
    }

    // Two cells that meet at an edge may both state a border; the wider one is drawn, the first on a tie.
    private static void Edges(LayoutTable table, LayoutCell?[,] covered)
    {
        static LayoutBorder? Wider(LayoutBorder? a, LayoutBorder? b) => a is null ? b : b is null ? a : b.Width > a.Width ? b : a;
        for (int r = 0; r < table.Rows.Count; r++)
        {
            foreach (var cell in table.Rows[r].Cells)
            {
                int right = cell.Column + cell.Span, below = r + cell.RowSpan;
                if (right < covered.GetLength(1) && covered[r, right] is { } next && next != cell)
                {
                    cell.Right = next.Left = Wider(cell.Right, next.Left);
                }
                if (below < covered.GetLength(0) && covered[below, cell.Column] is { } under && under != cell)
                {
                    cell.Bottom = under.Top = Wider(cell.Bottom, under.Top);
                }
            }
        }
    }
}
