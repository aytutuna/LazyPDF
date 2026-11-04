using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class AccessDrawingOwnerTests
{
    private static byte[] Drawn(string page)
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R /StructTreeRoot 6 0 R /MarkInfo <</Marked true>> /Lang (en-US)>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 612 792]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Resources <</Font <</F1 5 0 R>> /XObject <</Fm1 10 0 R>>>>>>");
        pdf.Stream(4, "", page);
        pdf.Obj(5, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding>>");
        pdf.Obj(6, "<</Type /StructTreeRoot /K 7 0 R>>");
        pdf.Obj(7, "<</Type /StructElem /S /Document /P 6 0 R /K [8 0 R 9 0 R]>>");
        pdf.Obj(8, "<</Type /StructElem /S /P /P 7 0 R /Pg 3 0 R /K 0>>");
        pdf.Obj(9, "<</Type /StructElem /S /H1 /P 7 0 R /Pg 3 0 R /K 1>>");
        pdf.Stream(10, "/Type /XObject /Subtype /Form /BBox [0 0 612 792] /Resources <</Font <</F1 5 0 R>>>>", "BT /F1 11 Tf 72 700 Td (Label) Tj ET");
        return pdf.Finish();
    }

    [Theory]
    [InlineData("/Artifact BMC q 1 0 0 1 1 -2 cm /Fm1 Do Q EMC /P <</MCID 0>> BDC /Fm1 Do EMC")]
    [InlineData("/P <</MCID 0>> BDC /Fm1 Do EMC /Artifact BMC q 1 0 0 1 1 -2 cm /Fm1 Do Q EMC")]
    public void ADropShadowDoesNotTakeTheTextOfTheDrawingItCopies(string page)
    {
        using var document = PdfDocument.Open(Drawn(page));

        Assert.Equal("Label", ReadingOrder.Export(document));
    }

    [Fact]
    public void TwoSequencesDrawingTheFormCloseTogetherEachKeepTheirOwnCopy()
    {
        using var document = PdfDocument.Open(Drawn("/P <</MCID 0>> BDC /Fm1 Do EMC /H1 <</MCID 1>> BDC q 1 0 0 1 0 -3 cm /Fm1 Do Q EMC"));

        Assert.Equal("Label\n# Label", ReadingOrder.Export(document));
    }

    [Theory]
    [InlineData("q 0 0 1 1 re W n /Fm1 Do Q /P <</MCID 0>> BDC /Fm1 Do EMC")]
    [InlineData("q 7 Tr /Fm1 Do Q /P <</MCID 0>> BDC /Fm1 Do EMC")]
    public void ADrawingThePageDoesNotShowIsNotTheOwnerOfTheVisibleOne(string page)
    {
        using var document = PdfDocument.Open(Drawn(page));

        Assert.Equal("Label", ReadingOrder.Export(document));
    }

    [Fact]
    public void ASequenceWhoseDrawingIsClippedAwayGetsNothingFromTheVisibleOne()
    {
        using var document = PdfDocument.Open(Drawn("/H1 <</MCID 1>> BDC q 0 0 1 1 re W n /Fm1 Do Q EMC /P <</MCID 0>> BDC /Fm1 Do EMC"));

        Assert.Equal("Label", ReadingOrder.Export(document));
    }

    private static byte[] TwoPages(string extra)
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R] /Count 2 /MediaBox [0 0 612 792]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Contents 5 0 R /Resources <</Font <</F1 7 0 R>>>> /StructParents 0>>");
        pdf.Obj(4, "<</Type /Page /Parent 2 0 R /Contents 6 0 R /Resources <</Font <</F1 7 0 R>>>>>>");
        pdf.Stream(5, "", AccessKit.Text(72, 700, "First page words") + AccessKit.Text(72, 600, "More words"));
        pdf.Stream(6, "", AccessKit.Text(72, 700, "Second page words") + AccessKit.Text(72, 600, "More words"));
        pdf.Obj(7, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding>>");
        pdf.Obj(8, extra);
        return pdf.Finish();
    }

    [Fact]
    public void AnUnreferencedObjectWithTheLargestKeyDoesNotMakeNewKeysCollide()
    {
        using var document = PdfDocument.Open(TwoPages("<</StructParents 9223372036854775807>>"));

        AutoTagger.Tag(document);

        using var again = AccessKit.Reopen(document, rewrite: true);
        long? first = again.Integer(again.Pages[0].Dictionary, "StructParents");
        long? second = again.Integer(again.Pages[1].Dictionary, "StructParents");
        Assert.Equal(0, first);
        Assert.NotNull(second);
        Assert.NotEqual(first, second);
    }

    [Fact]
    public void AStaleKeyOnADirectAnnotationIsNotHandedToThePage()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 612 792]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Resources <</Font <</F1 5 0 R>>>> /Annots [<</Subtype /Text /Rect [0 0 10 10] /StructParent 0>>]>>");
        pdf.Stream(4, "", AccessKit.Text(72, 700, "Page words") + AccessKit.Text(72, 600, "More words"));
        pdf.Obj(5, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding>>");
        using var document = PdfDocument.Open(pdf.Finish());

        AutoTagger.Tag(document);

        using var again = AccessKit.Reopen(document, rewrite: true);
        var annotation = (PdfDictionary)again.Resolve(again.Array(again.Pages[0].Dictionary, "Annots")!.Items[0])!;
        long? page = again.Integer(again.Pages[0].Dictionary, "StructParents");
        Assert.NotNull(page);
        Assert.NotEqual(page, again.Integer(annotation, "StructParent"));
    }

    [Fact]
    public void AStaleKeyOnAnIndirectAnnotationTheTaggerSkipsIsNotHandedToThePage()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 612 792]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Resources <</Font <</F1 5 0 R>>>> /Annots [6 0 R]>>");
        pdf.Stream(4, "", AccessKit.Text(72, 700, "Page words") + AccessKit.Text(72, 600, "More words"));
        pdf.Obj(5, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding>>");
        pdf.Obj(6, "<</Type /Annot /Subtype /Popup /Rect [0 0 10 10] /StructParent 0>>");
        using var document = PdfDocument.Open(pdf.Finish());

        AutoTagger.Tag(document);

        using var again = AccessKit.Reopen(document, rewrite: true);
        var annotation = (PdfDictionary)again.Resolve(again.Array(again.Pages[0].Dictionary, "Annots")!.Items[0])!;
        long? page = again.Integer(again.Pages[0].Dictionary, "StructParents");
        Assert.NotNull(page);
        Assert.NotEqual(page, again.Integer(annotation, "StructParent"));
    }
}
