using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

internal static class StructureFixtures
{
    public static PdfDocument Open(int pages = 3) => PdfDocument.Open(TestPdf.Simple(pages));

    /// <summary>
    /// A file with <paramref name="pages"/> pages (objects 3 and up, 200 by 300 points) and a catalog
    /// that carries <paramref name="catalog"/>; <paramref name="more"/> adds objects from number 20.
    /// </summary>
    public static PdfDocument File(string catalog, Action<TestPdf>? more = null, int pages = 3, string pageEntries = "")
    {
        var pdf = new TestPdf();
        pdf.Obj(1, $"<</Type /Catalog /Pages 2 0 R {catalog}>>");
        var kids = string.Join(" ", Enumerable.Range(0, pages).Select(i => $"{3 + i} 0 R"));
        pdf.Obj(2, $"<</Type /Pages /Kids [{kids}] /Count {pages} /MediaBox [0 0 200 300]>>");
        for (int i = 0; i < pages; i++) pdf.Obj(3 + i, $"<</Type /Page /Parent 2 0 R {pageEntries}>>");
        more?.Invoke(pdf);
        return PdfDocument.Open(pdf.Finish());
    }

    /// <summary>
    /// The document written both ways and read again: PdfPig must open each, and the document read
    /// from the update is returned (the rewrite is read too, so both are exercised).
    /// </summary>
    public static PdfDocument Reopen(PdfDocument document)
    {
        var rewritten = document.SaveRewrite();
        using (var pig = UglyToad.PdfPig.PdfDocument.Open(rewritten)) Assert.Equal(document.Pages.Count, pig.NumberOfPages);
        Assert.Empty(PdfDocument.Open(rewritten).Repairs);

        var updated = document.SaveIncremental();
        using (var pig = UglyToad.PdfPig.PdfDocument.Open(updated)) Assert.Equal(document.Pages.Count, pig.NumberOfPages);
        var reopened = PdfDocument.Open(updated);
        Assert.Empty(reopened.Repairs);
        return reopened;
    }

    /// <summary>The document rewritten and read again.</summary>
    public static PdfDocument Rewritten(PdfDocument document) => PdfDocument.Open(document.SaveRewrite());

    public static PdfDestination ToPage(int index) => new(index, DestinationFit.Xyz, 10, Top: 250);
}
