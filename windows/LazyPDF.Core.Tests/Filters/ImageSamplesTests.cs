using Xunit;

namespace LazyPDF.Core.Tests;

public class ImageSamplesTests
{
    private static PdfRgbaImage Convert(string dictionary, byte[] samples, FilterFixtures.Streams? streams = null, Action<PdfDictionary>? extra = null)
    {
        streams ??= new FilterFixtures.Streams();
        var image = FilterFixtures.Dict(dictionary);
        extra?.Invoke(image);
        return PdfImageSamples.ToRgba(image, samples, FilterFixtures.Resolve, streams.Decode);
    }

    private static byte[] Px(PdfRgbaImage image, int x, int y) => image.Rgba[((y * image.Width + x) * 4)..][..4];

    private static void Near(byte[] expected, byte[] actual, int tolerance = 1) =>
        Assert.True(expected.Zip(actual).All(p => Math.Abs(p.First - p.Second) <= tolerance), $"expected [{string.Join(",", expected)}], got [{string.Join(",", actual)}]");

    [Fact]
    public void GrayEightBit()
    {
        var image = Convert("<< /Width 2 /Height 2 /BitsPerComponent 8 /ColorSpace /DeviceGray >>", [0, 85, 170, 255]);
        Assert.Equal(2, image.Width);
        Assert.Equal(2, image.Height);
        Assert.Equal(16, image.Rgba.Length);
        Assert.Equal(new byte[] { 0, 0, 0, 255 }, Px(image, 0, 0));
        Assert.Equal(new byte[] { 85, 85, 85, 255 }, Px(image, 1, 0));
        Assert.Equal(new byte[] { 170, 170, 170, 255 }, Px(image, 0, 1));
        Assert.Equal(new byte[] { 255, 255, 255, 255 }, Px(image, 1, 1));
    }

    [Theory]
    [InlineData(1, new byte[] { 0b10100000 }, new byte[] { 255, 0, 255 })]
    [InlineData(2, new byte[] { 0b00_01_11_00 }, new byte[] { 0, 85, 255 })]
    [InlineData(4, new byte[] { 0x0F, 0x80 }, new byte[] { 0, 255, 136 })]
    [InlineData(16, new byte[] { 0, 0, 0xFF, 0xFF, 0x80, 0x00 }, new byte[] { 0, 255, 128 })]
    public void GrayAtEveryDepth(int bits, byte[] samples, byte[] expected)
    {
        var image = Convert($"<< /Width 3 /Height 1 /BitsPerComponent {bits} /ColorSpace /DeviceGray >>", samples);
        Assert.Equal(expected, new[] { Px(image, 0, 0)[0], Px(image, 1, 0)[0], Px(image, 2, 0)[0] });
    }

    [Fact]
    public void RowsStartOnByteBoundaries()
    {
        // Width 3 at 2 bits: six bits and two padding bits per row.
        var image = Convert("<< /Width 3 /Height 2 /BitsPerComponent 2 /ColorSpace /DeviceGray >>", [0b11_00_11_11, 0b00_11_00_00]);
        Assert.Equal(new byte[] { 255, 0, 255 }, new[] { Px(image, 0, 0)[0], Px(image, 1, 0)[0], Px(image, 2, 0)[0] });
        Assert.Equal(new byte[] { 0, 255, 0 }, new[] { Px(image, 0, 1)[0], Px(image, 1, 1)[0], Px(image, 2, 1)[0] });
    }

    [Fact]
    public void DecodeArrayInvertsGray()
    {
        var image = Convert("<< /Width 2 /Height 1 /BitsPerComponent 8 /ColorSpace /DeviceGray /Decode [1 0] >>", [0, 255]);
        Assert.Equal(255, Px(image, 0, 0)[0]);
        Assert.Equal(0, Px(image, 1, 0)[0]);
    }

    [Fact]
    public void DecodeArrayNarrowsTheRange()
    {
        var image = Convert("<< /Width 2 /Height 1 /BitsPerComponent 8 /ColorSpace /DeviceGray /Decode [0 0.5] >>", [0, 255]);
        Assert.Equal(0, Px(image, 0, 0)[0]);
        Assert.Equal(128, Px(image, 1, 0)[0]);
    }

    [Theory]
    [InlineData(8)]
    [InlineData(16)]
    [InlineData(4)]
    public void RgbAtEveryDepth(int bits)
    {
        byte[] samples = bits switch
        {
            8 => [255, 0, 128, 0, 255, 0],
            16 => [0xFF, 0xFF, 0, 0, 0x80, 0, 0, 0, 0xFF, 0xFF, 0, 0],
            _ => [0xF0, 0x80, 0xF0],
        };
        var image = Convert($"<< /Width 2 /Height 1 /BitsPerComponent {bits} /ColorSpace /DeviceRGB >>", samples);
        Near(bits == 4 ? [255, 0, 136, 255] : [255, 0, 128, 255], Px(image, 0, 0));
        Near([0, 255, 0, 255], Px(image, 1, 0));
    }

    [Fact]
    public void RgbWithDecodeSwapsRange()
    {
        var image = Convert("<< /Width 1 /Height 1 /BitsPerComponent 8 /ColorSpace /DeviceRGB /Decode [1 0 1 0 1 0] >>", [255, 0, 100]);
        Near([0, 255, 155, 255], Px(image, 0, 0));
    }

    [Fact]
    public void CmykIsTheNaiveConversion()
    {
        var image = Convert("<< /Width 5 /Height 1 /BitsPerComponent 8 /ColorSpace /DeviceCMYK >>",
            [0, 0, 0, 0, 0, 0, 0, 255, 255, 0, 0, 0, 0, 255, 0, 0, 0, 0, 255, 0]);
        Assert.Equal(new byte[] { 255, 255, 255, 255 }, Px(image, 0, 0));
        Assert.Equal(new byte[] { 0, 0, 0, 255 }, Px(image, 1, 0));
        Assert.Equal(new byte[] { 0, 255, 255, 255 }, Px(image, 2, 0));
        Assert.Equal(new byte[] { 255, 0, 255, 255 }, Px(image, 3, 0));
        Assert.Equal(new byte[] { 255, 255, 0, 255 }, Px(image, 4, 0));
    }

    [Fact]
    public void IndexedWithAStringLookup()
    {
        var image = Convert("<< /Width 4 /Height 1 /BitsPerComponent 8 /ColorSpace [/Indexed /DeviceRGB 2 <FF0000 00FF00 0000FF>] >>", [0, 1, 2, 9]);
        Assert.Equal(new byte[] { 255, 0, 0, 255 }, Px(image, 0, 0));
        Assert.Equal(new byte[] { 0, 255, 0, 255 }, Px(image, 1, 0));
        Assert.Equal(new byte[] { 0, 0, 255, 255 }, Px(image, 2, 0));
        Assert.Equal(new byte[] { 0, 0, 255, 255 }, Px(image, 3, 0));
    }

    [Fact]
    public void IndexedWithAStreamLookupAndPackedIndices()
    {
        var streams = new FilterFixtures.Streams();
        var lookup = streams.Add("<< /Length 6 >>", [10, 20, 30, 200, 210, 220]);
        var image = Convert("<< /Width 4 /Height 1 /BitsPerComponent 1 /ColorSpace [/Indexed /DeviceRGB 1 0] >>", [0b01100000], streams,
            d => ((PdfArray)d["ColorSpace"]!).Items[3] = lookup);
        Assert.Equal(new byte[] { 10, 20, 30, 255 }, Px(image, 0, 0));
        Assert.Equal(new byte[] { 200, 210, 220, 255 }, Px(image, 1, 0));
        Assert.Equal(new byte[] { 200, 210, 220, 255 }, Px(image, 2, 0));
        Assert.Equal(new byte[] { 10, 20, 30, 255 }, Px(image, 3, 0));
    }

    [Fact]
    public void IndexedOverGrayAndShortLookup()
    {
        var image = Convert("<< /Width 3 /Height 1 /BitsPerComponent 8 /ColorSpace [/I /G 2 <00FF>] >>", [0, 1, 2]);
        Assert.Equal(0, Px(image, 0, 0)[0]);
        Assert.Equal(255, Px(image, 1, 0)[0]);
        Assert.Equal(0, Px(image, 2, 0)[0]);
    }

    [Fact]
    public void IndexedOverIndexedIsDamaged()
    {
        var e = Assert.Throws<PdfReadException>(() =>
            Convert("<< /Width 1 /Height 1 /ColorSpace [/Indexed [/Indexed /DeviceRGB 0 <000000>] 0 <00>] >>", [0]));
        Assert.Equal(PdfReadProblem.Damaged, e.Problem);
    }

    [Theory]
    [InlineData(1, new byte[] { 200 }, 200)]
    [InlineData(3, new byte[] { 10, 20, 30 }, 10)]
    public void IccBasedByComponentCount(int n, byte[] samples, int firstChannel)
    {
        var streams = new FilterFixtures.Streams();
        var profile = streams.Add($"<< /N {n} >>", []);
        var image = Convert($"<< /Width 1 /Height 1 /BitsPerComponent 8 >>", samples, streams, d => d["ColorSpace"] = new PdfArray([new PdfName("ICCBased"), profile]));
        Assert.Equal(firstChannel, Px(image, 0, 0)[0]);
        Assert.Equal(samples.Length == 1 ? 200 : 20, Px(image, 0, 0)[1]);
    }

    [Fact]
    public void IccBasedWithFourComponentsIsCmyk()
    {
        var streams = new FilterFixtures.Streams();
        var profile = streams.Add("<< /N 4 >>", []);
        var image = Convert("<< /Width 1 /Height 1 /BitsPerComponent 8 >>", [0, 0, 0, 255], streams, d => d["ColorSpace"] = new PdfArray([new PdfName("ICCBased"), profile]));
        Assert.Equal(new byte[] { 0, 0, 0, 255 }, Px(image, 0, 0));
    }

    [Fact]
    public void IccBasedWithoutNFallsBackToTheAlternate()
    {
        var streams = new FilterFixtures.Streams();
        var profile = streams.Add("<< /Alternate /DeviceRGB >>", []);
        var image = Convert("<< /Width 1 /Height 1 /BitsPerComponent 8 >>", [1, 2, 3], streams, d => d["ColorSpace"] = new PdfArray([new PdfName("ICCBased"), profile]));
        Assert.Equal(new byte[] { 1, 2, 3, 255 }, Px(image, 0, 0));
    }

    [Fact]
    public void IccBasedWithNothingToGoByIsDamaged()
    {
        var streams = new FilterFixtures.Streams();
        var profile = streams.Add("<< /N 7 >>", []);
        var e = Assert.Throws<PdfReadException>(() =>
            Convert("<< /Width 1 /Height 1 /BitsPerComponent 8 >>", [1, 2, 3], streams, d => d["ColorSpace"] = new PdfArray([new PdfName("ICCBased"), profile])));
        Assert.Equal(PdfReadProblem.Damaged, e.Problem);
    }

    [Fact]
    public void CalGrayIsGray()
    {
        var image = Convert("<< /Width 1 /Height 1 /BitsPerComponent 8 /ColorSpace [/CalGray << /WhitePoint [0.95 1 1.09] /Gamma 2.2 >>] >>", [77]);
        Assert.Equal(new byte[] { 77, 77, 77, 255 }, Px(image, 0, 0));
    }

    [Fact]
    public void CalRgbWithTheSrgbMatrixStaysCloseToTheInput()
    {
        const string space = "[/CalRGB << /WhitePoint [0.9505 1 1.089] /Gamma [2.2 2.2 2.2] " +
                             "/Matrix [0.4124 0.2126 0.0193 0.3576 0.7152 0.1192 0.1805 0.0722 0.9505] >>]";
        var image = Convert($"<< /Width 3 /Height 1 /BitsPerComponent 8 /ColorSpace {space} >>", [255, 255, 255, 0, 0, 0, 128, 128, 128]);
        Near([255, 255, 255, 255], Px(image, 0, 0), 2);
        Near([0, 0, 0, 255], Px(image, 1, 0), 1);
        Near([128, 128, 128, 255], Px(image, 2, 0), 4);
    }

    [Fact]
    public void LabMapsLightnessToGray()
    {
        const string space = "[/Lab << /WhitePoint [0.9642 1 0.8249] /Range [-128 127 -128 127] >>]";
        var image = Convert($"<< /Width 3 /Height 1 /BitsPerComponent 8 /ColorSpace {space} >>", [255, 128, 128, 0, 128, 128, 128, 128, 128]);
        Assert.True(Px(image, 0, 0).Take(3).All(c => c >= 245));
        Assert.True(Px(image, 1, 0).Take(3).All(c => c <= 8));
        var middle = Px(image, 2, 0);
        Assert.InRange((int)middle[0], 105, 135);
        Assert.InRange(Math.Abs(middle[0] - middle[1]), 0, 8);
        Assert.InRange(Math.Abs(middle[1] - middle[2]), 0, 8);
    }

    [Fact]
    public void LabAxesTurnTheColour()
    {
        const string space = "[/Lab << /WhitePoint [0.9642 1 0.8249] /Range [-100 100 -100 100] >>]";
        // L 50 with a = +100 is red-ish, a = -100 green-ish, b = +100 yellow, b = -100 blue.
        var image = Convert($"<< /Width 4 /Height 1 /BitsPerComponent 8 /ColorSpace {space} >>",
            [128, 255, 128, 128, 0, 128, 128, 128, 255, 128, 128, 0]);
        var red = Px(image, 0, 0);
        var green = Px(image, 1, 0);
        var yellow = Px(image, 2, 0);
        var blue = Px(image, 3, 0);
        Assert.True(red[0] > red[1] + 60);
        Assert.True(green[1] > green[0] + 60);
        Assert.True(yellow[0] > yellow[2] + 60);
        Assert.True(blue[2] > blue[0] + 60);
    }

    [Fact]
    public void SeparationThroughAnExponentialTint()
    {
        var image = Convert("<< /Width 3 /Height 1 /BitsPerComponent 8 /ColorSpace [/Separation /Spot /DeviceGray << /FunctionType 2 /Domain [0 1] /C0 [1] /C1 [0] /N 1 >>] >>", [0, 128, 255]);
        Assert.Equal(255, Px(image, 0, 0)[0]);
        Near([127, 127, 127, 255], Px(image, 1, 0), 1);
        Assert.Equal(0, Px(image, 2, 0)[0]);
    }

    [Fact]
    public void SeparationThroughACalculatorIntoCmyk()
    {
        var streams = new FilterFixtures.Streams();
        var tint = streams.Add("<< /FunctionType 4 /Domain [0 1] /Range [0 1 0 1 0 1 0 1] >>", "{ 0 exch 0 0 }"u8.ToArray());
        var image = Convert("<< /Width 2 /Height 1 /BitsPerComponent 8 >>", [0, 255], streams,
            d => d["ColorSpace"] = new PdfArray([new PdfName("Separation"), new PdfName("Magenta"), new PdfName("DeviceCMYK"), tint]));
        Assert.Equal(new byte[] { 255, 255, 255, 255 }, Px(image, 0, 0));
        Assert.Equal(new byte[] { 255, 0, 255, 255 }, Px(image, 1, 0));
    }

    [Fact]
    public void SeparationThroughASampledTint()
    {
        var streams = new FilterFixtures.Streams();
        var tint = streams.Add("<< /FunctionType 0 /Domain [0 1] /Range [0 1] /Size [2] /BitsPerSample 8 >>", [255, 0]);
        var image = Convert("<< /Width 2 /Height 1 /BitsPerComponent 8 >>", [0, 255], streams,
            d => d["ColorSpace"] = new PdfArray([new PdfName("Separation"), new PdfName("Black"), new PdfName("DeviceGray"), tint]));
        Assert.Equal(255, Px(image, 0, 0)[0]);
        Assert.Equal(0, Px(image, 1, 0)[0]);
    }

    [Fact]
    public void DeviceNWithTwoColorantsThroughACalculator()
    {
        var streams = new FilterFixtures.Streams();
        var tint = streams.Add("<< /FunctionType 4 /Domain [0 1 0 1] /Range [0 1 0 1 0 1] >>", "{ 1 exch sub exch 1 exch sub exch 1 }"u8.ToArray());
        var image = Convert("<< /Width 3 /Height 1 /BitsPerComponent 8 >>", [255, 0, 0, 255, 0, 0], streams,
            d => d["ColorSpace"] = new PdfArray([new PdfName("DeviceN"), FilterFixtures.Parse("[/Cyan /Spot]"), new PdfName("DeviceRGB"), tint]));
        Assert.Equal(new byte[] { 0, 255, 255, 255 }, Px(image, 0, 0));
        Assert.Equal(new byte[] { 255, 0, 255, 255 }, Px(image, 1, 0));
        Assert.Equal(new byte[] { 255, 255, 255, 255 }, Px(image, 2, 0));
    }

    [Fact]
    public void DeviceNTintFunctionWithTheWrongInputCountIsDamaged()
    {
        var streams = new FilterFixtures.Streams();
        var tint = streams.Add("<< /FunctionType 4 /Domain [0 1] /Range [0 1 0 1 0 1] >>", "{ dup dup }"u8.ToArray());
        var e = Assert.Throws<PdfReadException>(() => Convert("<< /Width 1 /Height 1 /BitsPerComponent 8 >>", [1, 2], streams,
            d => d["ColorSpace"] = new PdfArray([new PdfName("DeviceN"), FilterFixtures.Parse("[/A /B]"), new PdfName("DeviceRGB"), tint])));
        Assert.Equal(PdfReadProblem.Damaged, e.Problem);
    }

    [Fact]
    public void ImageMaskPaintsWhereTheSampleIsZero()
    {
        var image = Convert("<< /Width 4 /Height 1 /ImageMask true >>", [0b01010000]);
        Assert.Equal(new byte[] { 0, 0, 0, 255 }, Px(image, 0, 0));
        Assert.Equal(0, Px(image, 1, 0)[3]);
        Assert.Equal(255, Px(image, 2, 0)[3]);
        Assert.Equal(0, Px(image, 3, 0)[3]);
    }

    [Fact]
    public void ImageMaskDecodeInverts()
    {
        var image = Convert("<< /Width 2 /Height 1 /ImageMask true /Decode [1 0] >>", [0b01000000]);
        Assert.Equal(0, Px(image, 0, 0)[3]);
        Assert.Equal(255, Px(image, 1, 0)[3]);
    }

    [Fact]
    public void ColorKeyMaskAlphaValues()
    {
        var image = Convert("<< /Width 4 /Height 1 /BitsPerComponent 8 /ColorSpace /DeviceGray /Mask [10 20] >>", [9, 10, 20, 21]);
        Assert.Equal([255, 0, 0, 255], Enumerable.Range(0, 4).Select(x => (int)Px(image, x, 0)[3]));
    }

    [Fact]
    public void ColorKeyMaskOnIndexedUsesTheIndices()
    {
        var image = Convert("<< /Width 3 /Height 1 /BitsPerComponent 8 /ColorSpace [/Indexed /DeviceRGB 2 <FF0000 00FF00 0000FF>] /Mask [1 1] >>", [0, 1, 2]);
        Assert.Equal([255, 0, 255], Enumerable.Range(0, 3).Select(x => (int)Px(image, x, 0)[3]));
    }

    [Fact]
    public void ColorKeyMaskNeedsOneRangePerComponent()
    {
        var image = Convert("<< /Width 2 /Height 1 /BitsPerComponent 8 /ColorSpace /DeviceRGB /Mask [0 255] >>", [1, 2, 3, 4, 5, 6]);
        Assert.All(new[] { Px(image, 0, 0)[3], Px(image, 1, 0)[3] }, a => Assert.Equal(255, a));
    }

    [Fact]
    public void SoftMaskSetsAlpha()
    {
        var streams = new FilterFixtures.Streams();
        var mask = streams.Add("<< /Width 2 /Height 1 /BitsPerComponent 8 /ColorSpace /DeviceGray >>", [0, 200]);
        var image = Convert("<< /Width 2 /Height 1 /BitsPerComponent 8 /ColorSpace /DeviceGray >>", [50, 60], streams, d => d["SMask"] = mask);
        Assert.Equal(new byte[] { 50, 50, 50, 0 }, Px(image, 0, 0));
        Assert.Equal(new byte[] { 60, 60, 60, 200 }, Px(image, 1, 0));
    }

    [Fact]
    public void SoftMaskOfAnotherSizeIsSampledNearest()
    {
        var streams = new FilterFixtures.Streams();
        var mask = streams.Add("<< /Width 2 /Height 2 /BitsPerComponent 8 /ColorSpace /DeviceGray >>", [10, 20, 30, 40]);
        var image = Convert("<< /Width 4 /Height 4 /BitsPerComponent 8 /ColorSpace /DeviceGray >>", new byte[16], streams, d => d["SMask"] = mask);
        Assert.Equal(10, Px(image, 1, 1)[3]);
        Assert.Equal(20, Px(image, 2, 1)[3]);
        Assert.Equal(30, Px(image, 1, 2)[3]);
        Assert.Equal(40, Px(image, 3, 3)[3]);
    }

    [Fact]
    public void SoftMaskDecodeAndDepth()
    {
        var streams = new FilterFixtures.Streams();
        var mask = streams.Add("<< /Width 2 /Height 1 /BitsPerComponent 1 /ColorSpace /DeviceGray /Decode [1 0] >>", [0b01000000]);
        var image = Convert("<< /Width 2 /Height 1 /BitsPerComponent 8 /ColorSpace /DeviceGray >>", [1, 2], streams, d => d["SMask"] = mask);
        Assert.Equal(255, Px(image, 0, 0)[3]);
        Assert.Equal(0, Px(image, 1, 0)[3]);
    }

    [Fact]
    public void SoftMaskWinsOverMask()
    {
        var streams = new FilterFixtures.Streams();
        var soft = streams.Add("<< /Width 1 /Height 1 /BitsPerComponent 8 >>", [99]);
        var hard = streams.Add("<< /Width 1 /Height 1 /ImageMask true >>", [0x80]);
        var image = Convert("<< /Width 1 /Height 1 /BitsPerComponent 8 /ColorSpace /DeviceGray >>", [1], streams, d =>
        {
            d["SMask"] = soft;
            d["Mask"] = hard;
        });
        Assert.Equal(99, Px(image, 0, 0)[3]);
    }

    [Fact]
    public void StencilMaskHidesWhereTheSampleIsOne()
    {
        var streams = new FilterFixtures.Streams();
        var mask = streams.Add("<< /Width 4 /Height 1 /ImageMask true /BitsPerComponent 1 >>", [0b01100000]);
        var image = Convert("<< /Width 4 /Height 1 /BitsPerComponent 8 /ColorSpace /DeviceGray >>", [10, 20, 30, 40], streams, d => d["Mask"] = mask);
        Assert.Equal([255, 0, 0, 255], Enumerable.Range(0, 4).Select(x => (int)Px(image, x, 0)[3]));
    }

    [Fact]
    public void StencilMaskOfAnotherSizeIsSampledNearest()
    {
        var streams = new FilterFixtures.Streams();
        var mask = streams.Add("<< /Width 8 /Height 1 /ImageMask true >>", [0b00001111]);
        var image = Convert("<< /Width 2 /Height 1 /BitsPerComponent 8 /ColorSpace /DeviceGray >>", [10, 20], streams, d => d["Mask"] = mask);
        Assert.Equal(255, Px(image, 0, 0)[3]);
        Assert.Equal(0, Px(image, 1, 0)[3]);
    }

    [Fact]
    public void MissingSamplesReadAsZero()
    {
        var image = Convert("<< /Width 2 /Height 3 /BitsPerComponent 8 /ColorSpace /DeviceGray >>", [200, 100, 50]);
        Assert.Equal(50, Px(image, 0, 1)[0]);
        Assert.Equal(0, Px(image, 1, 1)[0]);
        Assert.Equal(0, Px(image, 0, 2)[0]);
        Assert.Equal(255, Px(image, 1, 2)[3]);
    }

    [Fact]
    public void MissingColorSpaceIsGuessedFromTheSampleCount()
    {
        Assert.Equal(new byte[] { 1, 2, 3, 255 }, Px(Convert("<< /Width 1 /Height 1 /BitsPerComponent 8 >>", [1, 2, 3]), 0, 0));
        Assert.Equal(new byte[] { 9, 9, 9, 255 }, Px(Convert("<< /Width 1 /Height 1 /BitsPerComponent 8 >>", [9]), 0, 0));
        Assert.Equal(new byte[] { 0, 0, 0, 255 }, Px(Convert("<< /Width 1 /Height 1 /BitsPerComponent 8 >>", [0, 0, 0, 255]), 0, 0));
        var e = Assert.Throws<PdfReadException>(() => Convert("<< /Width 1 /Height 1 /BitsPerComponent 8 >>", [1, 2]));
        Assert.Equal(PdfReadProblem.Damaged, e.Problem);
    }

    [Fact]
    public void InlineImageKeysAreRead()
    {
        var image = Convert("<< /W 2 /H 1 /BPC 8 /CS /G >>", [10, 20]);
        Assert.Equal(2, image.Width);
        Assert.Equal(10, Px(image, 0, 0)[0]);
        var mask = Convert("<< /W 8 /H 1 /IM true /D [1 0] >>", [0x0F]);
        Assert.Equal(0, Px(mask, 0, 0)[3]);
        Assert.Equal(255, Px(mask, 7, 0)[3]);
    }

    [Theory]
    [InlineData("<< /Width 0 /Height 1 /ColorSpace /DeviceGray >>", PdfReadProblem.Damaged)]
    [InlineData("<< /Width 1 /Height -4 /ColorSpace /DeviceGray >>", PdfReadProblem.Damaged)]
    [InlineData("<< /Height 1 /ColorSpace /DeviceGray >>", PdfReadProblem.Damaged)]
    [InlineData("<< /Width 1 /Height 1 /BitsPerComponent 3 /ColorSpace /DeviceGray >>", PdfReadProblem.Damaged)]
    [InlineData("<< /Width 100000 /Height 100000 /BitsPerComponent 8 /ColorSpace /DeviceGray >>", PdfReadProblem.Unsupported)]
    [InlineData("<< /Width 2000000000 /Height 2000000000 /ColorSpace /DeviceRGB >>", PdfReadProblem.Unsupported)]
    [InlineData("<< /Width 1 /Height 1 /ColorSpace [/Pattern] >>", PdfReadProblem.Unsupported)]
    [InlineData("<< /Width 1 /Height 1 /ColorSpace /Cs7 >>", PdfReadProblem.Unsupported)]
    [InlineData("<< /Width 1 /Height 1 /ColorSpace 12 >>", PdfReadProblem.Damaged)]
    [InlineData("<< /Width 1 /Height 1 /ColorSpace [/Indexed /DeviceRGB 1] >>", PdfReadProblem.Damaged)]
    [InlineData("<< /Width 1 /Height 1 /ColorSpace [/Separation /X /DeviceGray] >>", PdfReadProblem.Damaged)]
    public void BadImagesAreRefusedBeforeAnyAllocation(string dictionary, PdfReadProblem problem)
    {
        var e = Assert.Throws<PdfReadException>(() => Convert(dictionary, [0]));
        Assert.Equal(problem, e.Problem);
    }

    [Fact]
    public void ARowTooWideForTheLimitIsUnsupported()
    {
        var e = Assert.Throws<PdfReadException>(() =>
            Convert("<< /Width 134000000 /Height 1 /BitsPerComponent 8 /ColorSpace /DeviceRGB >>", []));
        Assert.Equal(PdfReadProblem.Unsupported, e.Problem);
    }

    [Fact]
    public void BigImageConvertsInReasonableTime()
    {
        var samples = FilterFixtures.RandomBytes(2000 * 2000 * 3);
        var watch = System.Diagnostics.Stopwatch.StartNew();
        var image = Convert("<< /Width 2000 /Height 2000 /BitsPerComponent 8 /ColorSpace /DeviceRGB >>", samples);
        Assert.Equal(2000 * 2000 * 4, image.Rgba.Length);
        Assert.True(watch.Elapsed < TimeSpan.FromSeconds(5));
    }
}
