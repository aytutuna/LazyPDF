using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

// Resources are built from what the new content names, and everything a redacted page reached that nothing painted reaches is emptied.
public class RedactSweepTests
{
    private const string Pixels = "ZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATA123";
    private const string ImageEntries = "/Type /XObject /Subtype /Image /Width 8 /Height 8 /ColorSpace /DeviceGray /BitsPerComponent 8";
    private const string Place = "q 160 0 0 160 100 100 cm /Im1 Do Q";
    // The whole picture, so that no sample of it is left in the copy.
    private static readonly PdfRect Whole = new(90, 90, 270, 270);

    private static RedactionResult Cut(PdfDocument document) => new PdfRedactor(document).Apply([RedactionMark.FromRect(0, Whole)]);

    [Fact]
    public void ResourcesHoldOnlyWhatTheContentNames()
    {
        using var document = RedactionKit.Page("BT /F1 12 Tf 300 300 Td (kept) Tj ET " + Place, "/XObject <</Im1 7 0 R /Im2 8 0 R>> /ExtGState <</G 6 0 R>> /Foo <</X 8 0 R>> /ColorSpace <</DefaultRGB [/ICCBased 9 0 R] /Cs1 [/ICCBased 9 0 R]>> /ProcSet [/PDF /Text]", pdf =>
        {
            pdf.Obj(6, "<</Type /ExtGState /CA 0.5>>");
            pdf.Stream(7, ImageEntries, Pixels);
            pdf.Stream(8, ImageEntries, Pixels.Replace("PIXELS", "OTHERS"));
            pdf.Stream(9, "/N 3", "ZQXPROFILE");
        });
        var result = Cut(document);
        using var output = RedactionKit.Open(result);
        var resources = output.Dict(output.Pages[0].Dictionary, "Resources")!;
        Assert.Equal(["ColorSpace", "Font", "ProcSet", "XObject"], resources.Entries.Select(e => e.Key).Order());
        Assert.Equal(["F1"], output.Dict(resources, "Font")!.Entries.Select(e => e.Key));
        Assert.Equal(["DefaultRGB"], output.Dict(resources, "ColorSpace")!.Entries.Select(e => e.Key));
        Assert.Single(output.Dict(resources, "XObject")!.Entries);
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXOTHERS"));
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXPIXELSDATA"));
    }

    [Fact]
    public void CopiedFormHoldsOnlyWhatItsNewContentNames()
    {
        using var document = RedactionKit.Page("/Fm Do", "/XObject <</Fm 6 0 R /Im1 7 0 R>>", pdf =>
        {
            pdf.Stream(6, "/Type /XObject /Subtype /Form /BBox [0 0 600 800] /Resources <</Font <</F1 5 0 R>> /XObject <</Im1 7 0 R>>>>", "BT /F1 12 Tf 100 100 Td (ZQXWORD) Tj ET");
            pdf.Stream(7, ImageEntries, Pixels);
        });
        var result = new PdfRedactor(document).Apply([RedactionMark.FromRect(0, new PdfRect(90, 90, 200, 120))]);
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXWORD"));
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXPIXELSDATA"));
    }

    [Fact]
    public void KeysOfThePageAndAStructureElementCannotKeepTheCutPictureAlive()
    {
        using var document = RedactionKit.Page(Place, "/XObject <</Im1 6 0 R>>", pdf => pdf.Stream(6, ImageEntries, Pixels));
        document.Pages[0].Dictionary["Thumb"] = new PdfReference(6, 0);
        document.Pages[0].Dictionary["Keep"] = new PdfArray([new PdfDictionary { ["Deep"] = new PdfReference(6, 0) }]);
        var root = new PdfDictionary { ["Type"] = new PdfName("StructTreeRoot"), ["K"] = new PdfReference(6, 0) };
        document.Catalog["StructTreeRoot"] = document.Add(root);
        var result = Cut(document);
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXPIXELSDATA"));
        using var output = RedactionKit.Open(result);
        Assert.Single(output.Pages);
    }

    [Fact]
    public void HolderNestedDeepInArraysCannotKeepTheCutPictureAlive()
    {
        using var document = RedactionKit.Page(Place, "/XObject <</Im1 6 0 R>>", pdf => pdf.Stream(6, ImageEntries, Pixels));
        PdfObject held = new PdfReference(6, 0);
        for (int i = 0; i < 150; i++) held = new PdfArray([held]);
        document.Pages[0].Dictionary["Keep"] = held;
        var result = Cut(document);
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXPIXELSDATA"));
    }

    [Fact]
    public void AttachedFileOfThePageGoesWithIt()
    {
        using var document = RedactionKit.Page("BT /F1 12 Tf 100 100 Td (ZQXWORD) Tj ET", "", pdf => pdf.Stream(6, "/Type /EmbeddedFile", "ZQXSOURCEFILE"));
        document.Pages[0].Dictionary["AF"] = new PdfArray([new PdfDictionary { ["Type"] = new PdfName("Filespec"), ["EF"] = new PdfDictionary { ["F"] = new PdfReference(6, 0) } }]);
        var result = new PdfRedactor(document).Apply(RedactionKit.MarksOf(document, 0, "ZQXWORD"));
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXSOURCEFILE"));
    }

    [Fact]
    public void StreamOfAnObjectThatIsNotPaintedBecomesEmptyWhoeverNamesIt()
    {
        using var document = RedactionKit.Page(Place, "/XObject <</Im1 6 0 R>>", pdf => pdf.Stream(6, ImageEntries, Pixels));
        document.Catalog["Anywhere"] = new PdfReference(6, 0);
        var result = Cut(document);
        using var output = RedactionKit.Reopen(result.Bytes);
        var held = Assert.IsType<PdfStream>(output.Resolve(output.Catalog["Anywhere"]));
        Assert.Empty(output.Data(held));
        Assert.All(held.Dictionary.Entries, e => Assert.Equal("Length", e.Key));
    }

    [Fact]
    public void PageTreeAndPagesAreNeverEmptiedThroughADestination()
    {
        using var document = RedactionKit.Page("BT /F1 12 Tf 100 100 Td (ZQXWORD) Tj ET");
        var link = new PdfAnnotationWriter(document).AddLink(document.Pages[0], new PdfRect(300, 300, 400, 320), new UriAction("https://example.com"));
        link.Dictionary["Dest"] = new PdfArray([document.Pages[0].Reference, new PdfName("Fit")]);
        var result = new PdfRedactor(document).Apply(RedactionKit.MarksOf(document, 0, "ZQXWORD"));
        using var output = RedactionKit.Open(result);
        Assert.Single(output.Pages);
        Assert.Equal("Page", output.Name(output.Pages[0].Dictionary, "Type"));
        Assert.Single(PdfAnnotations.Read(output, output.Pages[0]));
    }

    [Fact]
    public void ObjectPaintedByAPageWithoutMarksStaysAndOneItOnlyListsGoes()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R] /Count 2 /MediaBox [0 0 600 800] /Resources 8 0 R>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Contents 5 0 R>>");
        pdf.Obj(4, "<</Type /Page /Parent 2 0 R /Contents 6 0 R>>");
        pdf.Stream(5, "", Place);
        pdf.Stream(6, "", "q 100 0 0 100 300 300 cm /Im2 Do Q");
        pdf.Obj(8, "<</XObject <</Im1 9 0 R /Im2 10 0 R>>>>");
        pdf.Stream(9, ImageEntries, Pixels);
        pdf.Stream(10, ImageEntries, Pixels.Replace("PIXELS", "KEPT"));
        using var document = PdfDocument.Open(pdf.Finish());
        var result = Cut(document);
        using var output = RedactionKit.Open(result);
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXPIXELSDATA"));
        Assert.True(RedactionKit.Holds(result.Bytes, "ZQXKEPTDATA"));
        Assert.Single(RedactionKit.Images(output, 1));
    }
}
