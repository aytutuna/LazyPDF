using LazyPDF.App.Viewer;
using Xunit;

namespace LazyPDF.App.Tests;

// The text of a file as the viewer reads it, apart from the tab's own document.
public sealed class TextSourceTests
{
    [Fact]
    public async Task EachPageGivesItsText()
    {
        var source = await TextSource.OpenAsync(Pdfs.Text(3), null);

        var second = await source!.GetAsync(1);

        Assert.Equal(3, source.PageCount);
        Assert.Contains("Page 2.", second!.Text);
    }

    [Fact]
    public async Task APageIsOnlyThereToPeekAtOnceItWasAskedFor()
    {
        var source = await TextSource.OpenAsync(Pdfs.Text(2), null);
        Assert.Null(source!.Peek(0));

        var page = await source.GetAsync(0);

        Assert.Same(page, source.Peek(0));
    }

    [Fact]
    public async Task APageThatIsNotThereIsNull()
    {
        var source = await TextSource.OpenAsync(Pdfs.Text(1), null);

        Assert.Null(await source!.GetAsync(5));
        Assert.Null(await source.GetAsync(-1));
    }

    [Fact]
    public async Task AFileThatNeedsAPasswordTheViewerLacksGivesNoSource()
    {
        byte[] locked = File.ReadAllBytes(Pdfs.Fixture("locked.pdf"));

        Assert.Null(await TextSource.OpenAsync(locked, null));
        Assert.NotNull(await TextSource.OpenAsync(locked, "secret"));
    }

    [Fact]
    public async Task TheSourceReadsTheBytesItWasGivenNotTheTabsLaterOnes()
    {
        byte[] bytes = Pdfs.Text(1, "Before the edit");
        var source = await TextSource.OpenAsync(bytes, null);

        var page = await source!.GetAsync(0);

        Assert.Contains("Before the edit", page!.Text);
    }
}
