using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class PageInsertTests
{
    [Fact]
    public void BlankPagesHaveTheSizeAndNoContent()
    {
        var document = PageTestFiles.Open(2, rootExtra: "/Rotate 90");
        PageOperations.InsertBlank(document, 1, 595, 842, 2);
        Assert.Equal(4, document.Pages.Count);
        var blank = document.Pages[1];
        Assert.Equal(new PdfRect(0, 0, 595, 842), blank.MediaBox);
        Assert.Equal(0, blank.Rotate);
        Assert.Empty(blank.Contents());
        Assert.Equal(blank.MediaBox, document.Pages[2].MediaBox);
        PageTestFiles.Reopen(document);
    }

    [Fact]
    public void BlankPagesGoWhereAsked()
    {
        var document = PageTestFiles.Open(2);
        PageOperations.InsertBlank(document, 0, 100, 100);
        PageOperations.InsertBlank(document, 3, 100, 100);
        Assert.Equal(4, document.Pages.Count);
        Assert.Equal([100, 200, 200, 100], document.Pages.Select(p => (int)p.MediaBox.Width));
        Assert.Throws<ArgumentOutOfRangeException>(() => PageOperations.InsertBlank(document, 5, 100, 100));
        Assert.Throws<ArgumentOutOfRangeException>(() => PageOperations.InsertBlank(document, 0, 0, 100));
        Assert.Throws<ArgumentOutOfRangeException>(() => PageOperations.InsertBlank(document, 0, 100, 100, 0));
    }

    [Fact]
    public void ADuplicateFollowsItsOriginalAndSharesTheContent()
    {
        var document = PageTestFiles.Open(3);
        PageOperations.Duplicate(document, [0, 2]);
        Assert.Equal([1, 1, 2, 3, 3], PageTestFiles.Order(document));
        var pages = document.Pages;
        Assert.NotEqual(pages[0].Reference, pages[1].Reference);
        Assert.Equal(pages[0].Dictionary["Contents"]!.ToString(), pages[1].Dictionary["Contents"]!.ToString());
        Assert.Equal(["Page 1", "Page 1", "Page 2", "Page 3", "Page 3"], PageTestFiles.Reopen(document));
    }

    [Fact]
    public void ADuplicateCopiesItsAnnotationsAndLeavesThePopupWithItsOwner()
    {
        var document = PageTestFiles.Open(1,
            pageExtra: _ => $"/Annots [{PageTestFiles.Free(1)} 0 R {PageTestFiles.Free(1) + 1} 0 R]",
            add: pdf =>
            {
                int n = PageTestFiles.Free(1);
                pdf.Obj(n, $"<</Type /Annot /Subtype /Text /Rect [10 10 30 30] /Contents (note) /Popup {n + 1} 0 R /P {PageTestFiles.PageObject(0)} 0 R>>");
                pdf.Obj(n + 1, $"<</Type /Annot /Subtype /Popup /Rect [40 40 100 100] /Parent {n} 0 R>>");
            });
        PageOperations.Duplicate(document, [0]);
        var first = document.Array(document.Pages[0].Dictionary, "Annots")!.Items.Cast<PdfReference>().ToList();
        var second = document.Array(document.Pages[1].Dictionary, "Annots")!.Items.Cast<PdfReference>().ToList();
        Assert.Empty(first.Intersect(second));
        var text = (PdfDictionary)document.Resolve(second[0])!;
        Assert.Equal("note", System.Text.Encoding.Latin1.GetString(((PdfString)text["Contents"]!).Bytes));
        Assert.Equal(second[1], text["Popup"]);
        Assert.Equal(document.Pages[1].Reference, text["P"]);
        var popup = (PdfDictionary)document.Resolve(second[1])!;
        Assert.Equal(second[0], popup["Parent"]);
    }

    [Fact]
    public void PageLabelsMakeRoomForInsertedPages()
    {
        var document = PageTestFiles.Open(4, catalogExtra: "/PageLabels <</Nums [0 <</S /r>> 2 <</S /D>>]>>");
        PageOperations.InsertBlank(document, 2, 100, 100);
        var nums = document.Array(document.Dict(document.Catalog, "PageLabels"), "Nums")!.Items;
        Assert.Equal([0L, 3L], new[] { 0, 2 }.Select(i => ((PdfNumber)nums[i]).Integer!.Value));
    }

    [Fact]
    public void InsertingAtTheStartKeepsAFirstLabelRange()
    {
        var document = PageTestFiles.Open(2, catalogExtra: "/PageLabels <</Nums [0 <</S /D>>]>>");
        PageOperations.InsertBlank(document, 0, 100, 100);
        var nums = document.Array(document.Dict(document.Catalog, "PageLabels"), "Nums")!.Items;
        Assert.Equal(0L, ((PdfNumber)nums[0]).Integer);
        Assert.Equal(1L, ((PdfNumber)nums[2]).Integer);
    }
}
