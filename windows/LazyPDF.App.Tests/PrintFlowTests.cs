using System.Windows;
using LazyPDF.App.Documents;
using LazyPDF.App.Services;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// Printing: Lazy Print when it takes the file, otherwise the pages drawn for the Windows print dialog.
public sealed class PrintFlowTests
{
    [Fact]
    public async Task LazyPrintIsHandedAFileOfTheDocumentAsItStands()
    {
        using var f = new ViewModelFixture();
        f.Sisters.PrintTaken = true;
        await f.Vm.OpenAsync(f.Pdf("letter.pdf"));
        var tab = f.Vm.ActiveDocument!;
        Pdfs.Retitle(tab.Session, "Unsaved edit");
        tab.Commit("Properties");
        DocumentTab? asked = null;
        f.Vm.SystemPrintRequested += (_, t) => asked = t;

        f.Vm.Print();

        string copy = Assert.Single(f.Sisters.Printed);
        Assert.Equal("letter.pdf", Path.GetFileName(copy));
        Assert.Equal("Unsaved edit", DocumentMetadata.Read(PdfDocument.Open(copy)).Title);
        Assert.Null(asked);
        Assert.Equal("Sent to Lazy Print.", f.Vm.StatusFull);
        Assert.True(File.Exists(copy));
    }

    [Fact]
    public async Task WithoutLazyPrintTheWindowIsAskedToPrintItself()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenAsync(f.Pdf());
        DocumentTab? asked = null;
        f.Vm.SystemPrintRequested += (_, t) => asked = t;

        f.Vm.Print();

        Assert.Same(f.Vm.ActiveDocument, asked);
        Assert.Single(f.Sisters.Printed);
        Assert.Empty(Directory.GetDirectories(f.Dir.Sub("print")));
    }

    [Fact]
    public async Task TheCopyForLazyPrintKeepsTheNameOfADocumentMadeFromAPicture()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenAsync(f.Dir.File("photo.png", [1, 2, 3]));

        f.Vm.Print();

        Assert.Equal("photo.pdf", Path.GetFileName(Assert.Single(f.Sisters.Printed)));
    }

    [Fact]
    public void OnTheHomeTabThereIsNothingToPrint()
    {
        using var f = new ViewModelFixture();

        f.Vm.Print();

        Assert.Empty(f.Sisters.Printed);
    }

    [Fact]
    public void ThePaginatorGivesOnePageForEachPageAtThePaperSize()
    {
        var paginator = new PagePaginator(new FakeRenderer(), 3) { PageSize = new Size(816, 1056) };

        var page = paginator.GetPage(1);

        Assert.Equal(3, paginator.PageCount);
        Assert.True(paginator.IsPageCountValid);
        Assert.Equal(new Size(816, 1056), page.Size);
        Assert.NotNull(page.Visual);
    }

    [Fact]
    public void APageTheRendererCannotDrawIsPrintedBlank()
    {
        var paginator = new PagePaginator(new FakeRenderer { Draws = false }, 1);

        var page = paginator.GetPage(0);

        Assert.Equal(paginator.PageSize, page.Size);
    }

    [Fact]
    public void APageIsDrawnToFitInsideThePaper()
    {
        var paginator = new PagePaginator(new FakeRenderer(), 1) { PageSize = new Size(100, 100) };

        var visual = (System.Windows.Media.DrawingVisual)paginator.GetPage(0).Visual;

        // The fake page is 200 by 300 points (267 by 400 DIPs): it is shrunk to 67 by 100 and centred.
        Assert.Equal(66.7, visual.ContentBounds.Width, 1);
        Assert.Equal(100, visual.ContentBounds.Height, 1);
        Assert.Equal(16.7, visual.ContentBounds.X, 1);
    }

    // Counts the pages it is asked to draw.
    private sealed class CountingRenderer : IDocumentRenderer
    {
        public List<int> Drawn { get; } = [];

        public bool Load(PdfEditSession session, string? password) => true;

        public (double Width, double Height) PageSize(int pageIndex) => (200, 300);

        public PdfRgbaImage? Render(int pageIndex, double dpi)
        {
            Drawn.Add(pageIndex);
            return new PdfRgbaImage(4, 6, Enumerable.Repeat((byte)255, 4 * 6 * 4).ToArray());
        }

        public void Dispose() { }
    }

    private static List<int> Drawn(PrintJob job)
    {
        var counter = (CountingRenderer)job.Renderer;
        var paginator = new PagePaginator(counter, job.PageCount, job.Sides);
        for (int i = 0; i < paginator.PageCount; i++) paginator.GetPage(i);
        return counter.Drawn;
    }

    [Fact]
    public async Task OddSidesOfATwoUpJobDrawTheFrontsOfTheSheets()
    {
        var source = PdfDocument.Open(Pdfs.Text(10));
        using var job = await PrintJob.Prepare(new PrintLayout(PerSheet: 2, Parity: PrintParity.Odd), source, new CountingRenderer(), 10, null, () => new CountingRenderer(), 612, 792);

        Assert.Equal(5, job.PageCount);
        Assert.Equal([0, 2, 4], Drawn(job));
    }

    [Fact]
    public async Task EvenSidesOfAnOddCountEndWithABlankThatIsDrawnNowhere()
    {
        var source = PdfDocument.Open(Pdfs.Text(5));
        using var job = await PrintJob.Prepare(new PrintLayout(PerSheet: 2, Parity: PrintParity.Even, Reverse: true), source, new CountingRenderer(), 5, null, () => new CountingRenderer(), 612, 792);

        Assert.Equal(3, job.PageCount);
        Assert.Equal([-1, 1], job.Sides);
        Assert.Equal([1], Drawn(job));
    }

    [Fact]
    public async Task APlainReverseJobDrawsThePagesBackwards()
    {
        var source = PdfDocument.Open(Pdfs.Text(3));
        using var job = await PrintJob.Prepare(new PrintLayout(Reverse: true), source, new CountingRenderer(), 3, [0, 1, 2], () => throw new InvalidOperationException(), 612, 792);

        Assert.Equal([2, 1, 0], Drawn(job));
    }

    [Fact]
    public async Task APlainJobWithNoRangeKeepsEveryPage()
    {
        var source = PdfDocument.Open(Pdfs.Text(3));
        using var job = await PrintJob.Prepare(new PrintLayout(), source, new CountingRenderer(), 3, null, () => throw new InvalidOperationException(), 612, 792);

        Assert.Null(job.Sides);
        Assert.False(job.IsEmpty);
    }

    [Fact]
    public async Task EvenOfASinglePageLeavesNothingToPrint()
    {
        var source = PdfDocument.Open(Pdfs.Text(1));
        using var job = await PrintJob.Prepare(new PrintLayout(Parity: PrintParity.Even), source, new CountingRenderer(), 1, null, () => throw new InvalidOperationException(), 612, 792);

        Assert.True(job.IsEmpty);
    }

    [Fact]
    public async Task SheetsTheRendererCannotOpenAreReportedAndReleased()
    {
        var source = PdfDocument.Open(Pdfs.Text(2));
        var sheets = new FakeRenderer { Draws = false };

        await Assert.ThrowsAsync<InvalidOperationException>(() => PrintJob.Prepare(new PrintLayout(PerSheet: 2), source, new CountingRenderer(), 2, null, () => sheets, 612, 792));

        Assert.True(sheets.Disposed);
    }

    [Fact]
    public void ABlankEntryIsAnEmptyPageAndIsNotCountedAsBlank()
    {
        var renderer = new CountingRenderer();
        var paginator = new PagePaginator(renderer, 3, [1, -1]);

        var page = paginator.GetPage(1);

        Assert.Equal(paginator.PageSize, page.Size);
        Assert.Empty(renderer.Drawn);
        Assert.Equal(0, paginator.Blank);
    }
}
