using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class ImageDefaultDecodeTests
{
    [Theory]
    [InlineData("/DeviceGray", 8, new double[] { 0, 1 }, true)]
    [InlineData("/DeviceGray", 8, new double[] { 1, 0 }, false)]
    [InlineData("/DeviceRGB", 8, new double[] { 0, 1, 0, 1, 0, 1 }, true)]
    [InlineData("/DeviceRGB", 8, new double[] { 0, 1, 1, 0, 0, 1 }, false)]
    [InlineData("/DeviceCMYK", 8, new double[] { 0, 1, 0, 1, 0, 1, 0, 1 }, true)]
    [InlineData("[/Indexed /DeviceRGB 1 <000000FFFFFF>]", 8, new double[] { 0, 255 }, true)]
    [InlineData("[/Indexed /DeviceRGB 1 <000000FFFFFF>]", 4, new double[] { 0, 15 }, true)]
    [InlineData("[/Indexed /DeviceRGB 1 <000000FFFFFF>]", 8, new double[] { 0, 1 }, false)]
    [InlineData("[/Indexed /DeviceRGB 1 <000000FFFFFF>]", 8, new double[] { 255, 0 }, false)]
    [InlineData("[/Lab <</WhitePoint [0.95 1 1.09]>>]", 8, new double[] { 0, 100, -100, 100, -100, 100 }, true)]
    [InlineData("[/Lab <</WhitePoint [0.95 1 1.09] /Range [-50 50 -60 60]>>]", 8, new double[] { 0, 100, -50, 50, -60, 60 }, true)]
    [InlineData("[/Lab <</WhitePoint [0.95 1 1.09] /Range [-50 50 -60 60]>>]", 8, new double[] { 0, 100, -100, 100, -100, 100 }, false)]
    [InlineData("[/ICCBased 6 0 R]", 8, new double[] { 0, 1, -1, 1, 0, 1 }, true)]
    [InlineData("[/ICCBased 6 0 R]", 8, new double[] { 0, 1, 0, 1, 0, 1 }, false)]
    public void EachSpacesOwnDefaultIsRecognised(string space, int bpc, double[] decode, bool expected)
    {
        byte[] file = OptimizeKit.Build("q 10 0 0 10 0 0 cm /Im0 Do Q", "/XObject <</Im0 5 0 R>>", pdf =>
        {
            pdf.Stream(5, $"/Type /XObject /Subtype /Image /Width 1 /Height 1 /ColorSpace {space} /BitsPerComponent {bpc} /Filter /FlateDecode", TestPdf.Deflate([0, 0, 0]));
            pdf.Stream(6, "/N 3 /Range [0 1 -1 1 0 1]", [0]);
        });
        using var document = PdfDocument.Open(file);

        Assert.Equal(expected, ImageKit.DefaultDecode(document, OptimizeKit.Image(document).Dictionary, decode));
    }
}
