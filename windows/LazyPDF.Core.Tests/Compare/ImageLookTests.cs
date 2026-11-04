using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class ImageLookTests
{
    private static void Alike(string first, string second)
    {
        using var a = CompareReviewTests.Picture(first);
        using var b = CompareReviewTests.Picture(second);
        Assert.True(PdfComparer.Compare(a, b).IsIdentical);
    }

    private static void Apart(string first, string second, Action<TestPdf, int>? extra = null)
    {
        using var a = CompareReviewTests.Picture(first, extra);
        using var b = CompareReviewTests.Picture(second, extra);
        Assert.Equal(CompareText.ImageReplaced, Assert.Single(PdfComparer.Compare(a, b).Changes).Detail);
    }

    [Fact]
    public void OneFilterInAnArrayReadsLikeABareFilter()
    {
        Alike("/Filter [/FlateDecode] /DecodeParms [<</Predictor 15 /Columns 100>>]", "/Filter /FlateDecode /DecodeParms <</Predictor 15 /Columns 100>>");
        Alike("/Filter [/ASCIIHexDecode] /DecodeParms [null]", "");
        Alike("/Filter /AHx", "");
    }

    [Fact]
    public void ValuesSpelledOutAsTheirDefaultsAreLeftOut()
    {
        Alike("/DecodeParms [null]", "");
        Alike("/DecodeParms <</Predictor 1 /Colors 1>>", "");
        Alike("/ImageMask false", "");
        Alike("/Decode [0 1]", "");
        Alike("/ColorSpace [/Indexed /DeviceGray 1 <00FF>] /Decode [0 255]", "/ColorSpace [/Indexed /DeviceGray 1 <00FF>]");
    }

    [Fact]
    public void HowTheStoredBytesAreReadIsPartOfTheLook()
    {
        Apart("/BitsPerComponent 4", "");
        Apart("/Filter /RunLengthDecode", "");
        Apart("/Decode [0 255]", "");
    }

    [Fact]
    public void EntriesOfAMaskThatGovernItsSamplesAreSeen()
    {
        static string Mask(int width, int height) => $"/Type /XObject /Subtype /Image /Width {width} /Height {height} /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /ASCIIHexDecode";
        const string Samples = "00FF00FF00FF00FF>";
        using var wide = CompareReviewTests.Picture("/SMask 10 0 R", (pdf, _) => pdf.Stream(10, Mask(4, 2), Samples));
        using var tall = CompareReviewTests.Picture("/SMask 10 0 R", (pdf, _) => pdf.Stream(10, Mask(2, 4), Samples));
        using var again = CompareReviewTests.Picture("/SMask 10 0 R", (pdf, _) => pdf.Stream(10, Mask(4, 2), Samples));
        Assert.Equal(CompareText.ImageReplaced, Assert.Single(PdfComparer.Compare(wide, tall).Changes).Detail);
        Assert.True(PdfComparer.Compare(wide, again).IsIdentical);
    }

    [Fact]
    public void RangeOfASampledTintFunctionIsSeen()
    {
        static Action<TestPdf, int> Function(string range) =>
            (pdf, _) => pdf.Stream(10, $"/FunctionType 0 /Domain [0 1] /Range {range} /Size [2] /BitsPerSample 8", "AB");
        const string Space = "/ColorSpace [/Separation /Spot /DeviceGray 10 0 R]";
        using var full = CompareReviewTests.Picture(Space, Function("[0 1]"));
        using var half = CompareReviewTests.Picture(Space, Function("[0 0.5]"));
        using var respelled = CompareReviewTests.Picture(Space, Function("[0.0 1.0]"));
        Assert.Equal(CompareText.ImageReplaced, Assert.Single(PdfComparer.Compare(full, half).Changes).Detail);
        Assert.True(PdfComparer.Compare(full, respelled).IsIdentical);
    }
}
