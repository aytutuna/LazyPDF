using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

// What a page keeps alive is what its content paints, through the keys that mean it. A name, a list or a private key that points at
// the cut picture or the old content keeps nothing.
public class RedactHolderRouteTests
{
    private const string Picture = RedactionFiles.Picture;
    private static readonly PdfRect OverBoth = new(90, 90, 300, 130);
    private const string Both = RedactionFiles.Word + " " + Picture;

    private static RedactionResult Redact(PdfDocument document) => RedactionFiles.Apply(document, RedactionMark.FromRect(0, OverBoth));

    [Theory]
    [InlineData("/Tag /P0 BDC EMC", "/Properties <</P0 6 0 R>>", "")]
    [InlineData("/C0 cs", "/ColorSpace <</C0 6 0 R>>", "")]
    [InlineData("BT /F2 12 Tf 400 600 Td (hello) Tj ET", "", "/F2 7 0 R")]
    public void NameThatPointsAtTheCutPictureKeepsNothing(string use, string resources, string fonts)
    {
        using var document = RedactionFiles.Open(Picture + " " + use, "/XObject <</Im1 6 0 R>> " + resources, pdf =>
        {
            RedactionFiles.Image(pdf, 6);
            pdf.Obj(7, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /ToUnicode 6 0 R>>");
        }, fonts);
        RedactionFiles.Gone(Redact(document), "ZQXPIXELS");
    }

    [Fact]
    public void FormListingKeysOfItsOwnKeepsNothing()
    {
        using var document = RedactionFiles.Open(Both + " /Fm2 Do", "/XObject <</Im1 6 0 R /Fm2 7 0 R>>", pdf =>
        {
            RedactionFiles.Image(pdf, 6);
            pdf.Stream(7, "/Type /XObject /Subtype /Form /BBox [0 0 600 800] /Resources <</K1 6 0 R /K2 31 0 R>>", "0 0 1 1 re f");
        });
        RedactionFiles.Gone(Redact(document), "ZQXPIXELS", "ZQXSECRET");
    }

    [Fact]
    public void FormWhoseResourcesAreAPictureKeepsNothing()
    {
        using var document = RedactionFiles.Open(Both + " /Fm2 Do", "/XObject <</Im1 6 0 R /Fm2 7 0 R>>", pdf =>
        {
            RedactionFiles.Image(pdf, 6);
            pdf.Stream(7, "/Type /XObject /Subtype /Form /BBox [0 0 600 800] /Resources 6 0 R", "0 0 1 1 re f");
        });
        RedactionFiles.Gone(Redact(document), "ZQXPIXELS", "ZQXSECRET");
    }

    [Fact]
    public void ProcSetThatIsAPictureKeepsNothing()
    {
        using var document = RedactionFiles.Open(Both, "/XObject <</Im1 6 0 R>> /ProcSet 6 0 R", pdf => RedactionFiles.Image(pdf, 6));
        RedactionFiles.Gone(Redact(document), "ZQXPIXELS", "ZQXSECRET");
    }

    [Theory]
    [InlineData("/Group <</S /Transparency /X <</CS [31 0 R 6 0 R]>>>>")]
    [InlineData("/TrimBox [0 0 600 800 31 0 R 6 0 R]")]
    [InlineData("/Group 31 0 R")]
    public void PageKeysThatHoldNoStreamKeepNothing(string extra)
    {
        using var document = RedactionFiles.Open(Both, "/XObject <</Im1 6 0 R>>", pdf => RedactionFiles.Image(pdf, 6), pageExtra: extra);
        RedactionFiles.Gone(Redact(document), "ZQXPIXELS", "ZQXSECRET");
    }

    [Fact]
    public void PrivateKeyAboveAPaintKeyKeepsNothing()
    {
        using var document = RedactionFiles.Open(Both + " /Fm2 Do", "/XObject <</Im1 6 0 R /Im2 7 0 R /Fm2 8 0 R>>", pdf =>
        {
            RedactionFiles.Image(pdf, 6);
            RedactionFiles.Image(pdf, 7, "/Private <</SMask 6 0 R /Mask 31 0 R>>", "ZQXOTHERS");
            pdf.Stream(8, "/Type /XObject /Subtype /Form /BBox [0 0 600 800] /Resources <</XObject <</Im2 7 0 R>>>>", "q 5 0 0 5 400 600 cm /Im2 Do Q");
        });
        RedactionFiles.Gone(Redact(document), "ZQXPIXELS", "ZQXSECRET");
    }

    [Theory]
    [InlineData(1)]
    [InlineData(2)]
    public void PageTreeNodeUsedAsAListStillReachesThePicture(int node)
    {
        using var document = RedactionFiles.Open(Picture, $"/XObject {node} 0 R", pdf => RedactionFiles.Image(pdf, 6),
            catalogExtra: node == 1 ? "/Im1 6 0 R" : "", pagesExtra: node == 2 ? "/Im1 6 0 R" : "");
        RedactionFiles.Gone(RedactionFiles.Apply(document, RedactionMark.FromRect(0, new PdfRect(90, 90, 250, 250))), "ZQXPIXELS");
    }

    [Fact]
    public void GlobalsOfAnUnmarkedPagesImageStay()
    {
        const string Entries = "/Type /XObject /Subtype /Image /Width 8 /Height 8 /ColorSpace /DeviceGray /BitsPerComponent 1 /Filter /JBIG2Decode /DecodeParms <</JBIG2Globals 10 0 R>>";
        using var document = RedactionFiles.Open([RedactionFiles.Word + " /Im1 Do", "/Im2 Do"], "/XObject <</Im1 6 0 R /Im2 7 0 R>>", pdf =>
        {
            pdf.Stream(6, Entries, "xx");
            pdf.Stream(7, Entries, "yy");
            pdf.Stream(10, "", "GLOBALDATA");
        });
        var result = RedactionFiles.Apply(document, RedactionMark.FromRect(0, RedactionFiles.Over));
        Assert.True(result.Verification.IsClean, string.Join("; ", result.Verification.Problems));
        Assert.True(RedactionKit.Holds(result.Bytes, "GLOBALDATA"));
    }

    [Fact]
    public void ThreadOfAnUnmarkedPageStays()
    {
        using var document = RedactionFiles.Open([RedactionFiles.Word, "BT ET"], more: pdf =>
        {
            pdf.Obj(8, "<</T 10 0 R /N 9 0 R /V 9 0 R /P 30 0 R /R [0 0 100 100]>>");
            pdf.Obj(9, "<</T 10 0 R /N 8 0 R /V 8 0 R /P 32 0 R /R [0 0 100 100]>>");
            pdf.Obj(10, "<</F 8 0 R /I <</Title (Thread)>>>>");
        }, pageExtras: ["/B [8 0 R]", "/B [9 0 R]"], catalogExtra: "/Threads [10 0 R]");
        var result = RedactionFiles.Apply(document, RedactionMark.FromRect(0, RedactionFiles.Over));
        using var output = RedactionKit.Open(result);
        var bead = (PdfDictionary)output.Resolve(((PdfArray)output.Resolve(output.Pages[1].Dictionary["B"])!).Items[0])!;
        Assert.True(bead.ContainsKey("T"));
        Assert.True(((PdfDictionary)output.Resolve(bead["T"])!).Count > 0);
    }

    [Fact]
    public void PageThatIsAlsoANodeWithKidsKeepsItsResources()
    {
        using var document = RedactionFiles.Open(Picture, "/XObject <</Im1 6 0 R>>", pdf => RedactionFiles.Image(pdf, 6), pageExtra: "/Kids []");
        var result = RedactionFiles.Apply(document, RedactionMark.FromRect(0, new PdfRect(90, 90, 250, 250)));
        Assert.Equal(1, result.Report.Pages.Sum(p => p.Images));
        RedactionFiles.Gone(result, "ZQXPIXELS");
    }
}
