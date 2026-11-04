using System.Text;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

// Other places that keep a copy of what was removed: image keys, the tag tree, XMP, private data, the file id.
public class RedactCopiesTests
{
    private const string Pixels = "ZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATA123";
    private const string ImageEntries = "/Type /XObject /Subtype /Image /Width 8 /Height 8 /ColorSpace /DeviceGray /BitsPerComponent 8";
    private const string Place = "q 160 0 0 160 100 100 cm /Im1 Do Q";
    private static readonly PdfRect TopLeft = new(100, 220, 140, 260);

    private static RedactionResult Redact(PdfDocument document, PdfRect? mark = null, RedactionOptions? options = null) =>
        new PdfRedactor(document).Apply([RedactionMark.FromRect(0, mark ?? TopLeft)], options);

    [Fact]
    public void CutImageDropsItsAlternatesOpiAndBytesPastTheLastRow()
    {
        using var document = RedactionKit.Page(Place, "/XObject <</Im1 6 0 R>>", pdf =>
        {
            pdf.Stream(6, $"{ImageEntries} /Alternates [<</Image 7 0 R>>] /OPI <</Version 1.3 /F (ZQXOPIPATH)>>", Pixels + "ZQXTRAILING");
            pdf.Stream(7, ImageEntries, Pixels.Replace("PIXELS", "ALTERN"));
        });
        var result = Redact(document);
        using var output = RedactionKit.Open(result);
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXALTERN"));
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXOPIPATH"));
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXTRAILING"));
        Assert.Equal(1, result.Report.Images);
    }

    private static void Tag(PdfDocument document, PdfObject kid, string alt)
    {
        var root = new PdfDictionary { ["Type"] = new PdfName("StructTreeRoot") };
        var top = new PdfDictionary();
        var figure = new PdfDictionary();
        var rootRef = document.Add(root);
        var topRef = document.Add(top);
        var figureRef = document.Add(figure);
        root["K"] = new PdfArray([topRef]);
        top["Type"] = new PdfName("StructElem");
        top["S"] = new PdfName("Document");
        top["P"] = rootRef;
        top["K"] = new PdfArray([figureRef]);
        figure["Type"] = new PdfName("StructElem");
        figure["S"] = new PdfName("Figure");
        figure["P"] = topRef;
        figure["Pg"] = document.Pages[0].Reference;
        figure["K"] = kid;
        figure["Alt"] = PdfText.ToObject(alt);
        document.Catalog["StructTreeRoot"] = rootRef;
    }

    private static PdfDocument ImageInForm(string page, string form) =>
        RedactionKit.Page(page, "/XObject <</Fm1 6 0 R>>", pdf =>
        {
            pdf.Stream(6, "/Type /XObject /Subtype /Form /BBox [0 0 600 800] /Resources <</XObject <</Im1 7 0 R>>>>", form);
            pdf.Stream(7, ImageEntries, Pixels);
        });

    [Fact]
    public void RemovalInsideAFormReachesTheElementOfTheSequenceThatCallsIt()
    {
        using var document = ImageInForm("/Figure <</MCID 0>> BDC /Fm1 Do EMC", Place);
        Tag(document, new PdfNumber(0), "Signature of Jane Doe");
        var result = Redact(document);
        using var output = RedactionKit.Open(result);
        Assert.False(RedactionKit.Holds(result.Bytes, "Signature of Jane Doe"));
    }

    [Fact]
    public void ContentItemInACopiedFormDoesNotKeepTheOriginalReachable()
    {
        using var document = ImageInForm("/Fm1 Do", "/Figure <</MCID 0>> BDC " + Place + " EMC");
        var item = new PdfDictionary { ["Type"] = new PdfName("MCR"), ["Pg"] = document.Pages[0].Reference, ["Stm"] = new PdfReference(6, 0), ["MCID"] = new PdfNumber(0) };
        Tag(document, item, "Signature of Jane Doe");
        var result = Redact(document);
        using var output = RedactionKit.Open(result);
        Assert.False(RedactionKit.Holds(result.Bytes, Pixels));
        Assert.False(RedactionKit.Holds(result.Bytes, "Signature of Jane Doe"));
    }

    [Fact]
    public void ObjectReferenceToACutImageDoesNotKeepTheOriginal()
    {
        using var document = RedactionKit.Page(Place, "/XObject <</Im1 6 0 R>>", pdf => pdf.Stream(6, ImageEntries, Pixels));
        var item = new PdfDictionary { ["Type"] = new PdfName("OBJR"), ["Pg"] = document.Pages[0].Reference, ["Obj"] = new PdfReference(6, 0) };
        Tag(document, item, "Signature of Jane Doe");
        var result = Redact(document);
        using var output = RedactionKit.Open(result);
        Assert.False(RedactionKit.Holds(result.Bytes, Pixels));
        Assert.False(RedactionKit.Holds(result.Bytes, "Signature of Jane Doe"));
    }

    [Fact]
    public void ContentItemWithoutATypeIsNotTakenForAnElement()
    {
        using var document = RedactionKit.Page("/P <</MCID 0>> BDC BT /F1 12 Tf 100 700 Td (ZQXMARKER) Tj ET EMC");
        var item = new PdfDictionary { ["Pg"] = document.Pages[0].Reference, ["MCID"] = new PdfNumber(0) };
        Tag(document, item, "described ZQXALT");
        var result = new PdfRedactor(document).Apply(RedactionKit.MarksOf(document, 0, "ZQXMARKER"));
        using var output = RedactionKit.Open(result);
        Assert.False(RedactionKit.Holds(result.Bytes, "described ZQXALT"));
    }

    private const string Packet = "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\"><rdf:Description>"
        + "<dc:title>kept title</dc:title>"
        + "<xmp:Thumbnails><rdf:Alt><rdf:li><xmpGImg:image>ZQXTHUMBNAIL</xmpGImg:image></rdf:li></rdf:Alt></xmp:Thumbnails>"
        + "<xmpMM:History><rdf:Seq><rdf:li>ZQXHISTORY</rdf:li></rdf:Seq></xmpMM:History>"
        + "</rdf:Description></rdf:RDF></x:xmpmeta>";

    private static PdfDocument WithPrivateData()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R /Metadata 7 0 R /PieceInfo <</App <</Data (ZQXPIECE)>>>>>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 600 800]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Resources <</Font <</F1 5 0 R>> /XObject <</Fm1 6 0 R>>>>>>");
        pdf.Stream(4, "", "/Fm1 Do BT /F1 12 Tf 100 700 Td (ZQXMARKER) Tj ET");
        pdf.Obj(5, RedactionKit.Helvetica);
        pdf.Stream(6, "/Type /XObject /Subtype /Form /BBox [0 0 10 10] /PieceInfo <</App <</Data (ZQXFORMPIECE)>>>>", "0 g 0 0 1 1 re f");
        pdf.Stream(7, "/Type /Metadata /Subtype /XML", Packet);
        return PdfDocument.Open(pdf.Finish("/Root 1 0 R /ID [<0102030405060708090a0b0c0d0e0f10> <0102030405060708090a0b0c0d0e0f10>]"));
    }

    [Fact]
    public void PageCopiesInXmpAndPrivateDataGoWithoutAskingForMetadataChanges()
    {
        using var document = WithPrivateData();
        var result = new PdfRedactor(document).Apply(RedactionKit.MarksOf(document, 0, "ZQXMARKER"));
        using var output = RedactionKit.Open(result);
        foreach (string gone in new[] { "ZQXTHUMBNAIL", "ZQXHISTORY", "ZQXPIECE", "ZQXFORMPIECE" }) Assert.False(RedactionKit.Holds(result.Bytes, gone), gone);
        Assert.Contains("kept title", Encoding.UTF8.GetString(output.Data(output.Stream(output.Catalog, "Metadata")!)));
    }

    [Fact]
    public void OpenOutputHasAnIdOfItsOwn()
    {
        using var document = WithPrivateData();
        var result = new PdfRedactor(document).Apply(RedactionKit.MarksOf(document, 0, "ZQXMARKER"));
        using var output = RedactionKit.Open(result);
        Assert.NotEqual(document.Id[0], output.Id[0]);
    }

    private static PdfDocument WithWordElsewhere()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 600 800]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Annots [6 0 R] /Resources <</Font <</F1 5 0 R>> /XObject <</Fm1 7 0 R>>>>>>");
        pdf.Stream(4, "", "/Fm1 Do BT /F1 12 Tf 100 700 Td (ZQXMARKER) Tj ET");
        pdf.Obj(5, RedactionKit.Helvetica);
        pdf.Obj(6, "<</Type /Annot /Subtype /Link /Rect [10 10 50 50] /A <</S /URI /URI (http://example.com/ZQXMARKER)>>>>");
        pdf.Stream(7, "/Type /XObject /Subtype /Form /BBox [0 0 10 10] /Metadata 8 0 R", "0 g 0 0 1 1 re f");
        pdf.Stream(8, "/Type /Metadata /Subtype /XML", "<x:xmpmeta><dc:title>ZQXMARKER in a form</dc:title></x:xmpmeta>");
        var document = PdfDocument.Open(pdf.Finish());
        Tag(document, new PdfNumber(0), "about ZQXMARKER");
        return document;
    }

    [Fact]
    public void WordInDescriptionsLinksAndEveryXmpPacketIsReportedAndOnlyReplacedWhenAsked()
    {
        using var document = WithWordElsewhere();
        var marks = RedactionKit.MarksOf(document, 0, "ZQXMARKER");
        var kept = new PdfRedactor(document).Apply(marks);
        Assert.False(kept.Verification.IsClean);
        Assert.Contains(kept.Report.Findings, f => f.Where == RedactionText.TextElsewhere && !f.Changed);
        Assert.Contains(kept.Report.Findings, f => f.Where.Contains("XMP") && !f.Changed);
        Assert.True(RedactionKit.Holds(kept.Bytes, "example.com/ZQXMARKER"));

        var changed = new PdfRedactor(document).Apply(marks, new RedactionOptions { ChangeMetadata = true });
        using var output = RedactionKit.Open(changed);
        Assert.False(RedactionKit.Holds(changed.Bytes, "ZQXMARKER"));
        Assert.True(RedactionKit.Holds(changed.Bytes, "example.com/[redacted]"));
        Assert.Contains(changed.Report.Findings, f => f.Where == RedactionText.TextElsewhere && f.Changed);
    }

    [Fact]
    public void WordInAnAttachmentIsNamedAsSuch()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R /Extra 4 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 600 800]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R>>");
        pdf.Stream(4, "/Type /EmbeddedFile", "notes about ZQXMARKER");
        var verification = PdfRedactor.Verify(pdf.Finish(), [], ["ZQXMARKER"]);
        Assert.Contains("attached file", Assert.Single(verification.Problems));
    }
}
