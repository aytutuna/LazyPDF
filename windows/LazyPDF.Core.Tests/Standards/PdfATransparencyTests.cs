using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class PdfATransparencyTests
{
    private static byte[] Drawn(string state, string page = "") =>
        StandardsKit.Compliant(content: "/GS gs 0 0 1 rg 10 10 50 50 re f", resources: $"/ExtGState <</GS <<{state}>>>>", page: page);

    [Theory]
    [InlineData("/ca 0.5")]
    [InlineData("/CA 0.5")]
    [InlineData("/BM /Multiply")]
    [InlineData("/SMask << /S /Luminosity /G 9 0 R >>")]
    public void Part1RefusesWhatNeedsTransparencyAndLaterPartsAllowIt(string state)
    {
        byte[] file = StandardsKit.Compliant(PdfALevel.A1b, content: "/GS gs 0 0 1 rg 10 10 50 50 re f", resources: $"/ExtGState <</GS <<{state}>>>>",
            extra: pdf => pdf.Stream(9, "/Type /XObject /Subtype /Form /BBox [0 0 10 10]", "0.5 g 0 0 10 10 re f"));
        Assert.Contains("6.4", StandardsKit.Clauses(file, PdfALevel.A1b));
        Assert.DoesNotContain("6.4", StandardsKit.Clauses(file, PdfALevel.A2b));
        Assert.DoesNotContain("6.2.10", StandardsKit.Clauses(file, PdfALevel.A2b));
    }

    [Fact]
    public void ANormalGraphicsStateIsFineEverywhere()
    {
        StandardsKit.AssertClean(Drawn("/ca 1 /CA 1 /BM /Normal /SMask /None"), PdfALevel.A2b);
        Assert.DoesNotContain("6.4", StandardsKit.Clauses(Drawn("/ca 1 /BM /Compatible"), PdfALevel.A1b));
    }

    [Fact]
    public void ATransparencyGroupOnThePageIsRefusedByPart1Only()
    {
        byte[] file = StandardsKit.Compliant(PdfALevel.A1b, page: "/Group << /S /Transparency /CS /DeviceRGB >>");
        Assert.Contains("6.4", StandardsKit.Clauses(file, PdfALevel.A1b));
        Assert.DoesNotContain("6.2.10", StandardsKit.Clauses(file, PdfALevel.A2b));
    }

    [Fact]
    public void AGroupWithADeviceSpaceCountsAsDeviceColourUse()
    {
        byte[] file = StandardsKit.Compliant(intents: "", content: "", page: "/Group << /S /Transparency /CS /DeviceCMYK >>");
        Assert.Contains("6.2.4.3", StandardsKit.Clauses(file));
    }

    [Fact]
    public void TransferFunctionsAreNeverAllowed()
    {
        Assert.Contains("6.2.5", StandardsKit.Clauses(Drawn("/TR /Identity")));
        Assert.Contains("6.2.8", StandardsKit.Clauses(Drawn("/TR 9 0 R"), PdfALevel.A1b));
        Assert.DoesNotContain("6.2.5", StandardsKit.Clauses(Drawn("/TR2 /Default")));
        Assert.Contains("6.2.5", StandardsKit.Clauses(Drawn("/TR2 /Identity")));
    }

    [Fact]
    public void AnAnnotationOpacityBelowOneIsRefusedByPart1()
    {
        byte[] file = StandardsKit.Compliant(PdfALevel.A1b, page: "/Annots [9 0 R]",
            extra: pdf => pdf.Obj(9, "<</Type /Annot /Subtype /Square /Rect [10 10 50 50] /F 4 /CA 0.5 /AP <</N 10 0 R>>>>")
                .Stream(10, "/Type /XObject /Subtype /Form /BBox [0 0 40 40]", "0 0 1 rg 0 0 40 40 re f"));
        Assert.Contains("6.4", StandardsKit.Clauses(file, PdfALevel.A1b));
        Assert.DoesNotContain("6.2.10", StandardsKit.Clauses(file, PdfALevel.A2b));
    }
}
