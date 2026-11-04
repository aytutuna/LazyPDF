using System.Text;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

// One string in every place a file can hold text: after the application it is searched for in the raw
// bytes and in every decoded stream, in plain and in UTF-16 form.
public class RedactMarkerTests
{
    private const string Pixels = "ZQXPIXELDATA0123";

    private static PdfDocument Build()
    {
        var document = RedactionKit.Page(
            "BT /F1 12 Tf 100 700 Td (ZQXMARKER in text) Tj ET q 1 0 0 1 100 600 cm /Fm1 Do Q q 64 0 0 64 100 100 cm /Im1 Do Q",
            "/XObject <</Fm1 6 0 R /Im1 7 0 R>>", pdf =>
            {
                pdf.Stream(6, "/Type /XObject /Subtype /Form /BBox [0 0 300 50] /Resources <</Font <</F1 5 0 R>>>>", "BT /F1 12 Tf 0 20 Td (ZQXMARKER in a form) Tj ET");
                pdf.Stream(7, "/Type /XObject /Subtype /Image /Width 4 /Height 4 /ColorSpace /DeviceGray /BitsPerComponent 8", Encoding.ASCII.GetBytes(Pixels));
            });
        var page = document.Pages[0];
        new PdfAnnotationWriter(document).AddNote(page, new PdfRect(100, 500, 120, 520), new AnnotationInfo("ZQXMARKER author", "ZQXMARKER in a note"));
        PdfForm.Read(document).AddField(new FieldSpec(FieldKind.Text, "f", 0, new PdfRect(100, 400, 300, 420)) { Value = "ZQXMARKER in a field" });

        document.Trailer["Info"] = document.Add(new PdfDictionary
        {
            ["Title"] = PdfText.ToObject("About ZQXMARKER"), ["Author"] = PdfText.ToObject("Someone"), ["Keywords"] = PdfText.ToObject("ZQXMARKER Türkçe"),
        });
        const string xmp = "<?xpacket begin='' id='W5M0MpCehiHzreSzNTczkc9d'?><x:xmpmeta xmlns:x='adobe:ns:meta/'><rdf:RDF xmlns:rdf='http://www.w3.org/1999/02/22-rdf-syntax-ns#'>"
            + "<rdf:Description xmlns:dc='http://purl.org/dc/elements/1.1/'><dc:title><rdf:Alt><rdf:li xml:lang='x-default'>ZQXMARKER xmp title</rdf:li></rdf:Alt></dc:title></rdf:Description></rdf:RDF></x:xmpmeta><?xpacket end='w'?>";
        document.Catalog["Metadata"] = document.Add(new PdfStream(new PdfDictionary { ["Type"] = new PdfName("Metadata"), ["Subtype"] = new PdfName("XML") }, Encoding.UTF8.GetBytes(xmp)));
        var outline = Outline.Read(document);
        outline.Add(new OutlineItem { Title = "Chapter ZQXMARKER", Destination = new PdfDestination(0) });
        outline.Write(document);
        return document;
    }

    private static List<RedactionMark> Everywhere(PdfDocument document)
    {
        var marks = RedactionKit.MarksOf(document, 0, "ZQXMARKER");
        marks.Add(RedactionMark.FromRect(0, new PdfRect(90, 490, 130, 530)));
        marks.Add(RedactionMark.FromRect(0, new PdfRect(90, 390, 310, 430)));
        marks.Add(RedactionMark.FromRect(0, new PdfRect(100, 100, 164, 164)));
        return marks;
    }

    [Fact]
    public void NothingOfTheMarkerIsLeftAnywhereWhenMetadataIsChanged()
    {
        using var document = Build();
        Assert.True(RedactionKit.Holds(document.SaveRewrite(), RedactionKit.Marker));
        Assert.True(RedactionKit.Holds(document.SaveRewrite(), Pixels));
        var result = new PdfRedactor(document).Apply(Everywhere(document), new RedactionOptions { ChangeMetadata = true });

        Assert.True(result.Verification.IsClean, string.Join("; ", result.Verification.Problems));
        Assert.False(RedactionKit.Holds(result.Bytes, RedactionKit.Marker));
        Assert.False(RedactionKit.Holds(result.Bytes, Pixels));
        using var output = RedactionKit.Reopen(result.Bytes);
        Assert.Equal(" in text in a form", RedactionKit.Text(output));
        Assert.Contains(result.Report.Findings, f => f.Where.Contains("XMP") && f.Changed);
        Assert.Contains(result.Report.Findings, f => f.Where.Contains("information") && f.Changed);
        Assert.Contains(result.Report.Findings, f => f.Where.Contains("bookmark") && f.Changed);
        Assert.Equal("Someone", PdfText.Decode(((PdfString)output.Info!["Author"]!).Bytes));
        Assert.Contains("Chapter", Outline.Read(output).Items[0].Title);
    }

    [Fact]
    public void MetadataIsReportedButKeptUnlessAsked()
    {
        using var document = Build();
        var result = new PdfRedactor(document).Apply(Everywhere(document));
        Assert.Equal(3, result.Report.Findings.Count);
        Assert.All(result.Report.Findings, f => Assert.False(f.Changed));
        Assert.False(result.Verification.IsClean);
        Assert.True(RedactionKit.Holds(result.Bytes, RedactionKit.Marker));
        // The page itself is clean either way.
        using var output = RedactionKit.Reopen(result.Bytes);
        Assert.Equal(" in text in a form", RedactionKit.Text(output));
    }

    [Fact]
    public void ReportDoesNotRepeatTheTextUnlessAsked()
    {
        using var document = Build();
        var plain = new PdfRedactor(document).Apply(Everywhere(document));
        Assert.DoesNotContain(RedactionKit.Marker, plain.Report.ToString());
        Assert.Empty(plain.Report.Text);
        var asked = new PdfRedactor(document).Apply(Everywhere(document), new RedactionOptions { IncludeText = true });
        Assert.Contains(asked.Report.Text, t => t.Contains(RedactionKit.Marker));
        Assert.Contains(RedactionKit.Marker, asked.Report.ToString());
    }

    [Fact]
    public void TheOutputIsAFreshFileWithNoEarlierRevision()
    {
        // A file that was saved by appending twice: the first revision holds the marker text in the clear.
        var original = Build().SaveRewrite();
        var session = PdfEditSession.Open(original);
        new PdfAnnotationWriter(session.Document).AddNote(session.Document.Pages[0], new PdfRect(300, 300, 320, 320), new AnnotationInfo("a", "later"));
        session.Commit("note");
        Assert.True(session.Current.Length > original.Length);
        Assert.Contains("ZQXMARKER", System.Text.Encoding.Latin1.GetString(session.Current.Span));

        var result = new PdfRedactor(session.Document).Apply(Everywhere(session.Document), new RedactionOptions { ChangeMetadata = true });
        Assert.Single(System.Text.RegularExpressions.Regex.Matches(System.Text.Encoding.Latin1.GetString(result.Bytes), "%%EOF"));
        Assert.DoesNotContain("ZQXMARKER", RedactionKit.Everything(result.Bytes));
        using var output = RedactionKit.Reopen(result.Bytes);
        Assert.Empty(output.Repairs);
    }

    [Fact]
    public void TaggedContentLosesItsDescriptionAndEmptyElements()
    {
        using var document = RedactionKit.Page("/P <</MCID 0>> BDC BT /F1 12 Tf 100 700 Td (ZQXMARKER) Tj ET EMC /P <</MCID 1>> BDC BT /F1 12 Tf 100 600 Td (kept) Tj ET EMC");
        var page = document.Pages[0];
        page.Dictionary["StructParents"] = new PdfNumber(0);
        var root = new PdfDictionary();
        var docElement = new PdfDictionary();
        var first = new PdfDictionary();
        var second = new PdfDictionary();
        var rootRef = document.Add(root);
        var docRef = document.Add(docElement);
        var firstRef = document.Add(first);
        var secondRef = document.Add(second);
        root["Type"] = new PdfName("StructTreeRoot");
        root["K"] = new PdfArray([docRef]);
        root["ParentTree"] = new PdfDictionary { ["Nums"] = new PdfArray([new PdfNumber(0), new PdfArray([firstRef, secondRef])]) };
        docElement["Type"] = new PdfName("StructElem");
        docElement["S"] = new PdfName("Document");
        docElement["P"] = rootRef;
        docElement["K"] = new PdfArray([firstRef, secondRef]);
        foreach (var (element, mcid) in new[] { (first, 0), (second, 1) })
        {
            element["Type"] = new PdfName("StructElem");
            element["S"] = new PdfName("P");
            element["P"] = docRef;
            element["Pg"] = page.Reference;
            element["K"] = new PdfNumber(mcid);
        }
        first["Alt"] = PdfText.ToObject("description of ZQXMARKER");
        document.Catalog["StructTreeRoot"] = rootRef;

        var result = new PdfRedactor(document).Apply(RedactionKit.MarksOf(document, 0, "ZQXMARKER"));
        using var output = RedactionKit.Open(result);
        Assert.False(RedactionKit.Holds(result.Bytes, "description of"));
        var tree = output.Dict(output.Catalog, "StructTreeRoot")!;
        var top = (PdfDictionary)output.Resolve(((PdfArray)output.Resolve(tree["K"])!).Items[0])!;
        var kids = (PdfArray)output.Resolve(top["K"])!;
        Assert.Equal(1, output.Integer((PdfDictionary)output.Resolve(kids.Items.Single())!, "K"));
        var nums = PdfNumberTree.Read(output, tree["ParentTree"]);
        var entry = (PdfArray)output.Resolve(nums.Single().Value)!;
        Assert.True(output.Resolve(entry.Items[0]) is null);
        Assert.NotNull(output.Resolve(entry.Items[1]));
    }
}
