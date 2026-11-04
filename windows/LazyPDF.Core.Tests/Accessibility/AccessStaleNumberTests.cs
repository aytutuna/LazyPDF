using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class AccessStaleNumberTests
{
    private const string Old = "/P <</MCID {0}>> BDC BT /F1 11 Tf 72 700 Td (Old) Tj ET EMC\n";

    [Fact]
    public void AFarOffStaleNumberOnEveryPageDoesNotStopTheTagging()
    {
        using var document = PdfDocument.Open(AccessKit.Build(5, _ => string.Format(Old, 999999) + AccessKit.Text(72, 500, "New words")));

        var result = AutoTagger.Tag(document);

        Assert.Equal(5, result.Pages);
        using var again = AccessKit.Reopen(document, rewrite: true);
        var tree = StructureTree.Read(again)!;
        Assert.All(tree.Contents, c => Assert.True(c.Mcid < 100));
    }

    [Fact]
    public void AStaleNumberAtTheLimitDoesNotPushTheNewOnesOutOfTheTree()
    {
        using var document = PdfDocument.Open(AccessKit.Build(1, _ => string.Format(Old, 1_000_000) + AccessKit.Text(72, 500, "New words")));

        AutoTagger.Tag(document);

        using var again = AccessKit.Reopen(document, rewrite: true);
        Assert.Contains("New words", ReadingOrder.Export(again));
    }

    [Fact]
    public void ThePageThatOnlyDrawsArtifactsDoesNotKeepTheKeyOfATaggedPage()
    {
        string[] contents = [AccessKit.Text(72, 700, "Words") + AccessKit.Text(72, 600, "More words"), "/Figure <</MCID 0>> BDC 0 0 10 10 re f EMC\n"];
        using var document = PdfDocument.Open(AccessKit.Build(2, i => contents[i], pageEntries: "/StructParents 0"));

        AutoTagger.Tag(document);

        using var again = AccessKit.Reopen(document, rewrite: true);
        var tree = StructureTree.Read(again)!;
        long? first = again.Integer(again.Pages[0].Dictionary, "StructParents");
        Assert.NotEqual(first, again.Integer(again.Pages[1].Dictionary, "StructParents"));
        Assert.All(tree.Contents, c => Assert.Equal(0, c.PageIndex));
    }

    [Fact]
    public void TheKeyOfAnUntaggedPageIsNotHandedToAnotherOwner()
    {
        string[] contents = [AccessKit.Text(72, 700, "Words") + AccessKit.Text(72, 600, "More words"), "0 0 10 10 re f\n", AccessKit.Text(72, 700, "Third") + AccessKit.Text(72, 600, "More")];
        using var document = PdfDocument.Open(AccessKit.Build(3, i => contents[i], pageEntries: "/StructParents 1"));

        AutoTagger.Tag(document);

        var keys = document.Pages.Select(p => document.Integer(p.Dictionary, "StructParents")).Where(k => k is not null).ToList();
        Assert.Equal(keys.Count, keys.Distinct().Count());
    }

    private static byte[] Tagged(string page, string form)
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R /StructTreeRoot 6 0 R /MarkInfo <</Marked true>> /Lang (en-US)>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 612 792]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Resources <</Font <</F1 5 0 R>> /XObject <</Fm1 10 0 R>>>>>>");
        pdf.Stream(4, "", page);
        pdf.Obj(5, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding>>");
        pdf.Obj(6, "<</Type /StructTreeRoot /K 7 0 R>>");
        pdf.Obj(7, "<</Type /StructElem /S /Document /P 6 0 R /K 8 0 R>>");
        pdf.Obj(8, "<</Type /StructElem /S /P /P 7 0 R /Pg 3 0 R /K 2>>");
        pdf.Stream(10, "/Type /XObject /Subtype /Form /BBox [0 0 612 792] /Resources <</Font <</F1 5 0 R>>>>", form);
        return pdf.Finish();
    }

    [Fact]
    public void TextOfAFormBelongsToTheSequenceAroundItsDrawingWhenTheFormNumbersThatNumberElsewhere()
    {
        var file = Tagged("/P <</MCID 2>> BDC /Fm1 Do EMC", "BT /F1 11 Tf 72 700 Td (Plain) Tj ET /Span <</MCID 2>> BDC BT /F1 11 Tf 72 650 Td (Marked) Tj ET EMC");
        using var document = PdfDocument.Open(file);

        Assert.Equal("Plain Marked", ReadingOrder.Export(document));
    }

    [Theory]
    [InlineData(0)]
    [InlineData(7)]
    public void TextOfAFormWithAStaleSequenceIsFoundUnderTheNewSequenceAroundTheDrawing(int stale)
    {
        string form = $"/P <</MCID {stale}>> BDC BT /F1 11 Tf 72 700 Td (Form words) Tj ET EMC";
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 612 792]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Resources <</Font <</F1 5 0 R>> /XObject <</Fm1 10 0 R>>>>>>");
        pdf.Stream(4, "", "/Fm1 Do\n" + AccessKit.Text(72, 500, "Page words"));
        pdf.Obj(5, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding>>");
        pdf.Stream(10, "/Type /XObject /Subtype /Form /BBox [0 0 612 792] /Resources <</Font <</F1 5 0 R>>>>", form);
        using var document = PdfDocument.Open(pdf.Finish());

        AutoTagger.Tag(document);

        using var again = AccessKit.Reopen(document, rewrite: true);
        string order = ReadingOrder.Export(again);
        Assert.Contains("Form words", order);
        Assert.Contains("Page words", order);
    }

    [Fact]
    public void ASequenceOfAnOuterFormIsNotMixedUpWithTheSameNumberOnThePage()
    {
        using var document = PdfDocument.Open(NestedFile());

        Assert.Equal("Page text\nInner text", ReadingOrder.Export(document));
    }

    private static byte[] NestedFile()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R /StructTreeRoot 6 0 R /MarkInfo <</Marked true>> /Lang (en-US)>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 612 792]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Resources <</Font <</F1 5 0 R>> /XObject <</FmA 10 0 R>>>>>>");
        pdf.Stream(4, "", "/P <</MCID 2>> BDC BT /F1 11 Tf 72 700 Td (Page text) Tj ET EMC /FmA Do");
        pdf.Obj(5, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding>>");
        pdf.Obj(6, "<</Type /StructTreeRoot /K 7 0 R>>");
        pdf.Obj(7, "<</Type /StructElem /S /Document /P 6 0 R /K [8 0 R 9 0 R]>>");
        pdf.Obj(8, "<</Type /StructElem /S /P /P 7 0 R /Pg 3 0 R /K 2>>");
        pdf.Obj(9, "<</Type /StructElem /S /P /P 7 0 R /Pg 3 0 R /K <</Type /MCR /Pg 3 0 R /MCID 2 /Stm 10 0 R>>>>");
        pdf.Stream(10, "/Type /XObject /Subtype /Form /BBox [0 0 612 792] /Resources <</XObject <</FmB 11 0 R>>>>", "/Span <</MCID 2>> BDC /FmB Do EMC");
        pdf.Stream(11, "/Type /XObject /Subtype /Form /BBox [0 0 612 792] /Resources <</Font <</F1 5 0 R>>>>", "BT /F1 11 Tf 72 650 Td (Inner text) Tj ET");
        return pdf.Finish();
    }

    private static byte[] Drawn(string page, string kids)
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R /StructTreeRoot 6 0 R /MarkInfo <</Marked true>> /Lang (en-US)>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 612 792]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Resources <</Font <</F1 5 0 R>> /XObject <</Fm1 10 0 R>>>>>>");
        pdf.Stream(4, "", page);
        pdf.Obj(5, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding>>");
        pdf.Obj(6, "<</Type /StructTreeRoot /K 7 0 R>>");
        pdf.Obj(7, $"<</Type /StructElem /S /Document /P 6 0 R /K [{kids}]>>");
        pdf.Obj(8, "<</Type /StructElem /S /P /P 7 0 R /Pg 3 0 R /K 0>>");
        pdf.Obj(9, "<</Type /StructElem /S /H1 /P 7 0 R /Pg 3 0 R /K 1>>");
        pdf.Stream(10, "/Type /XObject /Subtype /Form /BBox [0 0 612 792] /Resources <</Font <</F1 5 0 R>>>>", "BT /F1 11 Tf 72 700 Td (Label) Tj ET");
        return pdf.Finish();
    }

    [Fact]
    public void AFormDrawnInTwoSequencesGivesEachItsOwnText()
    {
        using var document = PdfDocument.Open(Drawn(
            "/P <</MCID 0>> BDC /Fm1 Do EMC /H1 <</MCID 1>> BDC q 1 0 0 1 0 -100 cm /Fm1 Do Q EMC", "8 0 R 9 0 R"));

        Assert.Equal("Label\n# Label", ReadingOrder.Export(document));
    }

    [Fact]
    public void ADrawingOfAFormOutsideEverySequenceStaysOutOfTheOneBeforeIt()
    {
        using var document = PdfDocument.Open(Drawn("/P <</MCID 0>> BDC /Fm1 Do EMC q 1 0 0 1 0 -100 cm /Fm1 Do Q", "8 0 R"));

        Assert.Equal("Label", ReadingOrder.Export(document));
    }

    [Fact]
    public void AStaleKeyOnAFormOutsideTheTreeIsNotLeftPointingAtAPage()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 612 792]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Resources <</Font <</F1 5 0 R>> /XObject <</Fm1 10 0 R>>>> /StructParents 0>>");
        pdf.Stream(4, "", "/Fm1 Do\n" + AccessKit.Text(72, 500, "Page words"));
        pdf.Obj(5, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding>>");
        pdf.Stream(10, "/Type /XObject /Subtype /Form /BBox [0 0 612 792] /StructParents 0 /Resources <</Font <</F1 5 0 R>>>>",
            "/P <</MCID 0>> BDC BT /F1 11 Tf 72 700 Td (Form words) Tj ET EMC");
        using var document = PdfDocument.Open(pdf.Finish());

        AutoTagger.Tag(document);

        using var again = AccessKit.Reopen(document, rewrite: true);
        long? page = again.Integer(again.Pages[0].Dictionary, "StructParents");
        var xobject = again.ObjectNumbers.Select(again.Get).OfType<PdfStream>().First(s => again.Name(s.Dictionary, "Subtype") == "Form");
        long? form = again.Integer(xobject.Dictionary, "StructParents");
        Assert.NotNull(page);
        Assert.NotEqual(page, form);
    }
}
