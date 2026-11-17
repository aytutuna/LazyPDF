using System.Text;
using LazyPDF.App.Services;
using LazyPDF.Core;
using Xunit;
using static LazyPDF.App.Tests.JpxMaker;

namespace LazyPDF.App.Tests;

// JPEG 2000 read through the bundled OpenJPEG. The files are made with its own encoder, losslessly.
public sealed class OpenJpegTests
{
    private static int[] Ramp(int count, int top) => [.. Enumerable.Range(0, count).Select(i => i * top / (count - 1))];

    private static byte Scale(int value, int prec) => (byte)((value * 255 + ((1 << prec) - 1) / 2) / ((1 << prec) - 1));

    private static PdfRgbaImage Read(byte[] file) => Assert.IsType<PdfRgbaImage>(OpenJpeg.Decode(file));

    [Fact]
    public void AGrayCodestreamComesBackAsEqualChannels()
    {
        int[] gray = Ramp(64, 255);
        var image = Read(Encode(8, 8, Gray, false, false, new Comp(8, gray)));

        Assert.Equal((8, 8), (image.Width, image.Height));
        for (int i = 0; i < 64; i++) Assert.Equal([gray[i], gray[i], gray[i], 255], image.Rgba[(i * 4)..(i * 4 + 4)].Select(b => (int)b));
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void AnRgbPictureIsExact(bool jp2)
    {
        int[] r = Ramp(64, 255), g = [.. r.Reverse()], b = [.. Enumerable.Range(0, 64).Select(i => i % 8 * 30)];
        var image = Read(Encode(8, 8, Srgb, jp2, true, new Comp(8, r), new Comp(8, g), new Comp(8, b)));

        for (int i = 0; i < 64; i++) Assert.Equal([r[i], g[i], b[i], 255], image.Rgba[(i * 4)..(i * 4 + 4)].Select(v => (int)v));
    }

    [Fact]
    public void AnAlphaChannelFromTheFileHeaderBecomesTheAlpha()
    {
        int[] alpha = Ramp(64, 255);
        var rgb = new Comp(8, Enumerable.Repeat(200, 64).ToArray());
        var image = Read(Encode(8, 8, Srgb, true, false, rgb, rgb with { Samples = [.. Enumerable.Repeat(100, 64)] }, rgb with { Samples = [.. Enumerable.Repeat(50, 64)] }, new Comp(1, 1, 8, false, alpha, true)));

        for (int i = 0; i < 64; i++) Assert.Equal([200, 100, 50, alpha[i]], image.Rgba[(i * 4)..(i * 4 + 4)].Select(v => (int)v));
    }

    [Fact]
    public void ASixteenBitSampleKeepsItsHighByte()
    {
        int[] gray = [0, 0x1234, 0x8000, 0xFFFF, .. Enumerable.Repeat(1000, 60)];
        var image = Read(Encode(8, 8, Gray, false, false, new Comp(16, gray)));

        Assert.Equal([0, 0x12, 0x80, 0xFF], new[] { 0, 1, 2, 3 }.Select(i => (int)image.Rgba[i * 4]));
        Assert.Equal(Scale(1000, 16), image.Rgba[4 * 4]);
    }

    [Fact]
    public void AFourBitSampleSpansTheFullRange()
    {
        int[] gray = [.. Enumerable.Range(0, 64).Select(i => i % 16)];
        var image = Read(Encode(8, 8, Gray, false, false, new Comp(4, gray)));

        for (int i = 0; i < 64; i++) Assert.Equal(gray[i] * 17, image.Rgba[i * 4]);
    }

    [Fact]
    public void AOneBitSampleIsBlackOrWhite()
    {
        int[] bits = [.. Enumerable.Range(0, 64).Select(i => i % 3 == 0 ? 1 : 0)];
        var image = Read(Encode(8, 8, Gray, false, false, new Comp(1, bits)));

        for (int i = 0; i < 64; i++) Assert.Equal(bits[i] * 255, image.Rgba[i * 4]);
    }

    [Fact]
    public void ASignedSampleIsShiftedToTheUnsignedRange()
    {
        int[] gray = [.. Enumerable.Range(0, 64).Select(i => i * 4 - 128)];
        var image = Read(Encode(8, 8, Gray, false, false, new Comp(1, 1, 8, true, gray)));

        for (int i = 0; i < 64; i++) Assert.Equal(gray[i] + 128, image.Rgba[i * 4]);
    }

    [Fact]
    public void SubsampledChromaIsSpreadOverTheFullPicture()
    {
        int[] luma = Enumerable.Repeat(100, 64).ToArray();
        // 4x4 chroma: the left half cb 128 + 40 and the right half cb 128 - 40, cr 128 throughout.
        int[] cb = [.. Enumerable.Range(0, 16).Select(i => i % 4 < 2 ? 168 : 88)];
        int[] cr = Enumerable.Repeat(128, 16).ToArray();
        var image = Read(Encode(8, 8, Sycc, true, false, new Comp(8, luma), new Comp(2, 2, 8, false, cb), new Comp(2, 2, 8, false, cr)));

        for (int y = 0; y < 8; y++)
        {
            foreach (int x in new[] { 0, 1, 6, 7 })
            {
                double d = x < 4 ? 40 : -40;
                int o = (y * 8 + x) * 4;
                Assert.InRange(image.Rgba[o], 99, 101);
                Assert.InRange(image.Rgba[o + 1], Math.Round(100 - 0.344136 * d) - 1, Math.Round(100 - 0.344136 * d) + 1);
                Assert.InRange(image.Rgba[o + 2], Math.Round(100 + 1.772 * d) - 1, Math.Round(100 + 1.772 * d) + 1);
            }
        }
    }

    [Fact]
    public void FourPlainComponentsAreCmykInk()
    {
        var comps = new[] { 255, 0, 0, 51 }.Select(v => new Comp(8, Enumerable.Repeat(v, 64).ToArray())).ToArray();
        var image = Read(Encode(8, 8, Cmyk, true, false, comps));

        // Cyan at full, black at a fifth: no red, and the rest dimmed to four fifths.
        Assert.Equal([0, 204, 204, 255], image.Rgba[..4].Select(v => (int)v));
    }

    [Fact]
    public void APaletteIsApplied()
    {
        byte[][] palette = [[255, 0, 0], [0, 255, 0], [0, 0, 255], [10, 20, 30]];
        int[] indices = [.. Enumerable.Range(0, 64).Select(i => i % 4)];
        var image = Read(Paletted(8, 8, indices, palette));

        for (int i = 0; i < 64; i++) Assert.Equal([.. palette[i % 4], 255], image.Rgba[(i * 4)..(i * 4 + 4)]);
    }

    [Fact]
    public void ADecodeThatIsNotJpeg2000OrIsEmptyGivesNull()
    {
        Assert.Null(OpenJpeg.Decode([]));
        Assert.Null(OpenJpeg.Decode([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13]));
        Assert.Null(OpenJpeg.Decode([0xFF, 0xD8, 0xFF, 0xE0, 0, 16]));
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void ACutOffFileNeverCrashesAndKeepsItsSize(bool jp2)
    {
        var file = Encode(32, 32, Srgb, jp2, true, new Comp(8, Ramp(1024, 255)), new Comp(8, Ramp(1024, 200)), new Comp(8, Ramp(1024, 100)));

        for (int length = 0; length < file.Length; length += 7)
        {
            var image = OpenJpeg.Decode(file[..length]);
            if (image is not null) Assert.Equal((32, 32, 32 * 32 * 4), (image.Width, image.Height, image.Rgba.Length));
        }
    }

    [Fact]
    public void ADamagedFileNeverCrashes()
    {
        var file = Encode(32, 32, Srgb, true, true, new Comp(8, Ramp(1024, 255)), new Comp(8, Ramp(1024, 200)), new Comp(8, Ramp(1024, 100)));
        var random = new Random(7);

        for (int round = 0; round < 300; round++)
        {
            var copy = (byte[])file.Clone();
            for (int hits = random.Next(1, 4); hits > 0; hits--) copy[random.Next(150, copy.Length)] ^= (byte)(1 << random.Next(8));
            var image = OpenJpeg.Decode(copy);
            if (image is not null) Assert.Equal(image.Width * image.Height * 4, image.Rgba.Length);
        }
    }

    [Theory]
    [InlineData(1 << 20, 1 << 20)]
    [InlineData(12000, 12000)]
    public void AHeaderOverThePixelCapGivesNull(int width, int height)
    {
        var file = Encode(8, 8, Gray, false, false, new Comp(8, Ramp(64, 255)));
        // SIZ follows SOC and the marker: length 2, capabilities 2, then size, offsets, tile size.
        Assert.Equal([0xFF, 0x51], file[2..4]);
        foreach (int at in new[] { 8, 24 }) Put(file, at, width);
        foreach (int at in new[] { 12, 28 }) Put(file, at, height);

        Assert.True((long)width * height > PdfImageSamples.MaxPixels);
        Assert.Null(OpenJpeg.Decode(file));
    }

    private static void Put(byte[] data, int at, int value)
    {
        for (int i = 0; i < 4; i++) data[at + i] = (byte)(value >> (24 - 8 * i));
    }

    [Fact]
    public void TheCodecFallsBackToOpenJpegForJpxAndLeavesOtherCodecsAlone()
    {
        var file = Encode(8, 8, Gray, true, false, new Comp(8, Ramp(64, 255)));
        var codec = new WicImageCodec();

        Assert.NotNull(codec.Decode(file, "JPXDecode"));
        Assert.Null(codec.Decode(file, "JBIG2Decode"));
    }

    [Fact]
    public void AJpxPictureInAPdfIsExtractedToPngWithItsPixels()
    {
        int[] r = Ramp(64, 255), g = [.. r.Reverse()], b = [.. Enumerable.Range(0, 64).Select(i => i % 8 * 30)];
        byte[] jpx = Encode(8, 8, Srgb, true, true, new Comp(8, r), new Comp(8, g), new Comp(8, b));

        var codec = new WicImageCodec();
        var found = Assert.Single(ImageExtractor.Extract(PdfDocument.Open(Pdf(jpx)), codec: codec));
        var png = Assert.Single(codec.DecodeFile(found.Image.Data)!);

        Assert.Equal((8, 8), (png.Width, png.Height));
        for (int i = 0; i < 64; i++) Assert.Equal([r[i], g[i], b[i], 255], png.Rgba[(i * 4)..(i * 4 + 4)].Select(v => (int)v));
    }

    private static byte[] Pdf(byte[] jpx)
    {
        var file = new MemoryStream();
        var offsets = new List<long>();
        void Write(string text) => file.Write(Encoding.Latin1.GetBytes(text));
        void Obj(string body, byte[]? stream = null)
        {
            offsets.Add(file.Length);
            Write($"{offsets.Count} 0 obj\n{body}");
            if (stream is not null)
            {
                Write("\nstream\n");
                file.Write(stream);
                Write("\nendstream");
            }
            Write("\nendobj\n");
        }
        Write("%PDF-1.7\n");
        Obj("<< /Type /Catalog /Pages 2 0 R >>");
        Obj("<< /Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 100 100] >>");
        Obj("<< /Type /Page /Parent 2 0 R /Contents 4 0 R /Resources << /XObject << /Im 5 0 R >> >> >>");
        string content = "q 80 0 0 80 10 10 cm /Im Do Q";
        Obj($"<< /Length {content.Length} >>", Encoding.Latin1.GetBytes(content));
        Obj($"<< /Type /XObject /Subtype /Image /Width 8 /Height 8 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /JPXDecode /Length {jpx.Length} >>", jpx);
        long xref = file.Length;
        Write($"xref\n0 {offsets.Count + 1}\n0000000000 65535 f \n");
        foreach (long offset in offsets) Write($"{offset:D10} 00000 n \n");
        Write($"trailer\n<< /Size {offsets.Count + 1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n");
        return file.ToArray();
    }
}
