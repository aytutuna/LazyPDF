using LazyPDF.App.Services;
using System.Windows.Controls;
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

    private static bool Turned(System.Windows.Media.Drawing? drawing) => drawing switch
    {
        System.Windows.Media.DrawingGroup group => group.Transform is System.Windows.Media.RotateTransform { Angle: 90 } || group.Children.Any(Turned),
        _ => false,
    };

    [Fact]
    public void A_landscape_page_is_turned_on_portrait_paper()
    {
        var paginator = new PagePaginator(new SizedRenderer(792, 612), 1);
        Assert.True(Turned(((System.Windows.Media.DrawingVisual)paginator.GetPage(0).Visual).Drawing));
    }

    [Fact]
    public void A_portrait_page_stays_upright()
    {
        var paginator = new PagePaginator(new SizedRenderer(612, 792), 1);
        Assert.False(Turned(((System.Windows.Media.DrawingVisual)paginator.GetPage(0).Visual).Drawing));
    }

    [Theory]
    [InlineData(PageRangeSelection.AllPages, 1, 1, 0, 8, null)]
    [InlineData(PageRangeSelection.CurrentPage, 1, 1, 4, 8, new[] { 4 })]
    [InlineData(PageRangeSelection.UserPages, 3, 5, 0, 8, new[] { 2, 3, 4 })]
    [InlineData(PageRangeSelection.UserPages, 5, 3, 0, 8, new[] { 2, 3, 4 })]
    [InlineData(PageRangeSelection.UserPages, 6, 20, 0, 8, new[] { 5, 6, 7 })]
    [InlineData(PageRangeSelection.UserPages, 9, 12, 0, 8, new[] { 7 })]
    [InlineData(PageRangeSelection.UserPages, 1, 3, 0, 0, new int[0])]
    [InlineData(PageRangeSelection.CurrentPage, 1, 1, 9, 9, new[] { 8 })]
    [InlineData(PageRangeSelection.CurrentPage, 1, 1, 0, 0, new int[0])]
    public void The_dialog_choice_becomes_pages(PageRangeSelection selection, int from, int to, int current, int count, int[]? expected)
    {
        Assert.Equal(expected, PagePaginator.PagesFor(selection, from, to, current, count)?.ToArray());
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

    [Fact]
    public void A_cancelled_token_stops_the_next_page()
    {
        using var source = new CancellationTokenSource();
        var paginator = new PagePaginator(new SizedRenderer(612, 792), 3, null, source.Token);
        paginator.GetPage(0);
        source.Cancel();
        Assert.Throws<OperationCanceledException>(() => paginator.GetPage(1));
    }

    [Fact]
    public void Progress_is_reported_once_per_page()
    {
        var seen = new List<(int, int)>();
        var paginator = new PagePaginator(new SizedRenderer(612, 792), 3, null, default, (n, count) => seen.Add((n, count)));
        for (int i = 0; i < 3; i++) paginator.GetPage(i);
        Assert.Equal([(1, 3), (2, 3), (3, 3)], seen);
    }
}
