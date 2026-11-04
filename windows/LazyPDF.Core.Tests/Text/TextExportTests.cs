using Xunit;
using static LazyPDF.Core.Tests.TextTestPdf;

namespace LazyPDF.Core.Tests;

public class TextExportTests
{
    private static PdfDocument Pages(int count, Func<int, string> content)
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        var kids = string.Join(" ", Enumerable.Range(0, count).Select(i => $"{3 + i} 0 R"));
        pdf.Obj(2, $"<</Type /Pages /Kids [{kids}] /Count {count} /MediaBox [0 0 600 800]>>");
        for (int i = 0; i < count; i++) pdf.Obj(3 + i, $"<</Type /Page /Parent 2 0 R /Contents {3 + count + i} 0 R /Resources <</Font <</F1 {3 + 2 * count} 0 R>>>>>>");
        for (int i = 0; i < count; i++) pdf.Stream(3 + count + i, "", content(i));
        Font(pdf, 3 + 2 * count);
        return PdfDocument.Open(pdf.Finish());
    }

    [Fact]
    public void APageExportsAsPlainText()
    {
        var page = Text(Line(50, 700, "Title") + Line(50, 650, "first line") + Line(50, 638, "second line"));
        Assert.Equal("Title\n\nfirst line\nsecond line", TextExport.Page(page));
    }

    [Fact]
    public void HyphensAtLineEndsAreJoinedOnRequest()
    {
        var page = Text(Line(50, 700, "a long informa-") + Line(50, 688, "tion and well-") + Line(50, 676, "Known text"));
        Assert.Equal("a long informa-\ntion and well-\nKnown text", TextExport.Page(page));
        Assert.Equal("a long information and well-Known text", TextExport.Page(page, joinHyphens: true));
    }

    [Fact]
    public void ARangeOfPagesIsSeparatedByFormFeeds()
    {
        var document = Pages(3, i => Line(50, 700, $"page {i + 1}"));
        var cache = new TextCache(document);
        Assert.Equal("page 1\fpage 2\fpage 3\f", TextExport.Range(cache, 0, 2));
        Assert.Equal("page 2\f", TextExport.Range(cache, 1, 1));
        Assert.Equal("page 3\f", TextExport.Range(cache, 2, 99));
        Assert.Equal("", TextExport.Range(cache, 5, 7));
    }

    [Fact]
    public void ExportCanBeCancelled()
    {
        var cache = new TextCache(Pages(2, i => Line(50, 700, "x")));
        using var source = new CancellationTokenSource();
        source.Cancel();
        Assert.Throws<OperationCanceledException>(() => TextExport.Range(cache, 0, 1, cancel: source.Token));
    }

    [Fact]
    public void TheCacheKeepsPagesUntilTheCapIsHit()
    {
        var document = Pages(4, i => Line(50, 700, "twelve chars"));
        var cache = new TextCache(document, maxChars: 30);
        var first = cache.Get(0);
        Assert.Same(first, cache.Get(0));
        cache.Get(1);
        Assert.Same(first, cache.Get(0));
        cache.Get(2);
        cache.Get(3);
        Assert.NotSame(first, cache.Get(0));
        Assert.Equal(4, cache.PageCount);
    }

    [Fact]
    public void AnOversizedPageIsStillReturned()
    {
        var cache = new TextCache(Pages(1, i => Line(50, 700, "more than five chars")), maxChars: 5);
        Assert.Equal("more than five chars", cache.Get(0).Text);
    }

    [Fact]
    public void ClearingForgetsThePages()
    {
        var cache = new TextCache(Pages(1, i => Line(50, 700, "x")));
        var page = cache.Get(0);
        cache.Clear();
        Assert.NotSame(page, cache.Get(0));
    }

    [Fact]
    public void PagesAreNumberedByIndex()
    {
        var cache = new TextCache(Pages(3, i => Line(50, 700, "x")));
        Assert.Equal(2, cache.Get(2).PageIndex);
    }
}
