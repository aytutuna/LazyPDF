using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class PdfAAnnotationTests
{
    private const string Square = "/Subtype /Square /F 4 /AP <</N 10 0 R>>";

    private static byte[] WithAnnotation(string annotation, PdfALevel level = PdfALevel.A2b, bool appearance = true) =>
        StandardsKit.Compliant(level, page: "/Annots [9 0 R]", extra: pdf =>
        {
            pdf.Obj(9, $"<</Type /Annot /Rect [10 10 50 50] {annotation}>>");
            if (appearance) pdf.Stream(10, "/Type /XObject /Subtype /Form /BBox [0 0 40 40]", "0 0 1 rg 0 0 40 40 re f");
        });

    [Fact]
    public void AnAnnotationWithAnAppearanceAndThePrintFlagPasses()
    {
        StandardsKit.AssertClean(WithAnnotation(Square));
        StandardsKit.AssertClean(WithAnnotation(Square, PdfALevel.A1b), PdfALevel.A1b);
    }

    [Fact]
    public void ForbiddenTypesAreReported()
    {
        foreach (string type in new[] { "Sound", "Movie", "Screen", "3D", "Bogus" })
            Assert.Contains("6.3.1", StandardsKit.Clauses(WithAnnotation($"/Subtype /{type} /F 4 /AP <</N 10 0 R>>")));
        Assert.Contains("6.5.2", StandardsKit.Clauses(WithAnnotation("/Subtype /Sound /F 4 /AP <</N 10 0 R>>", PdfALevel.A1b), PdfALevel.A1b));
    }

    [Fact]
    public void TypesFromPdf15AreReportedInPart1Only()
    {
        string caret = "/Subtype /Caret /F 4 /AP <</N 10 0 R>>";
        Assert.Contains("6.5.2", StandardsKit.Clauses(WithAnnotation(caret, PdfALevel.A1b), PdfALevel.A1b));
        Assert.DoesNotContain("6.3.1", StandardsKit.Clauses(WithAnnotation(caret)));
    }

    [Fact]
    public void AMissingNormalAppearanceIsReportedButNotForLinksOrPopups()
    {
        Assert.Contains("6.3.3", StandardsKit.Clauses(WithAnnotation("/Subtype /Square /F 4", appearance: false)));
        Assert.Contains("6.3.3", StandardsKit.Clauses(WithAnnotation("/Subtype /Square /F 4 /AP <</D 10 0 R>>")));
        Assert.DoesNotContain("6.3.3", StandardsKit.Clauses(WithAnnotation("/Subtype /Link /F 4 /Border [0 0 0]", appearance: false)));
        Assert.DoesNotContain("6.3.3", StandardsKit.Clauses(WithAnnotation("/Subtype /Popup", appearance: false)));
    }

    [Fact]
    public void AnAppearanceDictionaryMayOnlyHoldN()
    {
        Assert.Contains("6.3.3", StandardsKit.Clauses(WithAnnotation("/Subtype /Square /F 4 /AP <</N 10 0 R /D 10 0 R>>")));
    }

    [Fact]
    public void TheNormalAppearanceOfAButtonIsADictionaryAndOtherwiseAStream()
    {
        string widget = "/Subtype /Widget /FT /Btn /F 4";
        Assert.Contains("6.3.3", StandardsKit.Clauses(WithAnnotation($"{widget} /AP <</N 10 0 R>>")));
        Assert.DoesNotContain("6.3.3", StandardsKit.Clauses(WithAnnotation($"{widget} /AP <</N <</Yes 10 0 R /Off 10 0 R>>>>")));
        Assert.Contains("6.3.3", StandardsKit.Clauses(WithAnnotation("/Subtype /Widget /FT /Tx /F 4 /AP <</N <</Yes 10 0 R>>>>")));
    }

    [Fact]
    public void PrintAndVisibilityFlagsAreChecked()
    {
        Assert.Contains("6.3.2", StandardsKit.Clauses(WithAnnotation("/Subtype /Square /F 0 /AP <</N 10 0 R>>")));
        Assert.Contains("6.3.2", StandardsKit.Clauses(WithAnnotation("/Subtype /Square /AP <</N 10 0 R>>")));
        foreach (int hidden in new[] { 1, 2, 32 })
            Assert.Contains("6.3.2", StandardsKit.Clauses(WithAnnotation($"/Subtype /Square /F {4 | hidden} /AP <</N 10 0 R>>")));
        Assert.Contains("6.5.3", StandardsKit.Clauses(WithAnnotation("/Subtype /Square /F 0 /AP <</N 10 0 R>>", PdfALevel.A1b), PdfALevel.A1b));
    }

    [Fact]
    public void TheAppearanceStreamIsWalkedForColour()
    {
        byte[] file = StandardsKit.Compliant(intents: "", content: "", page: "/Annots [9 0 R]", extra: pdf =>
        {
            pdf.Obj(9, "<</Type /Annot /Rect [10 10 50 50] /Subtype /Square /F 4 /AP <</N 10 0 R>>>>");
            pdf.Stream(10, "/Type /XObject /Subtype /Form /BBox [0 0 40 40]", "0 0 1 rg 0 0 40 40 re f");
        });
        Assert.Contains(StandardsKit.Check(file).Issues, i => i.Clause == "6.2.4.3" && i.Where.StartsWith("Page 1, annotation 1", StringComparison.Ordinal));
    }

    [Fact]
    public void AFileAttachmentIsAllowedFromPart2ButNotInPart1OrPart4()
    {
        string attach = "/Subtype /FileAttachment /F 4 /AP <</N 10 0 R>>";
        Assert.DoesNotContain("6.3.1", StandardsKit.Clauses(WithAnnotation(attach)));
        Assert.Contains("6.5.2", StandardsKit.Clauses(WithAnnotation(attach, PdfALevel.A1b), PdfALevel.A1b));
        Assert.Contains("6.3.1", StandardsKit.Clauses(WithAnnotation(attach, PdfALevel.A4), PdfALevel.A4));
    }
}
