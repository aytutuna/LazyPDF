using System.Windows;
using System.Windows.Documents;
using System.Windows.Media;

namespace LazyPDF.App.Services;

/// <summary>The pages of a document for the Windows print dialog, each drawn by the renderer to fit the paper.</summary>
internal sealed class PagePaginator(IDocumentRenderer renderer, int pageCount) : DocumentPaginator
{
    // The size the printer driver does not mind drawing at; a larger page is shrunk to fit, a smaller one stays its own size.
    private const double PrintDpi = 300;

    private Size _pageSize = new(816, 1056);

    /// <summary>Pages that came out empty because the renderer could not draw them.</summary>
    public int Blank { get; private set; }

    public override bool IsPageCountValid => true;

    public override int PageCount => pageCount;

    public override Size PageSize
    {
        get => _pageSize;
        set => _pageSize = value;
    }

    public override IDocumentPaginatorSource? Source => null;

    public override DocumentPage GetPage(int pageNumber)
    {
        var visual = new DrawingVisual();
        var (width, height) = renderer.PageSize(pageNumber);
        bool drawn = false;
        if (width > 0 && height > 0)
        {
            double wide = width * 96 / 72, tall = height * 96 / 72;
            double scale = Math.Min(1, Math.Min(_pageSize.Width / wide, _pageSize.Height / tall));
            if (renderer.Render(pageNumber, PrintDpi * scale) is { } image)
            {
                var area = new Rect((_pageSize.Width - wide * scale) / 2, (_pageSize.Height - tall * scale) / 2, wide * scale, tall * scale);
                using var context = visual.RenderOpen();
                context.DrawImage(Pixels.ToBitmap(image), area);
                drawn = true;
            }
        }
        if (!drawn) Blank++;
        var whole = new Rect(_pageSize);
        return new DocumentPage(visual, _pageSize, whole, whole);
    }
}
