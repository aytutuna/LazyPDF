using LazyPDF.App.Services;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// Files the system cannot read as they are: restricted AES-256 files are decrypted for drawing, and /UserUnit pages keep their size.
public sealed class RestrictedAndScaledPagesTests
{
    private static WindowsPageRenderer Load(PdfEditSession session, string? password = null)
    {
        var renderer = new WindowsPageRenderer();
        Assert.True(renderer.Load(session, password));
        return renderer;
    }

    // A page of 100 by 100 units, /UserUnit 2 (so 200 points), filled with black.
    private static byte[] BlackPage(int unit)
    {
        string content = "0 g 0 0 100 100 re f";
        string text = "%PDF-1.7\n"
            + "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n"
            + "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n"
            + $"3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /UserUnit {unit} /Contents 4 0 R >>\nendobj\n"
            + $"4 0 obj\n<< /Length {content.Length} >>\nstream\n{content}\nendstream\nendobj\n"
            + "trailer\n<< /Root 1 0 R /Size 5 >>\n%%EOF\n";
        return System.Text.Encoding.ASCII.GetBytes(text);
    }

    [Fact]
    public void ARestrictedAes256FileOpenedWithoutTheOwnerIsStillDrawn()
    {
        var session = PdfEditSession.Open(Pdfs.Restricted(PdfPermissions.Print));
        Assert.True(session.Document.Security is { Revision: >= 6, OpenedAsOwner: false });

        using var renderer = Load(session);

        Assert.NotNull(renderer.Render(0, 72));
    }

    [Fact]
    public void AUserUnitPageIsLaidOutAtItsRealSize()
    {
        var session = PdfEditSession.Open(BlackPage(2));

        using var renderer = Load(session);

        var (width, height) = renderer.PageSize(0);
        Assert.Equal(200, width, 2);
        Assert.Equal(200, height, 2);
    }

    [Fact]
    public async Task AUserUnitPageLoadedAsyncIsLaidOutAtItsRealSize()
    {
        using var renderer = new WindowsPageRenderer();

        Assert.True(await renderer.LoadAsync(PdfEditSession.Open(BlackPage(2)), null));

        var (width, height) = renderer.PageSize(0);
        Assert.Equal(200, width, 2);
        Assert.Equal(200, height, 2);
    }

    [Fact]
    public async Task ARegionOfAUserUnitPageIsTakenFromTheRightPlace()
    {
        var session = PdfEditSession.Open(BlackPage(2));
        using var renderer = Load(session);

        // The black square is the whole page, so the far corner of the 200 point page is black too.
        var image = await renderer.RenderRegionAsync(0, new DisplayRect(150, 150, 50, 50), 72);

        Assert.NotNull(image);
        Assert.True(image!.Rgba[0] < 64);
        Assert.True(image.Rgba[(image.Width * image.Height - 1) * 4] < 64);
    }

    [Fact]
    public void ALoadLeavesTheEarlierOneToFinishItsDrawing()
    {
        var session = PdfEditSession.Open(Pdfs.Text(2));
        using var renderer = Load(session);
        for (int i = 0; i < 5; i++) Assert.True(renderer.Load(session, null));

        Assert.NotNull(renderer.Render(1, 72));
        Assert.Equal(2, renderer.PageCount);
    }
}
