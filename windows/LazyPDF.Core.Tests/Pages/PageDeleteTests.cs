using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class PageDeleteTests
{
    [Fact]
    public void DeletedPagesAreGoneAndTheRestKeepsItsOrder()
    {
        var document = PageTestFiles.Open(5);
        PageOperations.Delete(document, [1, 3]);
        Assert.Equal([1, 3, 5], PageTestFiles.Order(document));
        Assert.Equal(["Page 1", "Page 3", "Page 5"], PageTestFiles.Reopen(document));
        Assert.Equal(3, document.Integer(document.Dict(document.Catalog, "Pages"), "Count"));
    }

    [Fact]
    public void TheObjectsOfDeletedPagesAreFreed()
    {
        var document = PageTestFiles.Open(3);
        PageOperations.Delete(document, [0]);
        Assert.Null(document.Get(PageTestFiles.PageObject(0)));
        Assert.NotNull(document.Get(PageTestFiles.PageObject(1)));
    }

    [Fact]
    public void ARepeatedIndexDeletesOnePage()
    {
        var document = PageTestFiles.Open(3);
        PageOperations.Delete(document, [1, 1]);
        Assert.Equal([1, 3], PageTestFiles.Order(document));
    }

    [Fact]
    public void NoPagesAtAllIsNotADocument()
    {
        var document = PageTestFiles.Open(2);
        Assert.Throws<ArgumentException>(() => PageOperations.Delete(document, [0, 1]));
        Assert.Equal(2, document.Pages.Count);
    }

    [Fact]
    public void DeletingNothingChangesNothing()
    {
        var session = PdfEditSession.Open(PageTestFiles.Make(2));
        PageOperations.Delete(session.Document, []);
        Assert.False(session.Commit("Delete"));
    }

    [Fact]
    public void ADeleteIsOneUndoStep()
    {
        var session = PdfEditSession.Open(PageTestFiles.Make(4));
        PageOperations.Delete(session.Document, [0, 2]);
        var reopened = PageTestFiles.Commit(session, "Delete pages");
        Assert.Equal([2, 4], PageTestFiles.Order(reopened));
        Assert.True(session.Undo());
        Assert.Equal([1, 2, 3, 4], PageTestFiles.Order(session.Document));
        Assert.True(session.Redo());
        Assert.Equal([2, 4], PageTestFiles.Order(session.Document));
    }

    [Fact]
    public void PagesInANestedTreeAreDeletedFromTheirNodes()
    {
        var pdf = new TestPdf()
            .Obj(1, "<</Type /Catalog /Pages 2 0 R>>")
            .Obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R] /Count 3 /MediaBox [0 0 100 100]>>")
            .Obj(3, "<</Type /Pages /Parent 2 0 R /Kids [5 0 R 6 0 R] /Count 2 /Rotate 90>>")
            .Obj(4, "<</Type /Pages /Parent 2 0 R /Kids [7 0 R] /Count 1>>")
            .Obj(5, "<</Type /Page /Parent 3 0 R /Contents 8 0 R>>")
            .Obj(6, "<</Type /Page /Parent 3 0 R /Contents 9 0 R>>")
            .Obj(7, "<</Type /Page /Parent 4 0 R /Contents 10 0 R>>")
            .Stream(8, "", "(Page 1)").Stream(9, "", "(Page 2)").Stream(10, "", "(Page 3)");
        var document = PdfDocument.Open(pdf.Finish());
        PageOperations.Delete(document, [0]);
        var again = PdfDocument.Open(document.SaveRewrite());
        Assert.Equal([2, 3], PageTestFiles.Order(again));
        Assert.Equal([90, 0], again.Pages.Select(p => p.Rotate));
        Assert.Empty(again.Repairs);
    }
}
