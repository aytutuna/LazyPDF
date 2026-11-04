using System.Text;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class LinearizerTests
{
    [Theory]
    [InlineData(1)]
    [InlineData(2)]
    [InlineData(5)]
    [InlineData(40)]
    public void LayoutAndHintTablesDescribeTheFile(int pages)
    {
        var source = PdfDocument.Open(LinearizerKit.Make(pages));
        byte[] file = LinearizerKit.Keep($"basic-{pages}", source.SaveLinearized());

        var parameters = LinearizerKit.Verify(file);
        Assert.Equal(pages, parameters["N"]);
    }

    [Fact]
    public void TextAndPagesSurvive()
    {
        var source = PdfDocument.Open(LinearizerKit.Make(7));
        byte[] file = source.SaveLinearized();

        using var again = PdfDocument.Open(file);
        Assert.Equal(7, again.Pages.Count);
        for (int i = 0; i < 7; i++) Assert.Equal(source.Pages[i].Contents(), again.Pages[i].Contents());
        Assert.Equal(LinearizerKit.PigText(source), LinearizerKit.PigText(file));
        Assert.Equal("Linearizer test", Encoding.Latin1.GetString(((PdfString)again.Info!["Title"]!).Bytes));
        Assert.Equal(source.Id[0], again.Id[0]);
    }

    [Fact]
    public void InheritedAttributesMoveOntoThePages()
    {
        var source = PdfDocument.Open(LinearizerKit.Make(4));
        using var again = PdfDocument.Open(source.SaveLinearized());

        Assert.False(again.Dict(again.Catalog, "Pages")!.ContainsKey("Resources"));
        Assert.False(again.Dict(again.Catalog, "Pages")!.ContainsKey("MediaBox"));
        foreach (var page in again.Pages)
        {
            Assert.True(page.Dictionary.ContainsKey("Resources"));
            Assert.True(page.Dictionary.ContainsKey("MediaBox"));
            Assert.Equal(200, page.MediaBox.Width);
        }
        // One resources object serves the pages that had none of their own.
        Assert.Equal(again.Pages[0].Dictionary["Resources"], again.Pages[2].Dictionary["Resources"]);
    }

    [Fact]
    public void ADirectInheritedDictionaryBecomesOneSharedObject()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R 5 0 R] /Count 3 /MediaBox [0 0 90 90] /Resources <</Font <</F1 6 0 R>>>>>>");
        for (int i = 0; i < 3; i++) pdf.Obj(3 + i, $"<</Type /Page /Parent 2 0 R /Contents {7 + i} 0 R>>");
        pdf.Obj(6, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>");
        for (int i = 0; i < 3; i++) pdf.Stream(7 + i, "", $"BT /F1 12 Tf 10 10 Td (Sheet {i}) Tj ET");
        byte[] file = PdfDocument.Open(pdf.Finish()).SaveLinearized();

        LinearizerKit.Verify(file);
        using var again = PdfDocument.Open(file);
        var resources = again.Pages.Select(p => p.Dictionary["Resources"]).ToList();
        Assert.All(resources, r => Assert.IsType<PdfReference>(r));
        Assert.Single(resources.Distinct());
        Assert.Contains("Sheet 2", LinearizerKit.PigText(file));
    }

    [Fact]
    public void AnObjectOnlyTheFirstPageUsesStaysInItsSection()
    {
        byte[] file = PdfDocument.Open(LinearizerKit.Make(5)).SaveLinearized();
        var parameters = LinearizerKit.Verify(file);

        using var document = PdfDocument.Open(file);
        // Page 1 has no font of its own; the shared font and form are in the first section because page 1 uses them.
        string text = Encoding.Latin1.GetString(file);
        long courier = text.IndexOf("/Courier", StringComparison.Ordinal);
        Assert.True(courier > parameters["E"], "a font of page 2 is behind the first page");
        long helvetica = text.IndexOf("/Helvetica", StringComparison.Ordinal);
        Assert.InRange(helvetica, 1, parameters["E"]);
    }

    [Fact]
    public void ALinkToAnotherPageDoesNotPullItIn()
    {
        var source = PdfDocument.Open(LinearizerKit.Make(6));
        byte[] file = source.SaveLinearized();
        using var document = PdfDocument.Open(file);

        // Page 3 (index 2) holds no object of page 4, whose link it carries.
        var reach = LinearizerKit.Reach(document, document.Pages[2].Reference.Number);
        Assert.DoesNotContain(document.Pages[3].Reference.Number, reach);
        LinearizerKit.Verify(file);
    }

    [Fact]
    public void TheBookmarksJoinTheFirstPageWhenTheFileOpensOnThem()
    {
        byte[] file = PdfDocument.Open(LinearizerKit.Make(3)).SaveLinearized();
        var parameters = LinearizerKit.Verify(file);
        using var document = PdfDocument.Open(file);

        int outlines = ((PdfReference)document.Catalog["Outlines"]!).Number;
        string text = Encoding.Latin1.GetString(file);
        long at = text.IndexOf($"\n{outlines} 0 obj\n", StringComparison.Ordinal) + 1;
        Assert.InRange(at, parameters["H0"], parameters["E"]);
        Assert.Contains("/O ", Encoding.Latin1.GetString(file, (int)parameters["H0"], 40));
    }

    [Fact]
    public void ALinearizedFileCanBeLinearizedAgain()
    {
        byte[] once = PdfDocument.Open(LinearizerKit.Make(6)).SaveLinearized();
        byte[] twice = PdfDocument.Open(once).SaveLinearized();

        LinearizerKit.Verify(twice);
        Assert.Equal(LinearizerKit.PigText(once), LinearizerKit.PigText(twice));
    }

    [Fact]
    public void ADocumentWithoutPagesIsRefused()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [] /Count 0>>");
        var document = PdfDocument.Open(pdf.Finish());

        Assert.Throws<InvalidOperationException>(() => document.SaveLinearized());
    }

    [Fact]
    public void TheHeaderVersionIsRaisedToWhatLinearizationNeeds()
    {
        byte[] file = PdfDocument.Open(LinearizerKit.Make(2, "%PDF-1.0\n")).SaveLinearized();

        Assert.StartsWith("%PDF-1.2\n", Encoding.Latin1.GetString(file));
    }
}
