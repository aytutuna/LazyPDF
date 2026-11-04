using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class SanitizeTextTests
{
    private const string Resources = "/Font <</F1 5 0 R>> /XObject <</Im0 6 0 R>>";

    private static byte[] Page(string content) => OptimizeKit.Build(content, Resources, pdf =>
    {
        pdf.Obj(5, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>");
        pdf.Stream(6, "/Type /XObject /Subtype /Image /Width 1 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 8", "H");
    });

    private static SanitizeResult Run(byte[] file, SanitizeOptions? options = null)
    {
        using var document = PdfDocument.Open(file);
        return new PdfSanitizer(document).Run(options ?? new SanitizeOptions());
    }

    [Fact]
    public void WhiteTextOnABlankPageIsReportedNotRemoved()
    {
        var result = Run(Page("1 g BT /F1 12 Tf 10 100 Td (WHITEWORDS) Tj ET 0 g BT /F1 12 Tf 10 50 Td (BLACKWORDS) Tj ET"));
        Assert.Equal(1, SanitizeKit.Count(result.Kept, SanitizeItem.HiddenText));
        Assert.Equal(0, SanitizeKit.Count(result.Removed, SanitizeItem.HiddenText));
        Assert.True(OptimizeKit.Everywhere(result.Bytes, "WHITEWORDS"));
    }

    [Fact]
    public void WhiteTextOnADarkAreaIsNotHidden()
    {
        var result = Run(Page("0 g 0 0 200 200 re f 1 g BT /F1 12 Tf 10 100 Td (ONBLACK) Tj ET"));
        Assert.Equal(0, SanitizeKit.Count(result.Kept, SanitizeItem.HiddenText));
    }

    [Fact]
    public void TextUnderALaterPictureIsReported()
    {
        var result = Run(Page("BT /F1 12 Tf 10 100 Td (BEHINDPICTURE) Tj ET q 200 0 0 200 0 0 cm /Im0 Do Q"));
        Assert.Equal(1, SanitizeKit.Count(result.Kept, SanitizeItem.HiddenText));
    }

    [Fact]
    public void TextAfterAPictureIsNotHidden()
    {
        var result = Run(Page("q 200 0 0 200 0 0 cm /Im0 Do Q BT /F1 12 Tf 10 100 Td (ABOVEPICTURE) Tj ET"));
        Assert.Equal(0, SanitizeKit.Count(result.Kept, SanitizeItem.HiddenText));
    }

    [Fact]
    public void RenderModeThreeStaysUnlessAskedFor()
    {
        byte[] file = Page("BT /F1 12 Tf 3 Tr 10 100 Td (OCRLAYER) Tj ET BT 0 Tr 10 50 Td (shown) Tj ET");
        var kept = Run(file);
        Assert.True(OptimizeKit.Everywhere(kept.Bytes, "OCRLAYER"));
        Assert.Equal(1, SanitizeKit.Count(kept.Kept, SanitizeItem.InvisibleText));

        var removed = Run(file, new SanitizeOptions { InvisibleText = true });
        Assert.False(OptimizeKit.Everywhere(removed.Bytes, "OCRLAYER"));
        Assert.Equal(1, SanitizeKit.Count(removed.Removed, SanitizeItem.InvisibleText));
        Assert.Equal("shown", OptimizeKit.PigText(removed.Bytes).Trim());
    }

    [Fact]
    public void QuoteOperatorsKeepTheirLineMove()
    {
        byte[] file = Page("BT /F1 12 Tf 14 TL 10 150 Td 3 Tr (OCRONE) Tj (OCRTWO) ' ET BT 0 Tr 10 50 Td (below) Tj ET");
        var result = Run(file, new SanitizeOptions { InvisibleText = true });
        Assert.False(OptimizeKit.Everywhere(result.Bytes, "OCRTWO"));
        Assert.Equal(2, SanitizeKit.Count(result.Removed, SanitizeItem.InvisibleText));
        Assert.Contains("below", OptimizeKit.EngineText(result.Bytes));
    }

    [Fact]
    public void ATextObjectThatAlsoShowsVisibleTextIsLeft()
    {
        byte[] file = Page("BT /F1 12 Tf 10 100 Td 3 Tr (OCRMIXED) Tj 0 Tr ( visible) Tj ET");
        var result = Run(file, new SanitizeOptions { InvisibleText = true });
        Assert.True(OptimizeKit.Everywhere(result.Bytes, "OCRMIXED"));
        Assert.Equal(1, SanitizeKit.Count(result.Kept, SanitizeItem.InvisibleText));
    }

    [Fact]
    public void InvisibleTextInAFormIsRemovedToo()
    {
        byte[] file = OptimizeKit.Build("q /Fm0 Do Q", "/XObject <</Fm0 6 0 R>>", pdf =>
        {
            pdf.Obj(5, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>");
            pdf.Stream(6, "/Type /XObject /Subtype /Form /BBox [0 0 200 200] /Resources <</Font <</F1 5 0 R>>>>", "BT /F1 12 Tf 3 Tr (OCRINFORM) Tj ET");
        });
        var result = Run(file, new SanitizeOptions { InvisibleText = true });
        Assert.False(OptimizeKit.Everywhere(result.Bytes, "OCRINFORM"));
    }
}
