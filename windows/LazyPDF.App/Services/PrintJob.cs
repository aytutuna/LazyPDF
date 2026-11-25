using LazyPDF.Core;

namespace LazyPDF.App.Services;

/// <summary>What a print draws: a renderer, the pages of it to send in order and how many annotations the layout left off.</summary>
internal sealed class PrintJob(IDocumentRenderer renderer, int pageCount, IReadOnlyList<int>? sides, int dropped, IDocumentRenderer? owned) : IDisposable
{
    public IDocumentRenderer Renderer => renderer;

    /// <summary>Pages in <see cref="Renderer"/>.</summary>
    public int PageCount => pageCount;

    /// <summary>Zero-based pages of <see cref="Renderer"/> to send, -1 for a blank; null means every page.</summary>
    public IReadOnlyList<int>? Sides => sides;

    public bool IsEmpty => sides is { Count: 0 };

    public int Dropped => dropped;

    /// <summary>Picks the pages and, for a layout, makes the sheets from the file as it stands and opens them in a renderer of their own; the open file is not touched.</summary>
    public static async Task<PrintJob> Prepare(PrintLayout layout, PdfDocument source, IDocumentRenderer renderer, int pageCount, IReadOnlyList<int>? range,
        Func<IDocumentRenderer> newRenderer, double sheetWidth, double sheetHeight, CancellationToken cancel = default)
    {
        var pages = layout.IsPlain ? range : layout.Pages(range, pageCount);
        if (!layout.Imposes) return new PrintJob(renderer, pageCount, pages, 0, null);
        if (pages is { Count: 0 }) return new PrintJob(renderer, pageCount, [], 0, null);
        var sheets = await Task.Run(() => layout.Sheets(source, pages!, sheetWidth, sheetHeight, cancel), cancel);
        var own = newRenderer();
        if (!own.Load(PdfEditSession.Open(sheets.Bytes), null))
        {
            own.Dispose();
            throw new InvalidOperationException("The sheets cannot be drawn.");
        }
        return new PrintJob(own, sheets.Count, layout.SheetsToPrint(sheets.Count), sheets.Dropped, own);
    }

    public void Dispose() => owned?.Dispose();
}
