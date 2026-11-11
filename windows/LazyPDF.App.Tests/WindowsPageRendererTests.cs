using LazyPDF.App.Services;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// Windows.Data.Pdf as the app uses it, against what the probe of the system found.
public sealed class WindowsPageRendererTests
{
    private static WindowsPageRenderer Load(PdfEditSession session, string? password = null)
    {
        var renderer = new WindowsPageRenderer();
        Assert.True(renderer.Load(session, password));
        return renderer;
    }

    private static int Dark(PdfRgbaImage image) =>
        Enumerable.Range(0, image.Width * image.Height).Count(i => image.Rgba[i * 4] < 128);

    [Fact]
    public void ThePagesAreCountedAndMeasuredInPoints()
    {
        using var renderer = Load(PdfEditSession.Open(Pdfs.Text(pages: 3)));

        Assert.Equal(3, renderer.PageCount);
        var (width, height) = renderer.PageSize(0);
        Assert.Equal(595.3, width, 0.5);
        Assert.Equal(841.9, height, 0.5);
        Assert.Equal((0, 0), renderer.PageSize(3));
    }

    [Fact]
    public async Task ALoadThatFinishesAfterDisposeLeavesNothing()
    {
        var renderer = new WindowsPageRenderer();

        var loading = renderer.LoadAsync(PdfEditSession.Open(Pdfs.Text(pages: 3)), null);
        renderer.Dispose();
        await loading;

        Assert.Equal(0, renderer.PageCount);
    }

    [Fact]
    public async Task TwoLoadsInSequenceLeaveTheSecond()
    {
        using var renderer = new WindowsPageRenderer();

        await renderer.LoadAsync(PdfEditSession.Open(Pdfs.Text(pages: 3)), null);
        await renderer.LoadAsync(PdfEditSession.Open(Pdfs.Text(pages: 2)), null);

        Assert.Equal(2, renderer.PageCount);
    }

    [Fact]
    public async Task OverlappingLoadsLeaveTheLastStarted()
    {
        using var renderer = new WindowsPageRenderer();

        var slow = renderer.LoadAsync(PdfEditSession.Open(Pdfs.Text(pages: 40)), null);
        var fast = renderer.LoadAsync(PdfEditSession.Open(Pdfs.Text(pages: 2)), null);
        await Task.WhenAll(slow, fast);

        Assert.Equal(2, renderer.PageCount);
    }

    [Fact]
    public void APageIsDrawnWithTextOnWhite()
    {
        using var renderer = Load(PdfEditSession.Open(Pdfs.Text()));

        var image = renderer.Render(0, 72);

        Assert.NotNull(image);
        Assert.InRange(image.Width, 594, 596);
        Assert.Equal(image.Width * image.Height * 4, image.Rgba.Length);
        Assert.Equal(255, image.Rgba[3]);
        Assert.InRange(Dark(image), 50, image.Width * image.Height / 4);
    }

    [Fact]
    public void ADrawnPageIsTheRightWayUp()
    {
        using var renderer = Load(PdfEditSession.Open(Pdfs.Text()));
        var image = renderer.Render(0, 72)!;

        // The text starts at the top of the page: dark pixels in the upper half, none in the lower.
        int half = image.Height / 2;
        int upper = Enumerable.Range(0, half * image.Width).Count(i => image.Rgba[i * 4] < 128);
        int lower = Enumerable.Range(half * image.Width, half * image.Width).Count(i => image.Rgba[i * 4] < 128);
        Assert.True(upper > 0);
        Assert.Equal(0, lower);
    }

    [Fact]
    public void AHigherResolutionIsBiggerByTheRatio()
    {
        using var renderer = Load(PdfEditSession.Open(Pdfs.Text()));

        var small = renderer.Render(0, 72)!;
        var large = renderer.Render(0, 144)!;

        Assert.InRange((double)large.Width / small.Width, 1.98, 2.02);
    }

    [Fact]
    public void ASizeIsRoundedToWhatTheSystemReaches()
    {
        int reached = WindowsPageRenderer.Reachable(500);

        Assert.InRange(reached, 499, 501);
        Assert.Equal(reached, WindowsPageRenderer.Reachable(reached));
    }

    [Fact]
    public void TheScaleIsMeasuredFromTheSystem()
    {
        using var renderer = Load(PdfEditSession.Open(Pdfs.Text()));

        Assert.InRange(WindowsPageRenderer.Scale, 1.0, 3.0);
    }

    [Fact]
    public async Task ARegionIsTheSameAsThatPartOfThePage()
    {
        using var renderer = Load(PdfEditSession.Open(Pdfs.Text(line: "Region test line.")));
        double pixelsPerPoint = 2;
        var whole = (await renderer.RenderAsync(0, 144))!;

        var tile = (await renderer.RenderTileAsync(0, pixelsPerPoint, 0, 0, 280, 120))!;

        Assert.InRange(tile.Width, 279, 281);
        int differing = 0, compared = 0;
        for (int y = 0; y < tile.Height && y < whole.Height; y++)
        {
            for (int x = 0; x < tile.Width && x < whole.Width; x++)
            {
                compared++;
                if (Math.Abs(tile.Rgba[(y * tile.Width + x) * 4] - whole.Rgba[(y * whole.Width + x) * 4]) > 64) differing++;
            }
        }
        Assert.True(differing < compared * 0.02, $"{differing} of {compared} pixels differ");
    }

    [Fact]
    public async Task ARectangleOfThePageIsDrawnAtTheAskedSize()
    {
        using var renderer = Load(PdfEditSession.Open(Pdfs.Text()));

        var image = await renderer.RenderRegionAsync(0, new DisplayRect(36, 36, 200, 100), 144);

        Assert.NotNull(image);
        Assert.InRange(image.Width, 399, 401);
        Assert.InRange(image.Height, 199, 201);
    }

    [Fact]
    public void APageThatIsNotThereGivesNothing()
    {
        using var renderer = Load(PdfEditSession.Open(Pdfs.Text()));

        Assert.Null(renderer.Render(5, 72));
        Assert.Null(renderer.Render(-1, 72));
        Assert.Null(renderer.Render(0, 0));
    }

    [Fact]
    public void ADocumentThatWasNeverLoadedDrawsNothing()
    {
        using var renderer = new WindowsPageRenderer();

        Assert.Null(renderer.Render(0, 72));
        Assert.Equal(0, renderer.PageCount);
    }

    [Fact]
    public void AfterACommitTheNewFileIsWhatIsDrawn()
    {
        var session = PdfEditSession.Open(Pdfs.Text(pages: 1));
        using var renderer = Load(session);
        Assert.Equal(1, renderer.PageCount);

        PageOperations.InsertBlank(session.Document, 1, 612, 792);
        session.Commit("Add a page");
        Assert.True(renderer.Load(session, null));

        Assert.Equal(2, renderer.PageCount);
        Assert.Equal(612, renderer.PageSize(1).Width, 0.5);
    }

    [Fact]
    public void AFileWithAPasswordIsDrawnOnceItIsOpened()
    {
        var session = PdfEditSession.Open(Pdfs.Fixture("locked.pdf"), "secret");

        using var renderer = Load(session, "secret");

        Assert.NotNull(renderer.Render(0, 72));
    }

    [Fact]
    public void AFileOnlyTheOwnerRestrictsIsDrawnWithNoPassword()
    {
        var session = PdfEditSession.Open(Pdfs.Fixture("owner-only-aes.pdf"));

        using var renderer = Load(session);

        Assert.NotNull(renderer.Render(0, 72));
    }

    [Fact]
    public void AnAes256FileIsDecryptedByTheEngineBeforeTheSystemSeesIt()
    {
        var session = PdfEditSession.Open(Pdfs.Fixture("crypt-aes256.pdf"), "secret");
        Assert.True(session.Document.Security is { Revision: >= 6 }, "the fixture is a revision 6 file");

        using var renderer = Load(session, "secret");

        Assert.NotNull(renderer.Render(0, 72));
    }

    [Fact]
    public void ABitmapIsReadFromTheBottomRowUp()
    {
        // 2 by 2, bottom row first: red, green / blue, white (B G R A in the file).
        byte[] bmp = new byte[54 + 16];
        bmp[0] = (byte)'B';
        bmp[1] = (byte)'M';
        BitConverter.GetBytes(54).CopyTo(bmp, 10);
        BitConverter.GetBytes(2).CopyTo(bmp, 18);
        BitConverter.GetBytes(2).CopyTo(bmp, 22);
        BitConverter.GetBytes((short)32).CopyTo(bmp, 28);
        byte[] pixels = [0, 0, 255, 255, 0, 255, 0, 255, 255, 0, 0, 255, 255, 255, 255, 255];
        pixels.CopyTo(bmp, 54);

        var (width, height, rgba) = WindowsPageRenderer.ParseBmp(bmp);

        Assert.Equal((2, 2), (width, height));
        Assert.Equal(new byte[] { 0, 0, 255, 255, 255, 255, 255, 255, 255, 0, 0, 255, 0, 255, 0, 255 }, rgba);
    }

    [Fact]
    public void ABitmapThatIsNotThirtyTwoBitsIsRefused()
    {
        byte[] bmp = new byte[54 + 16];
        bmp[0] = (byte)'B';
        bmp[1] = (byte)'M';
        BitConverter.GetBytes(54).CopyTo(bmp, 10);
        BitConverter.GetBytes(2).CopyTo(bmp, 18);
        BitConverter.GetBytes(2).CopyTo(bmp, 22);
        BitConverter.GetBytes((short)24).CopyTo(bmp, 28);

        Assert.Throws<InvalidDataException>(() => WindowsPageRenderer.ParseBmp(bmp));
    }
}
