using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class PageOrderTests
{
    [Fact]
    public void ReorderPutsThePageAtTheOldIndexFirst()
    {
        var document = PageTestFiles.Open(4);
        PageOperations.Reorder(document, [3, 0, 2, 1]);
        Assert.Equal([4, 1, 3, 2], PageTestFiles.Order(document));
        Assert.Equal([4, 1, 3, 2], PageTestFiles.Order(PdfDocument.Open(document.SaveRewrite())));
    }

    [Theory]
    [InlineData(new[] { 0, 1 })]
    [InlineData(new[] { 0, 0, 1 })]
    [InlineData(new[] { 0, 1, 5 })]
    public void AnOrderThatIsNotAPermutationIsRefused(int[] order)
    {
        var document = PageTestFiles.Open(3);
        Assert.Throws<ArgumentException>(() => PageOperations.Reorder(document, order));
        Assert.Equal([1, 2, 3], PageTestFiles.Order(document));
    }

    [Fact]
    public void TheIdentityOrderChangesNothing()
    {
        var session = PdfEditSession.Open(PageTestFiles.Make(3));
        PageOperations.Reorder(session.Document, [0, 1, 2]);
        Assert.False(session.Commit("Reorder"));
    }

    [Theory]
    [InlineData(new[] { 3 }, 0, new[] { 4, 1, 2, 3, 5 })]
    [InlineData(new[] { 0 }, 5, new[] { 2, 3, 4, 5, 1 })]
    [InlineData(new[] { 0 }, 3, new[] { 2, 3, 1, 4, 5 })]
    [InlineData(new[] { 1, 2 }, 5, new[] { 1, 4, 5, 2, 3 })]
    [InlineData(new[] { 4, 3 }, 1, new[] { 1, 4, 5, 2, 3 })]
    [InlineData(new[] { 2 }, 2, new[] { 1, 2, 3, 4, 5 })]
    public void MoveKeepsTheMovedPagesInTheirOwnOrder(int[] pages, int before, int[] expected)
    {
        var document = PageTestFiles.Open(5);
        PageOperations.Move(document, pages, before);
        Assert.Equal(expected, PageTestFiles.Order(document));
    }

    [Fact]
    public void MovingBeyondTheEndIsRefused()
    {
        var document = PageTestFiles.Open(3);
        Assert.Throws<ArgumentOutOfRangeException>(() => PageOperations.Move(document, [0], 4));
        Assert.Throws<ArgumentOutOfRangeException>(() => PageOperations.Move(document, [0], -1));
    }

    [Fact]
    public void PagesTakeWhatTheirOldNodesGaveBeforeTheyMove()
    {
        var pdf = new TestPdf()
            .Obj(1, "<</Type /Catalog /Pages 2 0 R>>")
            .Obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R] /Count 2 /MediaBox [0 0 100 100]>>")
            .Obj(3, "<</Type /Pages /Parent 2 0 R /Kids [5 0 R] /Count 1 /Rotate 90 /Resources <</Font <<>>>>>>")
            .Obj(4, "<</Type /Pages /Parent 2 0 R /Kids [6 0 R] /Count 1 /CropBox [0 0 50 50]>>")
            .Obj(5, "<</Type /Page /Parent 3 0 R>>")
            .Obj(6, "<</Type /Page /Parent 4 0 R>>");
        var document = PdfDocument.Open(pdf.Finish());
        PageOperations.Reorder(document, [1, 0]);
        var again = PdfDocument.Open(document.SaveRewrite());
        Assert.Equal([0, 90], again.Pages.Select(p => p.Rotate));
        Assert.Equal(new PdfRect(0, 0, 50, 50), again.Pages[0].CropBox);
        Assert.NotNull(again.Pages[1].Resources);
        Assert.Equal(new PdfRect(0, 0, 100, 100), again.Pages[0].MediaBox);
    }

    [Fact]
    public void ABigTreeIsLaidOutEvenAndEveryPageNamesItsNode()
    {
        var document = PageTestFiles.Open(1100);
        PageOperations.Reorder(document, [.. Enumerable.Range(0, 1100).Reverse()]);
        var root = document.Dict(document.Catalog, "Pages")!;
        Assert.True(document.Array(root, "Kids")!.Items.Count <= 32);
        Assert.Equal(1100, document.Integer(root, "Count"));
        int deepest = 0;
        foreach (var page in document.Pages)
        {
            int depth = 0;
            for (var node = document.Dict(page.Dictionary, "Parent"); node is not null; node = document.Dict(node, "Parent"))
            {
                depth++;
                Assert.True(document.Array(node, "Kids")!.Items.Count <= 32);
            }
            deepest = Math.Max(deepest, depth);
        }
        Assert.Equal(3, deepest);
        Assert.Equal(Enumerable.Range(1, 1100).Reverse(), PageTestFiles.Order(document));
        Assert.Equal(1100, PdfDocument.Open(document.SaveRewrite()).Pages.Count);
    }

    [Fact]
    public void AnEditNearTheEndOfABigFileRewritesFewObjects()
    {
        var session = PdfEditSession.Open(PdfDocument.Open(PageTestFiles.Make(1100)).SaveRewrite());
        PageOperations.Reorder(session.Document, [.. Enumerable.Range(0, 1100).Reverse()]);
        session.Commit("Reverse");
        int before = session.Current.Length;
        var document = session.Document;
        PageOperations.Delete(document, [1099]);
        Assert.True(session.Commit("Delete"));
        Assert.True(session.Current.Length - before < 40_000, $"{session.Current.Length - before} bytes");
        Assert.Equal(1099, session.Document.Pages.Count);
    }

    [Fact]
    public void ARepairedTreeIsLaidOutAgainWhateverWasWrongWithIt()
    {
        var pdf = new TestPdf()
            .Obj(1, "<</Type /Catalog /Pages 2 0 R>>")
            .Obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R 2 0 R 99 0 R] /Count 7 /MediaBox [0 0 100 100]>>")
            .Obj(3, "<</Type /Page /Contents 5 0 R>>")
            .Obj(4, "<</Type /Page /Parent 77 0 R /Contents 6 0 R>>")
            .Stream(5, "", "BT (Page 1) Tj ET")
            .Stream(6, "", "BT (Page 2) Tj ET");
        var document = PdfDocument.Open(pdf.Finish());
        PageOperations.Reorder(document, [1, 0]);
        var again = PdfDocument.Open(document.SaveRewrite());
        Assert.Equal([2, 1], PageTestFiles.Order(again));
        Assert.Equal(2, again.Integer(again.Dict(again.Catalog, "Pages"), "Count"));
    }
}
