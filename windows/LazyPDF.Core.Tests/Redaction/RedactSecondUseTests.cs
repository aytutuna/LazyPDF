using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

// A picture, form or mask that is cut at a mark is a copy; every other use of it, wherever it is, still names the original.
public class RedactSecondUseTests
{
    private const string Stamp = "<</Type /Annot /Subtype /Stamp /Rect [500 700 501 701] /F 4 /AP <</N 7 0 R>>>>";
    private static readonly PdfRect OverPicture = new(90, 90, 250, 250);

    private static void Appearance(TestPdf pdf, string resources, string content) =>
        pdf.Stream(7, $"/Type /XObject /Subtype /Form /BBox [0 0 1 1] /Resources <<{resources}>>", content);

    [Fact]
    public void AnnotationAppearanceThatPaintsTheCutPictureMakesAPicture()
    {
        using var document = RedactionFiles.Open(RedactionFiles.Picture, "/XObject <</Im1 6 0 R>>", pdf =>
        {
            RedactionFiles.Image(pdf, 6);
            Appearance(pdf, "/XObject <</Im1 6 0 R>>", "/Im1 Do");
            pdf.Obj(8, Stamp);
        }, pageExtra: "/Annots [8 0 R]");
        RedactionKit.AssertFlattened(document, OverPicture, "ZQXPIXELS");
    }

    [Fact]
    public void AnnotationAppearanceThatIsTheCutFormMakesAPicture()
    {
        using var document = RedactionFiles.Open("/Fm1 Do", "/XObject <</Fm1 6 0 R>>", pdf =>
        {
            pdf.Stream(6, "/Type /XObject /Subtype /Form /BBox [0 0 600 800] /Resources <</Font <</F1 5 0 R>>>>", RedactionFiles.Word);
            pdf.Obj(8, "<</Type /Annot /Subtype /Stamp /Rect [500 700 501 701] /F 4 /AP <</N 6 0 R>>>>");
        }, pageExtra: "/Annots [8 0 R]");
        RedactionKit.AssertFlattened(document, RedactionFiles.Over, "ZQXSECRET");
    }

    [Fact]
    public void PictureStaysCutWhenNoAnnotationShowsIt()
    {
        using var document = RedactionFiles.Open(RedactionFiles.Picture, "/XObject <</Im1 6 0 R>>", pdf => RedactionFiles.Image(pdf, 6));
        var result = RedactionFiles.Apply(document, RedactionMark.FromRect(0, OverPicture));
        Assert.Empty(result.Report.Flattened);
        RedactionFiles.Gone(result, "ZQXPIXELS");
    }

    [Theory]
    [InlineData("/SMask 8 0 R")]
    public void MaskHeldByAPictureOffTheMarkMakesAPicture(string mask)
    {
        using var document = RedactionFiles.Open(RedactionFiles.Picture + " q 20 0 0 20 400 600 cm /Im2 Do Q", "/XObject <</Im1 6 0 R /Im2 7 0 R>>", pdf =>
        {
            RedactionFiles.Image(pdf, 6, mask);
            RedactionFiles.Image(pdf, 7, mask, "ZQXOTHERS");
            RedactionFiles.Image(pdf, 8, data: "ZQXMASKED");
        });
        RedactionKit.AssertFlattened(document, OverPicture, "ZQXMASKED", "ZQXPIXELS");
    }

    [Fact]
    public void CutPictureThatIsTheMaskOfAnotherMakesAPicture()
    {
        using var document = RedactionFiles.Open(RedactionFiles.Picture + " q 20 0 0 20 400 600 cm /Im2 Do Q", "/XObject <</Im1 6 0 R /Im2 7 0 R>>", pdf =>
        {
            RedactionFiles.Image(pdf, 6);
            RedactionFiles.Image(pdf, 7, "/SMask 6 0 R", "ZQXOTHERS");
        });
        RedactionKit.AssertFlattened(document, OverPicture, "ZQXPIXELS");
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void UseOnAnotherMarkedPageMakesThatPageAPicture(bool form)
    {
        string use = form ? "/Fm1 Do" : "/Im1 Do";
        string first = form ? "/Fm1 Do" : RedactionFiles.Picture;
        using var document = RedactionFiles.Open([first, "q 5 0 0 5 5000 5000 cm " + use + " Q"], "/XObject <</Im1 6 0 R /Fm1 7 0 R>>", pdf =>
        {
            RedactionFiles.Image(pdf, 6);
            pdf.Stream(7, "/Type /XObject /Subtype /Form /BBox [0 0 600 800] /Resources <</Font <</F1 5 0 R>>>>", RedactionFiles.Word);
        });
        var marks = new[] { RedactionMark.FromRect(0, form ? RedactionFiles.Over : OverPicture), RedactionMark.FromRect(1, new PdfRect(400, 600, 450, 650)) };
        var result = RedactionKit.Apply(document, marks);
        Assert.Contains(1, result.Report.Flattened);
        RedactionFiles.Gone(result, form ? "ZQXSECRET" : "ZQXPIXELS");
    }

    [Fact]
    public void AppearanceOnAKeptAnnotationOfAnUnmarkedPageThatCannotBeFollowedIsReported()
    {
        using var document = RedactionFiles.Open([RedactionFiles.Picture, "BT ET"], "/XObject <</Im1 6 0 R>>", pdf =>
        {
            RedactionFiles.Image(pdf, 6);
            Appearance(pdf, "/XObject <</Im1 6 0 R>>", "% not a whole token\n");
            pdf.Obj(8, Stamp);
        }, pageExtras: ["", "/Annots [8 0 R]"]);
        var result = RedactionFiles.Apply(document, RedactionMark.FromRect(0, OverPicture));
        Assert.False(result.Verification.IsClean);
        Assert.Contains(RedactionText.NotFollowed(1), result.Verification.Problems);
    }
}
