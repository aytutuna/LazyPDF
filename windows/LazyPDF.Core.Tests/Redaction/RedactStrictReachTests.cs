using System.IO.Compression;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

// What stays of the file after a redaction is what the pages paint, found by the keys that paint, and not whatever an object names.
public class RedactStrictReachTests
{
    private static readonly string Pixels = string.Concat(Enumerable.Repeat("ZQXPIXELS", 8))[..64];
    private const string Entries = "/Type /XObject /Subtype /Image /Width 8 /Height 8 /ColorSpace /DeviceGray /BitsPerComponent 8";
    private const string Place = "q 200 0 0 200 100 100 cm /Im1 Do Q ";
    private const string Word = "BT /F1 12 Tf 100 100 Td (ZQXSECRET) Tj ET";
    private static readonly RedactionMark OverImage = RedactionMark.FromRect(0, new PdfRect(100, 100, 300, 300));

    private static byte[] File(string content, string resources = "", Action<TestPdf>? more = null, string catalog = "", string page = "", string node = "")
    {
        var pdf = new TestPdf();
        pdf.Obj(1, $"<</Type /Catalog /Pages 2 0 R {catalog}>>");
        pdf.Obj(2, $"<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 600 800] {node}>>");
        pdf.Obj(3, $"<</Type /Page /Parent 2 0 R /Contents 4 0 R /Resources <</Font <</F1 5 0 R>> {resources}>> {page}>>");
        pdf.Stream(4, "", content);
        pdf.Obj(5, RedactionKit.Helvetica);
        more?.Invoke(pdf);
        return pdf.Finish();
    }

    private static RedactionResult Redact(byte[] file, params RedactionMark[] marks)
    {
        using var document = PdfDocument.Open(file);
        return RedactionKit.Apply(document, marks);
    }

    private static void AssertPixelsGone(RedactionResult result)
    {
        Assert.True(result.Verification.IsClean, string.Join("; ", result.Verification.Problems));
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXPIXELS"));
    }

    [Fact]
    public void KeyOfAUsedStateDoesNotKeepThePictureItNames()
    {
        var file = File("/G0 gs " + Place, "/ExtGState <</G0 6 0 R>> /XObject <</Im1 7 0 R>>", pdf =>
        {
            pdf.Obj(6, "<</Type /ExtGState /CA 1 /Keep 7 0 R>>");
            pdf.Stream(7, Entries, Pixels);
        });
        AssertPixelsGone(Redact(file, OverImage));
    }

    [Fact]
    public void ArrayOfStreamsUnderAnyKeyDoesNotKeepThem()
    {
        var file = File(Place, "/XObject <</Im1 7 0 R>>", pdf =>
        {
            pdf.Obj(6, "<</Type /ExtGState /Keep [7 0 R]>>");
            pdf.Stream(7, Entries + " /Alternates [<</Image 8 0 R>>]", Pixels);
            pdf.Stream(8, Entries, Pixels);
        });
        AssertPixelsGone(Redact(file, OverImage));
    }

    [Fact]
    public void ResourceListTypedAsAPageIsStillSweptAndSoIsWhatTheCatalogNamesBesides()
    {
        var file = File(Place, "/XObject 8 0 R", pdf =>
        {
            pdf.Stream(7, Entries, Pixels);
            pdf.Obj(8, "<</Type /Page /Im1 7 0 R>>");
        }, catalog: "/Keep 7 0 R");
        AssertPixelsGone(Redact(file, OverImage));
    }

    [Fact]
    public void AppearanceOfAKeptAnnotationDoesNotKeepThePageResourcesItListsOnly()
    {
        var file = File(Place + Word, "/XObject <</Im1 7 0 R>>", pdf =>
        {
            pdf.Stream(7, Entries, Pixels);
            pdf.Obj(9, "<</Font <</F1 5 0 R>> /XObject <</Im1 7 0 R>>>>");
            pdf.Obj(11, "<</Type /Annot /Subtype /Stamp /Rect [400 400 500 500] /AP <</N 10 0 R>>>>");
            pdf.Stream(10, "/Type /XObject /Subtype /Form /BBox [0 0 100 100] /Resources 9 0 R", "0 0 10 10 re f");
        }, page: "/Annots [11 0 R]");
        AssertPixelsGone(Redact(file, OverImage));
    }

    [Fact]
    public void ResourcesInTheTreeAreFoundWithoutAParentLink()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 600 800] /Resources <</Font <</F1 5 0 R>> /XObject <</Im1 7 0 R>>>>>>");
        pdf.Obj(3, "<</Type /Page /Contents 4 0 R>>");
        pdf.Stream(4, "", Place);
        pdf.Obj(5, RedactionKit.Helvetica);
        pdf.Stream(7, Entries, Pixels);
        AssertPixelsGone(Redact(pdf.Finish(), OverImage));
    }

    [Fact]
    public void PageTreeWithoutTypesIsLeftWhole()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Kids [3 0 R] /Count 1 /MediaBox [0 0 600 800]>>");
        pdf.Obj(3, "<</Parent 2 0 R /Contents 4 0 R /Resources <</Font <</F1 5 0 R>>>>>>");
        pdf.Stream(4, "", Word);
        pdf.Obj(5, RedactionKit.Helvetica);
        var result = Redact(pdf.Finish(), RedactionMark.FromRect(0, new PdfRect(90, 90, 300, 120)));
        using var output = RedactionKit.Reopen(result.Bytes);
        Assert.Single(output.Pages);
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXSECRET"));
    }

    [Fact]
    public void UnmarkedPageThatCannotBeFollowedIsReportedAndKeepsOnlyWhatItLists()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R 8 0 R] /Count 2 /MediaBox [0 0 600 800]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Resources 9 0 R>>");
        pdf.Stream(4, "", Place + Word);
        pdf.Obj(5, RedactionKit.Helvetica);
        pdf.Obj(8, "<</Type /Page /Parent 2 0 R /Contents 10 0 R /Resources 9 0 R /Keep 4 0 R>>");
        pdf.Obj(9, "<</Font <</F1 5 0 R>> /XObject <</Im1 7 0 R>>>>");
        pdf.Stream(10, "", "Q");
        pdf.Stream(7, Entries, Pixels);
        var result = Redact(pdf.Finish(), OverImage);
        Assert.Contains(RedactionText.NotFollowed(1), result.Verification.Problems);
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXSECRET"));
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void BoxesAndTurnThatAreObjectsOfTheirOwnSurviveOnEveryPageThatSharesThem(bool flatten)
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R 8 0 R] /Count 2>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Resources <</Font <</F1 5 0 R>>>> /MediaBox 10 0 R /Rotate 11 0 R>>");
        pdf.Stream(4, "", (flatten ? "BX EX " : "") + Word);
        pdf.Obj(5, RedactionKit.Helvetica);
        pdf.Obj(8, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Resources <</Font <</F1 5 0 R>>>> /MediaBox 10 0 R /Rotate 11 0 R>>");
        pdf.Obj(10, "[0 0 400 900]");
        pdf.Obj(11, "90");
        var result = Redact(pdf.Finish(), RedactionMark.FromRect(0, new PdfRect(90, 90, 300, 120)));
        using var output = RedactionKit.Reopen(result.Bytes);
        foreach (var page in output.Pages)
        {
            Assert.Equal(400, page.MediaBox.Width);
            Assert.Equal(90, page.Rotate);
        }
    }

    [Fact]
    public void PictureShownAgainWhereNoMarkIsMakesThePagePicture()
    {
        using var document = PdfDocument.Open(File(Place + "q 1 0 0 1 5000 0 cm 200 0 0 200 100 100 cm /Im1 Do Q", "/XObject <</Im1 7 0 R>>", pdf => pdf.Stream(7, Entries, Pixels)));
        RedactionKit.AssertFlattened(document, [OverImage], "ZQXPIXELS");
    }

    [Fact]
    public void PictureShownTwiceUnderTheMarksIsCutBothTimes()
    {
        using var document = PdfDocument.Open(File(Place + Place, "/XObject <</Im1 7 0 R>>", pdf => pdf.Stream(7, Entries, Pixels)));
        var result = new PdfRedactor(document).Apply([OverImage]);
        Assert.Empty(result.Report.Flattened);
        Assert.Equal(2, result.Report.Images);
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXPIXELS"));
    }

    [Fact]
    public void FormWithoutResourcesKeepsTheNamesItTakesFromThePage()
    {
        using var document = PdfDocument.Open(File(Word + " /Fm Do", "/XObject <</Fm 6 0 R /Im1 7 0 R>>", pdf =>
        {
            pdf.Stream(6, "/Type /XObject /Subtype /Form /BBox [0 0 600 800]", "q 100 0 0 100 400 400 cm /Im1 Do Q");
            pdf.Stream(7, Entries, Pixels);
        }));
        var result = new PdfRedactor(document).Apply([RedactionMark.FromRect(0, new PdfRect(90, 90, 300, 120))]);
        Assert.Empty(result.Report.Flattened);
        using var output = RedactionKit.Open(result);
        var list = output.Dict(output.Dict(output.Pages[0].Dictionary, "Resources"), "XObject")!;
        Assert.True(list.ContainsKey("Fm") && list.ContainsKey("Im1"));
        Assert.Single(RedactionKit.Images(output));
    }

    [Fact]
    public void FontChosenAgainInsideASavedStateIsStillTheOneAfterIt()
    {
        using var document = ContentTestPdf.Page("BT /F1 12 Tf 100 600 Td (ZQXSECRET) Tj ET /F1 12 Tf q /F2 10 Tf Q BT 100 300 Td (KEEPB) Tj ET",
            "/Font <</F1 5 0 R /F2 5 0 R>>", RedactionKit.Helvetica);
        var result = new PdfRedactor(document).Apply(RedactionKit.MarksOf(document, 0, "ZQXSECRET"));
        using var output = RedactionKit.Open(result);
        Assert.Equal("KEEPB", RedactionKit.Text(output));
    }

    [Fact]
    public void CatalogKeysOfTheLayersDoNotKeepWhatTheyNameBesides()
    {
        var file = File(Place, "/XObject <</Im1 7 0 R>>", pdf => pdf.Stream(7, Entries, Pixels),
            catalog: "/OCProperties <</OCGs [] /D <<>> /Keep [7 0 R]>> /OutputIntents [<</S /GTS_PDFA1 /Extra 7 0 R>>]");
        AssertPixelsGone(Redact(file, OverImage));
    }

    [Fact]
    public void VisibleLayerKeepsThePageAsText()
    {
        var file = File("/OC /MC0 BDC " + Word + " EMC", "/Properties <</MC0 6 0 R>>", pdf => pdf.Obj(6, "<</Type /OCG /Name (Layer)>>"),
            catalog: "/OCProperties <</OCGs [6 0 R] /D <</ON [6 0 R]>>>>");
        using var document = PdfDocument.Open(file);
        var result = new PdfRedactor(document).Apply([RedactionMark.FromRect(0, new PdfRect(90, 90, 300, 120))]);
        Assert.Empty(result.Report.Flattened);
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXSECRET"));
    }

    [Fact]
    public void HiddenLayerMakesThePagePicture()
    {
        var file = File("/OC /MC0 BDC " + Word + " EMC", "/Properties <</MC0 6 0 R>>", pdf => pdf.Obj(6, "<</Type /OCG /Name (Layer)>>"),
            catalog: "/OCProperties <</OCGs [6 0 R] /D <</OFF [6 0 R]>>>>");
        using var document = PdfDocument.Open(file);
        RedactionKit.AssertFlattened(document, [RedactionMark.FromRect(0, new PdfRect(90, 90, 300, 120))], "ZQXSECRET");
    }

    [Fact]
    public void FontDescriptorWithWildMetricsStillCutsTheTextUnderTheMark()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 600 800]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Resources <</Font <</F1 5 0 R>>>>>>");
        pdf.Stream(4, "", Word);
        pdf.Obj(5, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /FontDescriptor 6 0 R>>");
        pdf.Obj(6, "<</Type /FontDescriptor /FontName /Helvetica /Flags 32 /Ascent -5000 /Descent -6000 /ItalicAngle 0 /CapHeight 700 /StemV 80 /FontBBox [-166 -225 1000 931]>>");
        using var document = PdfDocument.Open(pdf.Finish());
        var result = new PdfRedactor(document).Apply([RedactionMark.FromRect(0, new PdfRect(90, 90, 300, 120))]);
        Assert.Empty(result.Report.Flattened);
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXSECRET"));
    }

    [Fact]
    public void StrokeInAStretchedSpaceIsFoundWhereItIsPainted()
    {
        using var document = PdfDocument.Open(File("q 1000 0 0 1 0 0 cm 1 w 0.15 100 m 0.15 700 l S Q"));
        var result = new PdfRedactor(document).Apply([RedactionMark.FromRect(0, new PdfRect(400, 300, 500, 400))]);
        Assert.Equal(1, result.Report.Paths);
    }

    [Theory]
    [InlineData("/Note <</ActualText (ZQXDESC)>> DP ", "")]
    [InlineData("/Span <</Title (ZQXDESC)>> BDC ", " EMC")]
    public void DescriptionBesideRemovedTextDoesNotStay(string before, string after)
    {
        using var document = PdfDocument.Open(File(before + Word + after));
        var result = new PdfRedactor(document).Apply([RedactionMark.FromRect(0, new PdfRect(90, 90, 300, 120))]);
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXDESC"));
    }

    [Fact]
    public void NoteWithNoExtentInsideTheMarkGoesWithIt()
    {
        using var document = PdfDocument.Open(File(Word));
        var note = new PdfAnnotationWriter(document).AddNote(document.Pages[0], new PdfRect(150, 100, 160, 110), new AnnotationInfo("Reviewer", "ZQXNOTE"));
        note.Dictionary["Rect"] = new PdfRect(150, 100, 150, 100).ToArray();
        var result = new PdfRedactor(document).Apply([RedactionMark.FromRect(0, new PdfRect(90, 90, 300, 120))]);
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXNOTE"));
    }

    [Fact]
    public void MarkWrittenInTheOrderOfTheSpecificationIsFilledWhole()
    {
        using var document = PdfDocument.Open(File("BX EX " + Word));
        // Upper right, upper left, lower right, lower left: the corners cross unless they are put in order.
        var mark = new RedactionMark(0, [new TextQuad(300, 300, 100, 300, 300, 100, 100, 100)]);
        var result = RedactionKit.Apply(document, [mark]);
        using var output = RedactionKit.Reopen(result.Bytes);
        var image = Assert.Single(RedactionKit.Images(output));
        var samples = output.Data(image.Stream!);
        double scale = image.Width / 600.0;
        foreach (var (x, y) in new[] { (110.0, 200.0), (290.0, 200.0), (200.0, 120.0), (200.0, 280.0) })
        {
            int i = ((int)((800 - y) * scale) * image.Width + (int)(x * scale)) * 3;
            Assert.Equal(new byte[] { 0, 0, 0 }, samples[i..(i + 3)]);
        }
    }

    [Fact]
    public void MarkFarBeyondThePageStillFillsThePicture()
    {
        using var document = PdfDocument.Open(File("BX EX " + Word));
        var result = RedactionKit.Apply(document, [RedactionMark.FromRect(0, new PdfRect(-1e12, -1e12, 1e12, 1e12))]);
        using var output = RedactionKit.Reopen(result.Bytes);
        var image = Assert.Single(RedactionKit.Images(output));
        Assert.Equal(new byte[] { 0, 0, 0 }, output.Data(image.Stream!)[..3]);
    }

    [Fact]
    public void DescriptionDeepInTheTagTreeDoesNotStay()
    {
        using var document = PdfDocument.Open(File(Word));
        var leaf = new PdfDictionary { ["S"] = new PdfName("Figure"), ["Alt"] = new PdfString("ZQXPORTRAIT"u8.ToArray(), false) };
        PdfDictionary top = leaf;
        for (int i = 0; i < 70; i++) top = new PdfDictionary { ["S"] = new PdfName("Div"), ["K"] = top };
        document.Catalog["StructTreeRoot"] = document.Add(new PdfDictionary { ["Type"] = new PdfName("StructTreeRoot"), ["K"] = top });
        RedactionStructure.Prune(document, [], new HashSet<PdfStream>(), []);
        Assert.False(leaf.ContainsKey("Alt"));
    }

    [Fact]
    public void ObjectReferenceOnAPageThatBecamePictureIsRemoved()
    {
        using var document = PdfDocument.Open(File(Word));
        var link = new PdfDictionary { ["S"] = new PdfName("Link"), ["Alt"] = new PdfString("ZQXLINK"u8.ToArray(), false) };
        link["K"] = new PdfDictionary { ["Type"] = new PdfName("OBJR"), ["Pg"] = document.Pages[0].Reference, ["Obj"] = new PdfReference(5, 0) };
        var root = new PdfDictionary { ["Type"] = new PdfName("StructTreeRoot"), ["K"] = link };
        document.Catalog["StructTreeRoot"] = document.Add(root);
        RedactionStructure.Prune(document, [], new HashSet<PdfStream>(), [document.Pages[0].Reference.Number]);
        Assert.False(root.ContainsKey("K"));
    }

    [Fact]
    public void WordInAZipAttachedWithoutATypeIsFound()
    {
        var file = File("BT /F1 12 Tf 100 100 Td (hello) Tj ET", "", pdf =>
        {
            pdf.Stream(6, "", Gzip("the ZQXCYCLE word"));
            pdf.Obj(7, "<</Type /Filespec /F (a.gz) /EF <</F 6 0 R>>>>");
        }, catalog: "/Names <</EmbeddedFiles <</Names [(a) 7 0 R]>>>>");
        Assert.Contains(PdfRedactor.Verify(file, [], ["ZQXCYCLE"]).Problems, p => p.Contains("attached file"));
    }

    [Fact]
    public void ContainerOfAnotherFormatIsNotCalledClean()
    {
        var file = File("BT /F1 12 Tf 100 100 Td (hello) Tj ET", "", pdf =>
        {
            pdf.Stream(6, "", new byte[] { 0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C, 0, 4, 1, 2, 3 });
            pdf.Obj(7, "<</Type /Filespec /F (a.7z) /EF <</F 6 0 R>>>>");
        }, catalog: "/Names <</EmbeddedFiles <</Names [(a) 7 0 R]>>>>");
        Assert.Contains(RedactionText.NotChecked(RedactionText.AttachedFile(6)), PdfRedactor.Verify(file, [], ["ZQXCYCLE"]).Problems);
    }

    [Fact]
    public void StreamThatCannotBeDecodedIsNotCalledClean()
    {
        var file = File("BT /F1 12 Tf 100 100 Td (hello) Tj ET", "", pdf => pdf.Stream(6, "/Filter /BogusDecode", "nothing to see"), catalog: "/Keep 6 0 R");
        Assert.Contains(RedactionText.NotChecked("object 6"), PdfRedactor.Verify(file, [], ["ZQXCYCLE"]).Problems);
    }

    [Theory]
    [InlineData("/Keep <</FontFile 6 0 R>>")]
    [InlineData("/Keep <</ToUnicode 6 0 R>>")]
    public void ProgramKeysOutsideAFontDoNotHideTheWord(string catalog)
    {
        var file = File("BT /F1 12 Tf 100 100 Td (hello) Tj ET", "", pdf => pdf.Stream(6, "", "the ZQXCYCLE word"), catalog: catalog);
        Assert.Contains(RedactionText.StillInFile("object 6"), PdfRedactor.Verify(file, [], ["ZQXCYCLE"]).Problems);
    }

    [Fact]
    public void CharSetOutsideAFontDescriptorDoesNotHideTheWord()
    {
        var file = File("BT /F1 12 Tf 100 100 Td (hello) Tj ET", catalog: "/Keep <</CharSet (ZQXCYCLE is here)>>");
        Assert.NotEmpty(PdfRedactor.Verify(file, [], ["ZQXCYCLE"]).Problems);
    }

    private static byte[] Gzip(string text)
    {
        using var output = new MemoryStream();
        using (var zip = new GZipStream(output, CompressionLevel.SmallestSize, true)) zip.Write(System.Text.Encoding.Latin1.GetBytes(text));
        return output.ToArray();
    }
}
