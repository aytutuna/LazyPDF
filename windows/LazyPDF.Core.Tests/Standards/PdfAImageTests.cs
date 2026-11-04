using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class PdfAImageTests
{
    private static byte[] WithImage(string entries, PdfALevel level = PdfALevel.A2b, byte[]? data = null) =>
        StandardsKit.Compliant(level, content: "q 10 0 0 10 0 0 cm /Im Do Q", resources: "/XObject <</Im 9 0 R>>",
            extra: pdf => pdf.Stream(9, $"/Type /XObject /Subtype /Image /Width 1 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 8 {entries}", data ?? [0]));

    [Fact]
    public void APlainImagePasses()
    {
        StandardsKit.AssertClean(WithImage(""));
        StandardsKit.AssertClean(WithImage("/Interpolate false"));
    }

    [Fact]
    public void InterpolateOpiAndAlternatesAreReported()
    {
        Assert.Contains("6.2.8", StandardsKit.Clauses(WithImage("/Interpolate true")));
        Assert.Contains("6.2.4", StandardsKit.Clauses(WithImage("/Interpolate true", PdfALevel.A1b), PdfALevel.A1b));
        Assert.Contains(StandardsKit.Check(WithImage("/OPI << /Version 2 >>")).Issues, i => i.Message.Contains("OPI"));
        Assert.Contains(StandardsKit.Check(WithImage("/Alternates []")).Issues, i => i.Message.Contains("Alternates"));
    }

    [Fact]
    public void ASoftMaskedImageIsRefusedByPart1Only()
    {
        byte[] file = StandardsKit.Compliant(PdfALevel.A1b, content: "q 10 0 0 10 0 0 cm /Im Do Q", resources: "/XObject <</Im 9 0 R>>",
            extra: pdf => pdf.Stream(9, "/Type /XObject /Subtype /Image /Width 1 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 8 /SMask 10 0 R", new byte[] { 0 })
                .Stream(10, "/Type /XObject /Subtype /Image /Width 1 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 8", new byte[] { 255 }));
        Assert.Contains("6.4", StandardsKit.Clauses(file, PdfALevel.A1b));
        Assert.DoesNotContain("6.2.10", StandardsKit.Clauses(file, PdfALevel.A2b));
    }

    [Fact]
    public void JpegTwoThousandIsRefusedByPart1Only()
    {
        byte[] file = WithImage("/Filter /JPXDecode", PdfALevel.A1b);
        Assert.Contains("6.2.4", StandardsKit.Clauses(file, PdfALevel.A1b));
        Assert.DoesNotContain("6.2.8", StandardsKit.Clauses(file, PdfALevel.A2b));
    }

    [Fact]
    public void InlineImagesAreHeldToTheSameRules()
    {
        string inline = "q 10 0 0 10 0 0 cm BI /W 1 /H 1 /CS /G /BPC 8 /I true ID x EI Q";
        Assert.Contains("6.2.8", StandardsKit.Clauses(StandardsKit.Compliant(content: inline)));
        Assert.DoesNotContain("6.2.8", StandardsKit.Clauses(StandardsKit.Compliant(content: inline.Replace("/I true ", ""))));
        Assert.Contains("6.1.10", StandardsKit.Clauses(StandardsKit.Compliant(content: inline.Replace("/I true", "/F /LZW"))));
    }

    [Fact]
    public void FormXObjectsMayNotReferenceOrCarryPostScript()
    {
        string use = "/Fm Do";
        byte[] Form(string entries) => StandardsKit.Compliant(content: use, resources: "/XObject <</Fm 9 0 R>>",
            extra: pdf => pdf.Stream(9, $"/Type /XObject /Subtype /Form /BBox [0 0 10 10] {entries}", "0 g 0 0 5 5 re f"));
        StandardsKit.AssertClean(Form(""));
        Assert.Contains("6.2.9", StandardsKit.Clauses(Form("/Ref << /F (x.pdf) /Page 0 >>")));
        Assert.Contains("6.2.9", StandardsKit.Clauses(Form("/Subtype2 /PS")));
        Assert.Contains("6.2.9", StandardsKit.Clauses(Form("/OPI << >>")));
        Assert.Contains("6.2.6", StandardsKit.Clauses(Form("/Ref << /F (x.pdf) /Page 0 >>"), PdfALevel.A1b));
        Assert.Contains("6.2.7", StandardsKit.Clauses(Form("/Subtype2 /PS"), PdfALevel.A1b));
    }

    [Fact]
    public void APostScriptXObjectIsReported()
    {
        byte[] file = StandardsKit.Compliant(resources: "/XObject <</P 9 0 R>>", extra: pdf => pdf.Stream(9, "/Type /XObject /Subtype /PS", "1 0 moveto"));
        Assert.Contains("6.2.9", StandardsKit.Clauses(file));
    }
}
