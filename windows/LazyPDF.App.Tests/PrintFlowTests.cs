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
}
