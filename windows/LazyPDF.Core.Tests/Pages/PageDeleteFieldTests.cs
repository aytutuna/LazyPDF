using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class PageDeleteFieldTests
{
    // Field a is a widget on page 1; field b has widgets on pages 2 and 3; field c is a tree, group.c, with a widget on page 4.
    private static PdfDocument Open()
    {
        int n = PageTestFiles.Free(4);
        return PageTestFiles.Open(4,
            catalogExtra: $"/AcroForm <</Fields [{n} 0 R {n + 1} 0 R {n + 4} 0 R] /CO [{n} 0 R {n + 1} 0 R]>>",
            pageExtra: i => i switch
            {
                0 => $"/Annots [{n} 0 R]",
                1 => $"/Annots [{n + 2} 0 R]",
                2 => $"/Annots [{n + 3} 0 R]",
                _ => $"/Annots [{n + 6} 0 R]",
            },
            add: pdf =>
            {
                pdf.Obj(n, "<</Type /Annot /Subtype /Widget /FT /Tx /T (a) /V (x) /Rect [0 0 10 10]>>");
                pdf.Obj(n + 1, $"<</FT /Tx /T (b) /V (y) /Kids [{n + 2} 0 R {n + 3} 0 R]>>");
                pdf.Obj(n + 2, $"<</Type /Annot /Subtype /Widget /Parent {n + 1} 0 R /Rect [0 0 10 10]>>");
                pdf.Obj(n + 3, $"<</Type /Annot /Subtype /Widget /Parent {n + 1} 0 R /Rect [0 0 10 10]>>");
                pdf.Obj(n + 4, $"<</T (group) /Kids [{n + 5} 0 R]>>");
                pdf.Obj(n + 5, $"<</T (c) /Parent {n + 4} 0 R /FT /Tx /Kids [{n + 6} 0 R]>>");
                pdf.Obj(n + 6, $"<</Type /Annot /Subtype /Widget /Parent {n + 5} 0 R /Rect [0 0 10 10]>>");
            });
    }

    private static List<int> Fields(PdfDocument document) =>
        [.. document.Array(document.Dict(document.Catalog, "AcroForm"), "Fields")!.Items.Cast<PdfReference>().Select(r => r.Number - PageTestFiles.Free(4))];

    [Fact]
    public void AFieldWhoseOnlyWidgetIsOnADeletedPageLeavesTheForm()
    {
        var document = Open();
        PageOperations.Delete(document, [0]);
        Assert.Equal([1, 4], Fields(document));
        var order = document.Array(document.Dict(document.Catalog, "AcroForm"), "CO")!;
        Assert.Single(order.Items);
    }

    [Fact]
    public void AFieldWithAWidgetLeftStaysWithThatWidgetOnly()
    {
        var document = Open();
        int n = PageTestFiles.Free(4);
        PageOperations.Delete(document, [1]);
        Assert.Equal([0, 1, 4], Fields(document));
        var kids = document.Array((PdfDictionary)document.Get(n + 1)!, "Kids")!;
        Assert.Equal([new PdfReference(n + 3, 0)], kids.Items);
    }

    [Fact]
    public void AFieldGoesWhenItsLastWidgetDoes()
    {
        var document = Open();
        PageOperations.Delete(document, [1, 2]);
        Assert.Equal([0, 4], Fields(document));
    }

    [Fact]
    public void ATreeOfFieldsGoesFromTheLeafUp()
    {
        var document = Open();
        int n = PageTestFiles.Free(4);
        PageOperations.Delete(document, [3]);
        Assert.Equal([0, 1], Fields(document));
        Assert.Empty(document.Array((PdfDictionary)document.Get(n + 4)!, "Kids")!.Items);
    }

    [Fact]
    public void TheFormReadsBackWithOnlyTheFieldsOnTheRemainingPages()
    {
        var document = Open();
        PageOperations.Delete(document, [0, 3]);
        var again = PdfDocument.Open(document.SaveRewrite());
        var form = again.Dict(again.Catalog, "AcroForm")!;
        Assert.Single(again.Array(form, "Fields")!.Items);
        Assert.Empty(again.Repairs);
    }
}
