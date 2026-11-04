using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class StructureFactsTests
{
    [Fact]
    public void PlainFile()
    {
        var bytes = TestPdf.Simple(3);
        var facts = DocumentFacts.Read(PdfDocument.Open(bytes));
        Assert.Equal(("1.4", bytes.Length, 3), (facts.Version, facts.FileSize, facts.PageCount));
        Assert.Equal((200, 300), (facts.FirstPageWidth, facts.FirstPageHeight));
        Assert.False(facts.IsEncrypted || facts.IsSigned || facts.IsCertified || facts.IsTagged || facts.HasJavaScript || facts.HasBookmarks || facts.IsPortfolio);
        Assert.Null(facts.Permissions);
        Assert.Equal(FormKind.None, facts.Form);
        Assert.Equal((0, 0), (facts.AttachmentCount, facts.LayerCount));
        Assert.Null(facts.PdfAPart);
        Assert.Equal(0, facts.RepairCount);
        Assert.Null(facts.Metadata.Title);
    }

    [Fact]
    public void RotatedFirstPageSwapsTheSize()
    {
        var document = StructureFixtures.Open();
        document.Pages[0].Dictionary["Rotate"] = new PdfNumber(90);
        var facts = DocumentFacts.Read(document);
        Assert.Equal((300, 200), (facts.FirstPageWidth, facts.FirstPageHeight));
    }

    [Fact]
    public void DocumentWithEverything()
    {
        var document = StructureFixtures.File(
            "/Lang (en) /MarkInfo <</Marked true>> /OpenAction 30 0 R /Outlines 31 0 R /Collection <<>> /AcroForm <</Fields [32 0 R] /SigFlags 3>> " +
            "/OCProperties <</OCGs [33 0 R 34 0 R]>> /Names <</EmbeddedFiles <</Names [(a) 35 0 R]>>>>",
            pdf =>
            {
                pdf.Obj(30, "<</S /JavaScript /JS (1)>>");
                pdf.Obj(31, "<</First 36 0 R /Last 36 0 R /Count 1>>");
                pdf.Obj(32, "<</FT /Tx /T (f)>>");
                pdf.Obj(33, "<</Type /OCG /Name (a)>>");
                pdf.Obj(34, "<</Type /OCG /Name (b)>>");
                pdf.Stream(37, "", "x");
                pdf.Obj(35, "<</F (a.txt) /EF <</F 37 0 R>>>>");
                pdf.Obj(36, "<</Title (t)>>");
            });
        var facts = DocumentFacts.Read(document);
        Assert.True(facts.IsTagged && facts.IsSigned && facts.HasJavaScript && facts.HasBookmarks && facts.IsPortfolio);
        Assert.Equal(FormKind.AcroForm, facts.Form);
        Assert.Equal((1, 2, "en"), (facts.AttachmentCount, facts.LayerCount, facts.Language));
    }

    [Fact]
    public void XfaWinsOverAcroForm()
    {
        var document = StructureFixtures.File("/AcroForm <</Fields [] /XFA [(template) 30 0 R]>>", pdf => pdf.Stream(30, "", "<x/>"));
        Assert.Equal(FormKind.Xfa, DocumentFacts.Read(document).Form);
        Assert.Equal(FormKind.None, DocumentFacts.Read(StructureFixtures.File("/AcroForm <</Fields []>>")).Form);
    }

    [Fact]
    public void EncryptedFileShowsPermissions()
    {
        var id = Enumerable.Range(1, 16).Select(i => (byte)i).ToArray();
        var security = PdfSecurity.Create("", "owner", PdfPermissions.Print | PdfPermissions.Copy, PdfCryptStrength.Aes256, id, new Random(1));
        var document = PdfDocument.Open(StructureFixtures.Open().SaveRewrite(new PdfSaveOptions(Security: security)));
        var facts = DocumentFacts.Read(document);
        Assert.True(facts.IsEncrypted);
        Assert.Equal(PdfPermissions.Print | PdfPermissions.Copy, facts.Permissions);
    }

    [Fact]
    public void MetadataIsIncluded()
    {
        var document = StructureFixtures.Open();
        (DocumentMetadata.Read(document) with { Title = "Plan" }).Write(document);
        Assert.Equal("Plan", DocumentFacts.Read(document).Metadata.Title);
    }

    [Fact]
    public void NoPagesGiveZeroSize()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [] /Count 0>>");
        var facts = DocumentFacts.Read(PdfDocument.Open(pdf.Finish()));
        Assert.Equal((0, 0, 0), (facts.PageCount, facts.FirstPageWidth, facts.FirstPageHeight));
    }

    [Fact]
    public void TextForFormKinds()
    {
        Assert.Equal("None", StructureText.FormKindName(FormKind.None));
        Assert.NotEqual(StructureText.FormKindName(FormKind.AcroForm), StructureText.FormKindName(FormKind.Xfa));
    }
}
