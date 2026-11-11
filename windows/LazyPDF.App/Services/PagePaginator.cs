using System.Windows;
using System.Windows.Documents;
using System.Windows.Media;

namespace LazyPDF.App.Services;

/// <summary>The pages of a document for the Windows print dialog, each drawn by the renderer to fit the paper.</summary>
internal sealed class PagePaginator(IDocumentRenderer renderer, int pageCount, IReadOnlyList<int>? pages = null) : DocumentPaginator
{
    // The size the printer driver does not mind drawing at; a larger page is shrunk to fit, a smaller one stays its own size.
    private const double PrintDpi = 300;

    private Size _pageSize = new(816, 1056);

    /// <summary>Pages that came out empty because the renderer could not draw them.</summary>
    public int Blank { get; private set; }

    public override bool IsPageCountValid => true;

    public override int PageCount => pages?.Count ?? pageCount;

    public override Size PageSize
    {
        get => _pageSize;
        set => _pageSize = value;
    }

    public override IDocumentPaginatorSource? Source => null;

    public override DocumentPage GetPage(int pageNumber)
    {
        var visual = new DrawingVisual();
        if (pages is not null) pageNumber = pages[pageNumber];
        var (width, height) = renderer.PageSize(pageNumber);
        bool drawn = false;
        if (width > 0 && height > 0)
        {
            double wide = width * 96 / 72, tall = height * 96 / 72;
            double w = _pageSize.Width, h = _pageSize.Height;
            double upright = Math.Min(1, Math.Min(w / wide, h / tall));
            double turned = Math.Min(1, Math.Min(w / tall, h / wide));
            bool turn = turned > upright;
            double scale = turn ? turned : upright;
            if (renderer.Render(pageNumber, PrintDpi * scale) is { } image)
            {
                double across = wide * scale, down = tall * scale;
                var area = new Rect((w - across) / 2, (h - down) / 2, across, down);
                using var context = visual.RenderOpen();
                // The picture is centred upright and then turned about the paper's centre, so it ends up sideways.
                if (turn) context.PushTransform(new RotateTransform(90, w / 2, h / 2));
                context.DrawImage(Pixels.ToBitmap(image), area);
                drawn = true;
            }
        }
        if (!drawn) Blank++;
        var whole = new Rect(_pageSize);
        return new DocumentPage(visual, _pageSize, whole, whole);
    }
}
