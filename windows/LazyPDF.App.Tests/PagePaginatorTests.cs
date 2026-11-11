using LazyPDF.App.Services;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

public sealed class PagePaginatorTests
{
    private sealed class SizedRenderer(double width, double height) : IDocumentRenderer
    {
        public List<int> Asked { get; } = [];

        public bool Load(PdfEditSession session, string? password) => true;

        public (double Width, double Height) PageSize(int pageIndex) => (width, height);

        public PdfRgbaImage? Render(int pageIndex, double dpi)
        {
            Asked.Add(pageIndex);
            return new PdfRgbaImage(4, 6, Enumerable.Repeat((byte)255, 4 * 6 * 4).ToArray());
        }

        public void Dispose() { }
    }

    [Fact]
    public void A_landscape_page_is_turned_on_portrait_paper()
    {
        var paginator = new PagePaginator(new SizedRenderer(792, 612), 1);
        Assert.True(paginator.GetPage(0).Visual is System.Windows.Media.DrawingVisual { ContentBounds.Height: > 1000 });
    }

    [Fact]
    public void A_portrait_page_stays_upright()
    {
        var paginator = new PagePaginator(new SizedRenderer(612, 792), 1);
        Assert.True(paginator.GetPage(0).Visual is System.Windows.Media.DrawingVisual { ContentBounds.Height: > 1000 });
    }

    [Fact]
    public void Chosen_pages_are_drawn_in_the_order_given()
    {
        var renderer = new SizedRenderer(612, 792);
        var paginator = new PagePaginator(renderer, 5, [2, 0]);
        paginator.GetPage(0);
        paginator.GetPage(1);
        Assert.Equal(2, paginator.PageCount);
        Assert.Equal([2, 0], renderer.Asked);
    }
}
