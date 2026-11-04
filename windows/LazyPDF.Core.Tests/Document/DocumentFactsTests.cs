using System.Text;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class DocumentFactsTests
{
    private static PdfDocument Open(string catalogEntries, TestPdf? extra = null, string trailer = "/Root 1 0 R")
    {
        var pdf = extra ?? new TestPdf();
        pdf.Obj(1, $"<</Type /Catalog /Pages 2 0 R {catalogEntries}>>");
        pdf.Obj(2, "<</Type /Pages /Kids [] /Count 0>>");
        return PdfDocument.Open(pdf.Finish(trailer));
    }

    [Fact]
    public void PlainFileHasNoFlags()
    {
        var document = PdfDocument.Open(TestPdf.Simple());
        Assert.False(document.IsSigned);
        Assert.False(document.IsCertified);
        Assert.False(document.HasXfa);
        Assert.False(document.IsTagged);
        Assert.False(document.IsLinearized);
        Assert.False(document.IsEncrypted);
        Assert.Null(document.PdfAPart);
        Assert.Null(document.PdfAConformance);
        Assert.Null(document.Info);
        Assert.Empty(document.Id);
    }

    [Fact]
    public void SignatureFlagsAndPermissions()
    {
        Assert.True(Open("/AcroForm <</SigFlags 3 /Fields []>>").IsSigned);
        Assert.False(Open("/AcroForm <</SigFlags 2>>").IsSigned);
        Assert.True(Open("/Perms <</UR3 << >> >>").IsSigned);
        var certified = Open("/Perms <</DocMDP 9 0 R>>", new TestPdf().Obj(9, "<</Type /Sig>>"));
        Assert.True(certified.IsSigned);
        Assert.True(certified.IsCertified);
        Assert.False(Open("/Perms <</UR3 << >> >>").IsCertified);
    }

    [Fact]
    public void XfaAndTags()
    {
        Assert.True(Open("/AcroForm <</XFA [(preamble) 7 0 R]>>").HasXfa);
        Assert.False(Open("/AcroForm <</Fields []>>").HasXfa);
        Assert.True(Open("/MarkInfo <</Marked true>>").IsTagged);
        Assert.False(Open("/MarkInfo <</Marked false>>").IsTagged);
    }

    [Fact]
    public void LinearizedFileSaysSoInItsFirstObject()
    {
        byte[] Build(string length)
        {
            var pdf = new TestPdf("%PDF-1.4\n%âãÏÓ\n").Obj(7, $"<</Linearized 1 /L {length} /N 1>>");
            pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
            pdf.Obj(2, "<</Type /Pages /Kids [] /Count 0>>");
            return pdf.Finish();
        }
        int size = Build("000").Length;
        Assert.True(PdfDocument.Open(Build(size.ToString())).IsLinearized);
        // A length that is not the file's means something was added or cut after.
        Assert.False(PdfDocument.Open(Build((size + 1).ToString())).IsLinearized);
    }

    [Fact]
    public void PdfAIsReadFromTheMetadata()
    {
        string xmp = "<?xpacket begin='' id='W5M0'?><x:xmpmeta xmlns:x='adobe:ns:meta/'><rdf:RDF xmlns:rdf='http://www.w3.org/1999/02/22-rdf-syntax-ns#'>"
                     + "<rdf:Description rdf:about='' xmlns:pdfaid='http://www.aiim.org/pdfa/ns/id/' pdfaid:part='2' pdfaid:conformance='u'/></rdf:RDF></x:xmpmeta><?xpacket end='w'?>";
        var document = Open("/Metadata 9 0 R", new TestPdf().Stream(9, "/Type /Metadata /Subtype /XML", xmp));
        Assert.Equal(2, document.PdfAPart);
        Assert.Equal("U", document.PdfAConformance);
    }

    [Fact]
    public void PdfAElementsAndBrokenMetadata()
    {
        string xmp = "<x:xmpmeta xmlns:x='adobe:ns:meta/' xmlns:pdfaid='http://www.aiim.org/pdfa/ns/id/'><pdfaid:part>1</pdfaid:part><pdfaid:conformance>B</pdfaid:conformance></x:xmpmeta>";
        Assert.Equal((1, "B"), PdfDocument.ReadPdfAId(Encoding.UTF8.GetBytes(xmp)));
        Assert.Equal((null, null), PdfDocument.ReadPdfAId(Encoding.UTF8.GetBytes("<x:xmpmeta><broken")));
        string bomb = "<!DOCTYPE x [<!ENTITY a \"aaaaaaaaaa\"><!ENTITY b \"&a;&a;&a;&a;\">]><x:xmpmeta xmlns:x='adobe:ns:meta/'>&b;</x:xmpmeta>";
        Assert.Equal((null, null), PdfDocument.ReadPdfAId(Encoding.UTF8.GetBytes(bomb)));
    }

    [Fact]
    public void VersionIsTheHeadersOrTheCatalogsWhenNewer()
    {
        Assert.Equal("1.4", Open("").Version);
        Assert.Equal("1.7", Open("/Version /1.7").Version);
        Assert.Equal("1.4", Open("/Version /1.2").Version);
        Assert.Equal("1.4", Open("/Version 5").Version);
        var pdf = new TestPdf("%PDF-2.0\n");
        Assert.Equal("2.0", Open("", pdf).Version);
        Assert.Equal("1.4", PdfDocument.Open(TestPdf.Replace(TestPdf.Simple(), "%PDF-1.4", "%PDF-x.y")).Version);
    }

    [Fact]
    public void InfoAndIdAreRead()
    {
        var pdf = new TestPdf().Obj(5, "<</Title (A title) /Producer (Test)>>");
        var document = Open("", pdf, "/Root 1 0 R /Info 5 0 R /ID [<0102> (ab)]");
        Assert.Equal("A title", TestPdf.Text(((PdfString)document.Info!["Title"]!).Bytes));
        Assert.Equal(2, document.Id.Count);
        Assert.Equal([1, 2], document.Id[0]);
        Assert.Equal(TestPdf.Latin("ab"), document.Id[1]);
    }

    [Fact]
    public void InfoAndIdComeFromAnOlderSectionWhenTheNewestLacksThem()
    {
        var first = new TestPdf().Obj(5, "<</Title (T)>>").Obj(1, "<</Type /Catalog /Pages 2 0 R>>").Obj(2, "<</Type /Pages /Kids [] /Count 0>>")
            .Finish("/Root 1 0 R /Info 5 0 R /ID [<aa> <bb>]");
        string update = "5 0 obj\n<</Title (New)>>\nendobj\n";
        long start = first.Length + update.Length;
        string section = $"xref\n5 1\n{first.Length:D10} 00000 n \ntrailer\n<</Size 6 /Root 1 0 R /Prev {TestPdf.Text(first).LastIndexOf("xref\n0", StringComparison.Ordinal)}>>\nstartxref\n{start}\n%%EOF\n";
        var document = PdfDocument.Open([.. first, .. TestPdf.Latin(update + section)]);
        Assert.Empty(document.Repairs);
        Assert.Equal("New", TestPdf.Text(((PdfString)document.Info!["Title"]!).Bytes));
        Assert.Equal(2, document.Id.Count);
    }
}
