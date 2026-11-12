namespace LazyPDF.Core;

public enum ImposeMode
{
    /// <summary>Several pages on each sheet, in reading order: across, then down.</summary>
    NUp,

    /// <summary>Saddle-stitch: two pages on each side of a landscape sheet, in the order that folds into a booklet.</summary>
    Booklet,
}

/// <param name="SheetWidth">Paper size in points, as the sheet is held. A booklet always uses the landscape orientation of it.</param>
/// <param name="PerSheet">2, 4, 6, 9 or 16 for <see cref="ImposeMode.NUp"/>; ignored for a booklet.</param>
/// <param name="Gap">Space in points between pages and from the pages to the sheet edge.</param>
public sealed record ImposeOptions(ImposeMode Mode, double SheetWidth, double SheetHeight, int PerSheet = 2, double Gap = 0, bool Border = false);

/// <param name="Document">The sheets, a new document that is not saved yet.</param>
/// <param name="AnnotationsFlattened">Annotations whose appearance was drawn into the page they sat on.</param>
/// <param name="AnnotationsDropped">Annotations left out: links, and those with no appearance, hidden or not shown.</param>
public sealed record ImposeResult(PdfDocument Document, int Sheets, int AnnotationsFlattened, int AnnotationsDropped);

public static partial class PageOperations
{
    private static readonly Dictionary<int, (int Columns, int Rows)> Grids = new()
    {
        [2] = (2, 1), [4] = (2, 2), [6] = (3, 2), [9] = (3, 3), [16] = (4, 4),
    };

    /// <summary>
    /// A new document of sheets with the pages at these indexes (in this order) placed on them as form
    /// XObjects, each fitted to its cell and centred, with its rotation and crop box kept. Annotations
    /// that have an appearance are drawn into their page first and all others are dropped; the result
    /// counts both. A booklet pads with blank cells to a multiple of 4 pages. The source is not
    /// changed; bookmarks, labels, tags and other document data are not carried over.
    /// </summary>
    public static ImposeResult Impose(PdfDocument source, IReadOnlyList<int> pages, ImposeOptions options, CancellationToken cancel = default)
    {
        if (pages.Count == 0) throw new ArgumentException("There are no pages to place.", nameof(pages));
        if (!(options.SheetWidth is > 0 and <= MaxPageSize) || !(options.SheetHeight is > 0 and <= MaxPageSize)) throw new ArgumentOutOfRangeException(nameof(options), "The size is out of range.");
        bool booklet = options.Mode == ImposeMode.Booklet;
        if (!booklet && !Grids.ContainsKey(options.PerSheet)) throw new ArgumentException("A sheet holds 2, 4, 6, 9 or 16 pages.", nameof(options));
        if (!(options.Gap >= 0)) throw new ArgumentOutOfRangeException(nameof(options), "The gap is negative.");
        var (columns, rows) = booklet ? (2, 1) : Grids[options.PerSheet];
        double width = booklet ? Math.Max(options.SheetWidth, options.SheetHeight) : options.SheetWidth;
        double height = booklet ? Math.Min(options.SheetWidth, options.SheetHeight) : options.SheetHeight;
        double gap = options.Gap;
        double cellWidth = (width - gap * (columns + 1)) / columns, cellHeight = (height - gap * (rows + 1)) / rows;
        if (!(cellWidth > 0) || !(cellHeight > 0)) throw new ArgumentOutOfRangeException(nameof(options), "The gap leaves no room for the pages.");

        var target = PageAssembly.Blank(source.Version);
        var importer = new PageImporter(source, target);
        var copies = importer.Import(pages, cancel);
        if (source.Trailer["Info"] is { } info && source.Info is not null) target.Trailer["Info"] = importer.CopyValue(info);
        PageTree.Set(target, copies);

        int flattened = 0, dropped = 0;
        var forms = new List<PdfReference>();
        var shown = new List<PdfPage>(target.Pages);
        foreach (var page in shown)
        {
            cancel.ThrowIfCancellationRequested();
            flattened += PdfAnnotationFlattener.Flatten(target, page, a => a.Type is not (AnnotationType.Link or AnnotationType.Popup));
            dropped += target.Array(page.Dictionary, "Annots")?.Items.Count ?? 0;
            var form = new PdfDictionary
            {
                ["Type"] = new PdfName("XObject"),
                ["Subtype"] = new PdfName("Form"),
                ["FormType"] = new PdfNumber(1),
                ["BBox"] = page.CropBox.ToArray(),
                ["Resources"] = page.Resources ?? new PdfDictionary(),
                ["Filter"] = new PdfName("FlateDecode"),
            };
            if (page.Dictionary["Group"] is { } group) form["Group"] = group;
            forms.Add(target.Add(new PdfStream(form, PdfFilterEncoders.Flate(page.Contents()))));
        }

        // A booklet block of four pages a, b, c, d (first, second, second to last, last) prints d,a on the front and b,c on the back.
        var slots = new List<int?>(Enumerable.Range(0, pages.Count).Select(i => (int?)i));
        if (booklet)
        {
            while (slots.Count % 4 != 0) slots.Add(null);
            var folded = new List<int?>();
            int last = slots.Count - 1;
            for (int i = 0; i < slots.Count / 4; i++) folded.AddRange([slots[last - 2 * i], slots[2 * i], slots[2 * i + 1], slots[last - 2 * i - 1]]);
            slots = folded;
        }
        int perSheet = columns * rows;
        var sheets = new List<PdfReference>();
        for (int start = 0; start < slots.Count; start += perSheet)
        {
            cancel.ThrowIfCancellationRequested();
            var resources = new PdfDictionary();
            var content = new ContentWriter();
            for (int slot = 0; slot < perSheet && start + slot < slots.Count; slot++)
            {
                if (slots[start + slot] is not { } index) continue;
                var crop = shown[index].CropBox;
                int turn = shown[index].Rotate;
                double w = crop.Width, h = crop.Height, unit = shown[index].UserUnit;
                bool sideways = turn % 180 != 0;
                double shownWidth = (sideways ? h : w) * unit, shownHeight = (sideways ? w : h) * unit;
                double fit = Math.Min(cellWidth / shownWidth, cellHeight / shownHeight);
                double placedWidth = shownWidth * fit, placedHeight = shownHeight * fit;
                int column = slot % columns, row = slot / columns;
                double x = gap + column * (cellWidth + gap) + (cellWidth - placedWidth) / 2;
                double y = height - gap - (row + 1) * cellHeight - row * gap + (cellHeight - placedHeight) / 2;
                // Turns the crop box upright with its lower-left corner at the origin.
                var upright = turn switch
                {
                    90 => new PdfMatrix(0, -1, 1, 0, -crop.Bottom, w + crop.Left),
                    180 => new PdfMatrix(-1, 0, 0, -1, w + crop.Left, h + crop.Bottom),
                    270 => new PdfMatrix(0, 1, -1, 0, h + crop.Bottom, -crop.Left),
                    _ => new PdfMatrix(1, 0, 0, 1, -crop.Left, -crop.Bottom),
                };
                string name = ContentResources.Add(target, resources, "XObject", forms[index], "Fm");
                content.Save().Concat(upright.Multiply(PdfMatrix.Scale(fit * unit, fit * unit)).Multiply(PdfMatrix.Translate(x, y)));
                content.Op("Do", [new PdfName(name)]).Restore();
                if (options.Border) content.Save().LineWidth(0.5).StrokeGray(0).Rect(x, y, placedWidth, placedHeight).Stroke().Restore();
            }
            var sheet = new PdfDictionary
            {
                ["Type"] = new PdfName("Page"),
                ["MediaBox"] = new PdfRect(0, 0, width, height).ToArray(),
                ["CropBox"] = new PdfRect(0, 0, width, height).ToArray(),
                ["Rotate"] = new PdfNumber(0L),
                ["Resources"] = resources,
                ["Contents"] = target.Add(new PdfStream(new PdfDictionary { ["Filter"] = new PdfName("FlateDecode") }, PdfFilterEncoders.Flate(content.ToArray()))),
            };
            sheets.Add(target.Add(sheet));
        }
        PageTree.Set(target, sheets);
        foreach (var copy in copies) target.Delete(copy.Number);
        // The importer carried the form fields over, but every widget is now flattened or dropped.
        target.Catalog.Remove("AcroForm");
        return new ImposeResult(target, sheets.Count, flattened, dropped);
    }
}
