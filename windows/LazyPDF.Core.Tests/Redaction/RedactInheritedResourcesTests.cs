using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class RedactInheritedResourcesTests
{
    private const string Pixels = "ZQXINHERITED012";

    [Fact]
    public void ResourcesTakenFromThePageTreeLeaveNoCopyOfTheCutImageBehind()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R] /Count 2 /MediaBox [0 0 600 800] /Resources <</Font <</F1 5 0 R>> /XObject <</Im1 6 0 R>>>>>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Contents 7 0 R>>");
        pdf.Obj(4, "<</Type /Page /Parent 2 0 R /Contents 8 0 R>>");
        pdf.Obj(5, ContentTestPdf.Helvetica);
        pdf.Stream(6, "/Type /XObject /Subtype /Image /Width 5 /Height 3 /ColorSpace /DeviceGray /BitsPerComponent 8", Pixels);
        pdf.Stream(7, "", "q 150 0 0 90 100 100 cm /Im1 Do Q BT /F1 12 Tf 100 300 Td (first) Tj ET");
        pdf.Stream(8, "", "BT /F1 12 Tf 100 300 Td (second) Tj ET");
        using var document = PdfDocument.Open(pdf.Finish());

        var result = RedactionKit.Apply(document, [RedactionMark.FromRect(0, new PdfRect(90, 90, 260, 200))]);
        using var output = RedactionKit.Open(result);
        Assert.False(RedactionKit.Holds(result.Bytes, Pixels));
        Assert.All(output.Data(RedactionKit.Images(output).Single().Stream!), b => Assert.Equal(0, b));
        Assert.Equal("first", RedactionKit.Text(output, 0));
        Assert.Equal("second", RedactionKit.Text(output, 1));
    }
}
