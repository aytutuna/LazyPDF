namespace LazyPDF.Core;

/// <summary>
/// Reads pages into the <see cref="ExportDocument"/> the writers share: paragraphs from the text
/// layer's lines, headings by size, bold and italic runs, lists, tables (drawn grids and aligned
/// columns), pictures in place, running heads and page numbers left out of the flow.
/// </summary>
public static class ExportLayout
{
    private const double MinPictureSide = 4;

    /// <summary>
    /// Analyses <paramref name="pages"/> (0-based, in the order given; null for all). Pictures
    /// need the <paramref name="codec"/> only for JPEG 2000, JBIG2 and masks on a JPEG.
    /// </summary>
    /// <exception cref="ArgumentOutOfRangeException">A page index is out of range.</exception>
    public static ExportDocument Analyze(PdfDocument document, IReadOnlyList<int>? pages = null, IImageCodec? codec = null, CancellationToken cancel = default)
    {
        var interpreter = new ContentInterpreter(document) { WalkPatterns = false };
        var images = new ExportImages(document, codec);
        var work = new List<PageWork>();
        foreach (int index in pages ?? Enumerable.Range(0, document.Pages.Count).ToList())
        {
            cancel.ThrowIfCancellationRequested();
            if (index < 0 || index >= document.Pages.Count) throw new ArgumentOutOfRangeException(nameof(pages));
            work.Add(Collect(document, interpreter, images, index));
        }

        var dropped = ExportStructure.RunningHeads([.. work.Select(w => (w.Height, (IReadOnlyList<ExRow>)w.Blocks.Where(b => !b.IsTable).SelectMany(b => b.Rows).ToList()))]);
        foreach (var page in work) page.Assemble(dropped);

        var paragraphs = work.SelectMany(w => w.Flow).OfType<ExPara>().ToList();
        double body = ExportStructure.BodySize(paragraphs);
        ExportStructure.Headings(paragraphs, body);
        var lists = ExportStructure.Lists(work.SelectMany(w => w.Flow));

        var result = work.Select(w => new ExportPage(w.Index, w.Width, w.Height,
            [.. w.Flow.Select(b => b is ExPara p ? Paragraph(p, lists) : (ExportBlock)b)], w.Lines, w.Pictures)).ToList();
        return new ExportDocument(PdfText.Read(document, document.Info, "Title"), result, body);
    }

    private static ExportParagraph Paragraph(ExPara p, Dictionary<ExPara, ExportListItem> lists)
    {
        var runs = ExportFlow.Merge(p.Runs);
        if (runs.Count > 0) runs[^1] = runs[^1] with { Text = runs[^1].Text.TrimEnd() };
        return new ExportParagraph(p.Box, runs, p.Heading, lists.GetValueOrDefault(p));
    }

    private static PageWork Collect(PdfDocument document, ContentInterpreter interpreter, ExportImages images, int index)
    {
        var page = document.Pages[index];
        var geometry = new PageGeometry(page);
        var text = TextPage.Create(interpreter, page);
        var scan = new ExportScan(geometry, true);
        interpreter.Run(page, scan);

        var lines = text.Lines.Select(l => ExLine.From(text, l, geometry)).ToList();
        ExportFlow.JoinMarkers(lines);
        var all = lines.OfType<ExLine>().ToList();
        // A file that marks all its text as artifact is mistagged; its text is the page.
        if (all.Count(l => l.IsArtifact) * 10 > all.Count * 9) all.ForEach(l => l.IsArtifact = false);

        var ruled = ExportGrid.Find(scan.Rules, all);
        for (int t = 0; t < ruled.Count; t++) ruled[t].Lines.ForEach(l => l.Table = t);

        var work = new PageWork(index, geometry.Width, geometry.Height, [.. all.Select(l => new ExportTextLine(l.Box, l.Runs))]);
        var emitted = new bool[ruled.Count];
        foreach (var block in text.Blocks)
        {
            var group = new List<ExLine>();
            void Flush()
            {
                if (group.Count > 0) work.Items.Add(new WorkBlock(block.IsTable, ExportFlow.Rows(group)));
                group = [];
            }
            for (int i = block.Lines.Start; i < block.Lines.End && i < lines.Count; i++)
            {
                if (lines[i] is not { } line) continue;
                if (line.Table < 0)
                {
                    group.Add(line);
                    continue;
                }
                Flush();
                if (!emitted[line.Table]) work.Items.Add(ruled[line.Table].Table);
                emitted[line.Table] = true;
            }
            Flush();
        }

        bool scanned = text.Chars.Count > 0 && text.Chars.Count(c => c.RenderMode == 3) * 5 >= text.Chars.Count * 4;
        foreach (var info in scan.Images)
        {
            var box = geometry.ToDisplay(info.Bounds);
            if (box.Width < MinPictureSide || box.Height < MinPictureSide) continue;
            // The page picture under the invisible text of an OCR'd scan would only repeat it.
            if (scanned && box.Width >= 0.9 * geometry.Width && box.Height >= 0.9 * geometry.Height) continue;
            if (images.Get(info) is { } image) work.Pictures.Add(new ExportPicture(box, image));
        }
        return work;
    }

    private sealed record WorkBlock(bool IsTable, List<ExRow> Rows);

    private sealed class PageWork(int index, double width, double height, IReadOnlyList<ExportTextLine> lines)
    {
        public int Index { get; } = index;
        public double Width { get; } = width;
        public double Height { get; } = height;
        public IReadOnlyList<ExportTextLine> Lines { get; } = lines;

        /// <summary>Text blocks and ruled tables in reading order.</summary>
        public List<object> Items { get; } = [];
        public List<ExportPicture> Pictures { get; } = [];

        /// <summary>The page's blocks: <see cref="ExPara"/> until headings and lists are known, then export blocks.</summary>
        public List<object> Flow { get; } = [];

        public IEnumerable<WorkBlock> Blocks => Items.OfType<WorkBlock>();

        public void Assemble(HashSet<ExRow> dropped)
        {
            foreach (object item in Items)
            {
                if (item is ExportTable table)
                {
                    Flow.Add(table);
                    continue;
                }
                var block = (WorkBlock)item;
                var rows = block.Rows.Where(r => !dropped.Contains(r) && !r.Cells.All(c => c.IsArtifact)).ToList();
                if (block.IsTable && ExportFlow.Aligned(rows) is { } aligned) Flow.Add(aligned);
                else Flow.AddRange(ExportFlow.Paragraphs(rows));
            }
            foreach (var picture in Pictures) Place(picture);
        }

        // Before the first block that lies lower than the picture's middle and shares some of its width.
        private void Place(ExportPicture picture)
        {
            double middle = picture.Bounds.Y + picture.Bounds.Height / 2;
            int at = Flow.FindIndex(b =>
            {
                var box = Box(b);
                return box.Y + box.Height / 2 > middle && box.X < picture.Bounds.X + picture.Bounds.Width && box.X + box.Width > picture.Bounds.X;
            });
            Flow.Insert(at < 0 ? Flow.Count : at, picture);
        }

        private static DisplayRect Box(object block) => block is ExPara p ? p.Box : ((ExportBlock)block).Bounds;
    }
}
