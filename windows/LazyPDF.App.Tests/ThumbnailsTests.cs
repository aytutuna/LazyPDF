using LazyPDF.App.Services;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// The pictures on the Home tab: made from the first page and kept under a name that changes with the file.
public sealed class ThumbnailsTests
{
    private static readonly byte[] PngSignature = [0x89, 0x50, 0x4E, 0x47];

    private static Thumbnails Make(TempDir dir) => new(() => new WindowsPageRenderer(), dir.Sub("thumbs"));

    [Fact]
    public async Task AFileGivesAPngOfItsFirstPage()
    {
        using var dir = new TempDir();
        string path = dir.File("a.pdf", Pdfs.Text(pages: 2));

        byte[]? png = await Make(dir).GetAsync(path, 200);

        Assert.NotNull(png);
        Assert.Equal(PngSignature, png.AsSpan(0, 4).ToArray());
        Assert.InRange(BitConverter.ToInt32([png[19], png[18], png[17], png[16]]), 198, 202);
    }

    [Fact]
    public async Task ThePictureIsKeptAndUsedTheSecondTime()
    {
        using var dir = new TempDir();
        string path = dir.File("a.pdf", Pdfs.Text());
        var thumbnails = Make(dir);

        byte[]? first = await thumbnails.GetAsync(path);
        var cached = Directory.GetFiles(dir.Sub("thumbs"));
        byte[]? second = await thumbnails.GetAsync(path);

        Assert.Single(cached);
        Assert.Equal(first, second);
        Assert.Single(Directory.GetFiles(dir.Sub("thumbs")));
    }

    [Fact]
    public async Task AChangedFileGetsANewPicture()
    {
        using var dir = new TempDir();
        string path = dir.File("a.pdf", Pdfs.Text());
        var thumbnails = Make(dir);
        await thumbnails.GetAsync(path);

        File.WriteAllBytes(path, Pdfs.Text(pages: 2, line: "Another text"));
        await thumbnails.GetAsync(path);

        Assert.Equal(2, Directory.GetFiles(dir.Sub("thumbs")).Length);
    }

    [Fact]
    public async Task AFileThatNeedsAPasswordHasNoPicture()
    {
        using var dir = new TempDir();
        string path = dir.File("locked.pdf", File.ReadAllBytes(Pdfs.Fixture("locked.pdf")));

        Assert.Null(await Make(dir).GetAsync(path));
    }

    [Fact]
    public async Task AFileThatIsNotThereOrNotAPdfHasNoPicture()
    {
        using var dir = new TempDir();
        string junk = dir.File("junk.pdf", "not a pdf"u8.ToArray());
        var thumbnails = Make(dir);

        Assert.Null(await thumbnails.GetAsync(dir.Sub("none.pdf")));
        Assert.Null(await thumbnails.GetAsync(junk));
    }

    [Fact]
    public async Task APictureOldEnoughIsPrunedAtTheNextStart()
    {
        using var dir = new TempDir();
        string path = dir.File("a.pdf", Pdfs.Text());
        await Make(dir).GetAsync(path);
        string cached = Directory.GetFiles(dir.Sub("thumbs")).Single();
        File.SetLastWriteTimeUtc(cached, DateTime.UtcNow.AddDays(-90));

        _ = Make(dir);

        Assert.Empty(Directory.GetFiles(dir.Sub("thumbs")));
    }

    [Fact]
    public async Task ForgettingAFileDeletesOnlyItsPicture()
    {
        using var dir = new TempDir();
        string a = dir.File("a.pdf", Pdfs.Text());
        string b = dir.File("b.pdf", Pdfs.Text(line: "Other"));
        var thumbnails = Make(dir);
        await thumbnails.GetAsync(a);
        await thumbnails.GetAsync(b);
        var both = Directory.GetFiles(dir.Sub("thumbs"));

        thumbnails.Forget(a);

        var left = Directory.GetFiles(dir.Sub("thumbs")).Single();
        Assert.Contains(left, both);
        thumbnails.Forget(b);
        Assert.Empty(Directory.GetFiles(dir.Sub("thumbs")));
    }

    [Fact]
    public async Task ClearingEmptiesTheFolder()
    {
        using var dir = new TempDir();
        var thumbnails = Make(dir);
        await thumbnails.GetAsync(dir.File("a.pdf", Pdfs.Text()));
        await thumbnails.GetAsync(dir.File("b.pdf", Pdfs.Text(line: "Other")));

        thumbnails.Clear();

        Assert.Empty(Directory.GetFiles(dir.Sub("thumbs")));
    }

    [Fact]
    public async Task AFileWithAnOwnerPasswordHasNoPicture()
    {
        using var dir = new TempDir();
        string path = dir.File("owner.pdf", Pdfs.Restricted(PdfPermissions.All & ~PdfPermissions.Copy));

        Assert.Null(await Make(dir).GetAsync(path));
        Assert.False(Directory.Exists(dir.Sub("thumbs")) && Directory.GetFiles(dir.Sub("thumbs")).Length > 0);
    }

    [Fact]
    public async Task AFileOverTheSizeLimitHasNoPicture()
    {
        using var dir = new TempDir();
        string path = dir.File("a.pdf", Pdfs.Text());
        long limit = Thumbnails.MaxFileBytes;
        Thumbnails.MaxFileBytes = 10;
        try
        {
            Assert.Null(await Make(dir).GetAsync(path));
        }
        finally
        {
            Thumbnails.MaxFileBytes = limit;
        }
    }

    [Fact]
    public async Task FilesAskedForTogetherAllGetAPicture()
    {
        using var dir = new TempDir();
        var thumbnails = Make(dir);

        var pngs = await Task.WhenAll(
            thumbnails.GetAsync(dir.File("a.pdf", Pdfs.Text())),
            thumbnails.GetAsync(dir.File("b.pdf", Pdfs.Text(line: "Other"))));

        Assert.All(pngs, png => Assert.Equal(PngSignature, png!.AsSpan(0, 4).ToArray()));
    }

    [Fact]
    public async Task NoMoreThanTwoPicturesAreDrawnAtOnce()
    {
        using var dir = new TempDir();
        int now = 0, peak = 0;
        var thumbnails = new Thumbnails(() => new SlowRenderer(() =>
        {
            int n = Interlocked.Increment(ref now);
            lock (dir) peak = Math.Max(peak, n);
            Thread.Sleep(150);
            Interlocked.Decrement(ref now);
        }), dir.Sub("thumbs"));

        var pngs = await Task.WhenAll(Enumerable.Range(0, 6)
            .Select(i => thumbnails.GetAsync(dir.File($"f{i}.pdf", Pdfs.Text(line: $"Text {i}")))));

        Assert.All(pngs, Assert.NotNull);
        Assert.Equal(2, peak);
    }

    [Fact]
    public async Task AnEncryptedFileIsNotOpenedAgain()
    {
        using var dir = new TempDir();
        int made = 0;
        var thumbnails = new Thumbnails(() =>
        {
            made++;
            return new FakeRenderer();
        }, dir.Sub("thumbs"));
        string path = dir.File("owner.pdf", Pdfs.Restricted(PdfPermissions.All & ~PdfPermissions.Copy));

        Assert.Null(await thumbnails.GetAsync(path));
        Assert.Null(await thumbnails.GetAsync(path));
        Assert.Equal(1, made);

        thumbnails.Forget(path);
        Assert.Null(await thumbnails.GetAsync(path));
        Assert.Equal(2, made);
    }

    [Fact]
    public void ForgettingAndClearingWithoutTheFolderDoNotThrow()
    {
        using var dir = new TempDir();
        var thumbnails = Make(dir);

        thumbnails.Forget(dir.Sub("a.pdf"));
        thumbnails.Clear();
    }

    private sealed class SlowRenderer(Action onRender) : IDocumentRenderer
    {
        public bool Load(PdfEditSession session, string? password) => true;

        public (double Width, double Height) PageSize(int pageIndex) => (200, 300);

        public PdfRgbaImage? Render(int pageIndex, double dpi)
        {
            onRender();
            return new PdfRgbaImage(4, 6, Enumerable.Repeat((byte)255, 4 * 6 * 4).ToArray());
        }

        public void Dispose() { }
    }
}
