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

    private static byte[] Be16(int v) => [(byte)(v >> 8), (byte)v];

    private static byte[] Be32(long v) => [(byte)(v >> 24), (byte)(v >> 16), (byte)(v >> 8), (byte)v];

    // A codestream by hand: SIZ, COD without decomposition levels, QCD, optional extra main header segments, and one tile-part with
    // no packets and optional header segments of its own. Only its structure matters, so it never holds a picture.
    private static byte[] Hostile(int width, int height, int tile, int blockExp, bool smallPrecincts, byte[]? extra = null, int components = 1, byte[]? tileExtra = null, int layers = 1)
    {
        byte[] siz = [.. Be16(0xFF51), .. Be16(38 + 3 * components), 0, 0, .. Be32(width), .. Be32(height), .. Be32(0), .. Be32(0), .. Be32(tile), .. Be32(tile), .. Be32(0), .. Be32(0), .. Be16(components), .. Enumerable.Repeat(new byte[] { 7, 1, 1 }, components).SelectMany(b => b)];
        byte[] qcd = [.. Be16(0xFF5C), .. Be16(4), 0x40, 0x40];
        return [.. Be16(0xFF4F), .. siz, .. Cod(layers, blockExp, smallPrecincts), .. qcd, .. extra ?? [], .. Be16(0xFF90), .. Be16(10), 0, 0, .. Be32(0), 0, 1, .. tileExtra ?? [], .. Be16(0xFF93), .. Be16(0xFFD9)];
    }

    // The precincts of a small-precinct segment: one sample at the lowest resolution, two above it.
    private static byte[] Precincts(int levels) => [0, .. Enumerable.Repeat((byte)0x11, levels)];

    private static byte[] Cod(int layers, int blockExp, bool smallPrecincts, int levels = 0, byte[]? precincts = null)
    {
        precincts ??= smallPrecincts ? Precincts(levels) : [];
        return [.. Be16(0xFF52), .. Be16(12 + precincts.Length), (byte)(smallPrecincts ? 1 : 0), 0, .. Be16(layers), 0, (byte)levels, (byte)blockExp, (byte)blockExp, 0, 1, .. precincts];
    }

    private static byte[] Coc(int component, bool smallPrecincts, int levels = 0)
    {
        byte[] precincts = smallPrecincts ? Precincts(levels) : [];
        return [.. Be16(0xFF53), .. Be16(9 + precincts.Length), (byte)component, (byte)(smallPrecincts ? 1 : 0), (byte)levels, 0, 0, 0, 1, .. precincts];
    }

    // A 64 KB MCT record, which OpenJPEG copies into the coding parameters of every tile.
    private static byte[] MctRecord() => [.. Be16(0xFF74), .. Be16(65535), .. Be16(0), .. Be16(1), .. Be16(0), .. new byte[65535 - 8]];

    private static void AssertRefused(byte[] file, long budget)
    {
        var watch = System.Diagnostics.Stopwatch.StartNew();
        Assert.Null(OpenJpeg.Decode(file, 0, budget));
        Assert.True(watch.Elapsed < TimeSpan.FromSeconds(10), watch.Elapsed.ToString());
        Assert.Equal((nuint)0, OpenJpeg.lazypdf_opj_used());
    }

    [Fact]
    public void AnMctRecordCopiedIntoEveryTileStaysWithinTheBudget() =>
        AssertRefused(Hostile(64, 64, 1, 4, false, MctRecord()), 16 << 20);

    [Fact]
    public void TinyPrecinctsAndBlocksStayWithinTheBudget() =>
        AssertRefused(Hostile(8000, 8000, 8000, 0, true), 1L << 30);

    // A 92 x 92 tile of one-sample precincts is 8464 packets a layer. At 65535 layers that takes hours to walk, which the
    // memory budget does not stop.
    [Theory]
    [InlineData(65535)]
    [InlineData(1025)]
    [InlineData(1024)]
    public void TooManyLayersOrPacketsAreRefusedBeforeDecoding(int layers)
    {
        byte[] file = Hostile(92, 92, 92, 0, true, layers: layers);
        AssertRefusedFast(file);
        Assert.False(OpenJpeg.Plausible(file));
    }

    [Fact]
    public void LayersAndPrecinctsUnderTheBoundAreAccepted()
    {
        // 400 layers of 8464 packets is 3.4 million; 1000 layers of one packet a tile is next to nothing.
        Assert.True(OpenJpeg.Plausible(Hostile(92, 92, 92, 0, true, layers: 400)));
        Assert.True(OpenJpeg.Plausible(Hostile(92, 92, 92, 0, false, layers: 1000)));
    }

    [Fact]
    public void ATilePartHeaderThatRestatesTheCodingIsCounted()
    {
        // The tile's own COC cuts the first component into one-sample precincts, which the main header knew nothing of.
        Assert.False(OpenJpeg.Plausible(Hostile(92, 92, 92, 0, false, layers: 1000, tileExtra: Coc(0, true))));
        Assert.False(OpenJpeg.Plausible(Hostile(92, 92, 92, 0, false, tileExtra: Cod(1000, 0, true))));
        // A COD of its own that has no precincts takes the main header's away again, a main COC's too.
        Assert.True(OpenJpeg.Plausible(Hostile(92, 92, 92, 0, true, layers: 1000, tileExtra: Cod(1000, 0, false))));
        Assert.True(OpenJpeg.Plausible(Hostile(92, 92, 92, 0, false, extra: Coc(0, true), layers: 1000, tileExtra: Cod(1000, 0, false))));
        Assert.False(OpenJpeg.Plausible(Hostile(92, 92, 92, 0, false, extra: Coc(0, true), layers: 1000)));
    }

    [Fact]
    public void ACodOpenJpegWouldRefuseIsRefused()
    {
        Assert.True(OpenJpeg.Plausible(Hostile(64, 64, 64, 0, false, extra: Cod(1, 0, false, 32))));
        Assert.False(OpenJpeg.Plausible(Hostile(64, 64, 64, 0, false, extra: Cod(1, 0, false, 33))));
        Assert.False(OpenJpeg.Plausible(Hostile(64, 64, 64, 0, false, extra: Cod(1025, 0, false))));
        Assert.False(OpenJpeg.Plausible(Hostile(64, 64, 64, 0, false, extra: Cod(1, 9, false))));
        // An exponent of 0 above the lowest resolution.
        Assert.False(OpenJpeg.Plausible(Hostile(64, 64, 64, 0, false, extra: Cod(1, 0, true, 1, [0, 0x10]))));
        Assert.True(OpenJpeg.Plausible(Hostile(64, 64, 64, 0, false, extra: Cod(1, 0, true, 1, [0, 0x11]))));
    }

    [Fact]
    public void AMalformedMarkerLengthGivesNull()
    {
        Assert.True(OpenJpeg.Plausible(Hostile(64, 64, 64, 0, false, extra: [.. Be16(0xFF64), .. Be16(6), 1, 2, 3, 4])));
        foreach (int length in new[] { 0, 1, 7, 60000, 65535 })
        {
            Assert.False(OpenJpeg.Plausible(Hostile(64, 64, 64, 0, false, extra: [.. Be16(0xFF64), .. Be16(length), 1, 2, 3, 4])), length.ToString());
        }
        byte[] file = Hostile(64, 64, 64, 0, false);
        Assert.False(OpenJpeg.Plausible(file[..30]));
        Assert.False(OpenJpeg.Plausible(file[..^4]));
        // Psot of 5, below the 14 bytes of a SOT and a SOD; its low half sits 8 bytes from the end.
        PutShort(file, file.Length - 8, 5);
        Assert.False(OpenJpeg.Plausible(file));
    }

    [Fact]
    public void RealLayeredAndPrecinctPartitionedPicturesStillDecode()
    {
        var random = new Random(3);
        int[] Noise() => [.. Enumerable.Range(0, 96 * 96).Select(_ => random.Next(256))];
        int[] ramp = [.. Enumerable.Range(0, 96 * 96).Select(i => (i % 96 * 2 + i / 96) % 256)];
        foreach (var (layers, precinct) in new[] { (5, 0), (1, 32), (5, 32), (12, 16) })
        {
            int[] r = Noise(), g = ramp, b = Noise();
            byte[] file = Layered(96, 96, layers, precinct, new Comp(8, r), new Comp(8, g), new Comp(8, b));
            Assert.True(OpenJpeg.Plausible(file), $"{layers} layers, precincts {precinct}");
            var image = Read(file);
            for (int i = 0; i < r.Length; i++) Assert.Equal([r[i], g[i], b[i], 255], image.Rgba[(i * 4)..(i * 4 + 4)].Select(v => (int)v));
        }
    }

    [Fact]
    public void ManyOnePixelTilesAreRefusedFromTheHeader() =>
        AssertRefused(Hostile(255, 257, 1, 4, false, MctRecord()), 1L << 30);

    [Fact]
    public void ADecodeThatSucceedsLeavesNothingCharged()
    {
        Read(Encode(8, 8, Gray, false, false, new Comp(8, Ramp(64, 255))));
        Assert.Equal((nuint)0, OpenJpeg.lazypdf_opj_used());
    }

    [Fact]
    public void AMultiTilePictureStillDecodes()
    {
        int[] gray = [.. Enumerable.Range(0, 100 * 100).Select(i => i * 7 % 256)];
        var image = Read(Tiled(100, 100, 32, new Comp(8, gray)));

        Assert.Equal((100, 100), (image.Width, image.Height));
        for (int i = 0; i < gray.Length; i++) Assert.Equal(gray[i], image.Rgba[i * 4]);
    }

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
        var image = Read(Encode(8, 8, Srgb, true, false, rgb, rgb with { Samples = [.. Enumerable.Repeat(100, 64)] }, rgb with { Samples = [.. Enumerable.Repeat(50, 64)] }, new Comp(1, 1, 8, false, alpha, 1)));

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

    private static Comp Flat(int value) => new(8, Enumerable.Repeat(value, 64).ToArray());

    [Fact]
    public void PremultipliedOpacityIsUndoneInTheColour()
    {
        byte[] code = Encode(8, 8, Unspecified, false, false, Flat(100), Flat(50), Flat(20), Flat(128));
        var image = Read(Wrap(8, 8, 4, code, Colr(Srgb + 15), Cdef((0, 1), (0, 2), (0, 3), (2, 0))));

        Assert.Equal([199, 100, 40, 128], image.Rgba[..4].Select(v => (int)v));
    }

    [Fact]
    public void AnExtraChannelOfUnspecifiedTypeIsNeitherColourNorOpacity()
    {
        byte[] code = Encode(8, 8, Unspecified, false, false, Flat(10), Flat(20), Flat(30), Flat(40));
        var image = Read(Wrap(8, 8, 4, code, Colr(Srgb + 15), Cdef((0, 1), (0, 2), (0, 3), (65535, 65535))));

        Assert.Equal([10, 20, 30, 255], image.Rgba[..4].Select(v => (int)v));
    }

    [Fact]
    public void AllChannelsOfUnspecifiedTypeStillGiveTheColour()
    {
        byte[] code = Encode(8, 8, Unspecified, false, false, Flat(10), Flat(20), Flat(30));
        var image = Read(Wrap(8, 8, 3, code, Colr(Srgb + 15), Cdef((65535, 65535), (65535, 65535), (65535, 65535))));

        Assert.Equal([10, 20, 30, 255], image.Rgba[..4].Select(v => (int)v));
    }

    [Fact]
    public void FourComponentsWithoutAColourBoxAreRgbaWhenThePdfSaysThreeAreColour()
    {
        byte[] file = Encode(8, 8, Unspecified, false, false, Flat(10), Flat(20), Flat(30), Flat(200));

        Assert.NotEqual([10, 20, 30, 200], Read(file).Rgba[..4].Select(v => (int)v));
        Assert.Equal([10, 20, 30, 200], OpenJpeg.Decode(file, 3)!.Rgba[..4].Select(v => (int)v));
        Assert.Equal([10, 10, 10, 20], OpenJpeg.Decode(Encode(8, 8, Unspecified, false, false, Flat(10), Flat(20)), 1)!.Rgba[..4].Select(v => (int)v));
    }

    [Fact]
    public void AllComponentsSubsampledTheSameWayAreNotYcc()
    {
        var plane = new Comp(2, 2, 8, false, Enumerable.Repeat(200, 16).ToArray());
        var rgb = Read(Encode(8, 8, Unspecified, false, false, plane, plane with { Samples = [.. Enumerable.Repeat(100, 16)] }, plane with { Samples = [.. Enumerable.Repeat(50, 16)] }));
        Assert.Equal([200, 100, 50, 255], rgb.Rgba[..4].Select(v => (int)v));

        var chroma = new Comp(2, 2, 8, false, Enumerable.Repeat(168, 16).ToArray());
        var ycc = Read(Encode(8, 8, Unspecified, false, false, Flat(100), chroma, plane with { Samples = [.. Enumerable.Repeat(128, 16)] }));
        Assert.NotEqual([100, 168, 128], ycc.Rgba[..3].Select(v => (int)v));
    }

    [Fact]
    public void ACielabPictureIsNotRead()
    {
        byte[] code = Encode(8, 8, Unspecified, false, false, Flat(50), Flat(128), Flat(128));

        Assert.Null(OpenJpeg.Decode(Wrap(8, 8, 3, code, Colr(14))));
    }

    // A few hundred bytes of header over a picture the size of the pixel cap, with a palette of many channels.
    private static (byte[] Code, byte[] Pclr, byte[] Cmap) HostilePalette(int channels)
    {
        byte[] code = Encode(8, 8, Unspecified, false, false, Flat(0));
        foreach (int at in new[] { 8, 12, 24, 28 }) Put(code, at, 11585);
        var pclr = new List<byte> { 0, 1, (byte)channels };
        pclr.AddRange(Enumerable.Repeat((byte)7, channels));
        pclr.AddRange(Enumerable.Repeat((byte)1, channels));
        var cmap = Enumerable.Range(0, channels).SelectMany(i => new byte[] { 0, 0, 1, (byte)i }).ToArray();
        return (code, [.. pclr], cmap);
    }

    private static void AssertRefusedFast(byte[] file)
    {
        var watch = System.Diagnostics.Stopwatch.StartNew();
        Assert.Null(OpenJpeg.Decode(file));
        Assert.True(watch.Elapsed < TimeSpan.FromSeconds(2));
    }

    [Theory]
    [InlineData(255)]
    [InlineData(3)]
    public void APaletteThatMakesMoreThanTheBudgetHoldsIsRefusedBeforeDecoding(int channels)
    {
        var (code, pclr, cmap) = HostilePalette(channels);
        AssertRefusedFast(Wrap(11585, 11585, 1, code, Colr(Srgb + 15), ("pclr", pclr), ("cmap", cmap)));
    }

    [Fact]
    public void APaletteInABoxAfterTheHeaderIsRefused()
    {
        var (code, pclr, cmap) = HostilePalette(255);
        var file = Wrap(11585, 11585, 1, code, Colr(Srgb + 15));
        file = Before(file, code.Length, "cmap", cmap);
        file = Before(file, code.Length + 8 + cmap.Length, "pclr", pclr);
        AssertRefusedFast(file);
    }

    [Fact]
    public void APaletteInASecondHeaderBoxIsRefused()
    {
        var (code, pclr, cmap) = HostilePalette(255);
        var file = Before(Wrap(11585, 11585, 1, code, Colr(Srgb + 15)), code.Length, "jp2h", Boxes(("pclr", pclr), ("cmap", cmap)));
        AssertRefusedFast(file);
    }

    [Fact]
    public void ASecondHeaderBoxIsRefusedEvenWithoutAPalette()
    {
        byte[] code = Encode(8, 8, Gray, false, false, Flat(0));
        Assert.NotNull(OpenJpeg.Decode(Wrap(8, 8, 1, code, Colr(Gray + 15))));
        Assert.Null(OpenJpeg.Decode(Before(Wrap(8, 8, 1, code, Colr(Gray + 15)), code.Length, "jp2h", Boxes(Colr(Gray + 15)))));
    }

    [Fact]
    public void ChannelDefinitionsThatAssociateColoursSwapTheChannels()
    {
        byte[] code = Encode(8, 8, Unspecified, false, false, Flat(10), Flat(20), Flat(30));
        byte[] cdef = [0, 3, 0, 0, 0, 0, 0, 3, 0, 1, 0, 0, 0, 2, 0, 2, 0, 0, 0, 1];
        var image = Read(Wrap(8, 8, 3, code, Colr(Srgb + 15), ("cdef", cdef)));

        Assert.Equal([30, 20, 10, 255], image.Rgba[..4].Select(v => (int)v));
    }

    private static void PutShort(byte[] data, int at, int value)
    {
        data[at] = (byte)(value >> 8);
        data[at + 1] = (byte)value;
    }

    // Offsets in a codestream's SIZ: image size 8 and 12, tile size 24 and 28, component count 40.
    [Theory]
    [InlineData(false, 255, 257, 1, 1, 16384)]
    [InlineData(true, 255, 257, 1, 1, 16384)]
    [InlineData(false, 255, 257, 1, 1, 3)]
    [InlineData(true, 4096, 4096, 1, 1, 1)]
    [InlineData(false, 8, 8, 0, 8, 3)]
    [InlineData(false, 8, 8, 8, 8, 6)]
    public void AHeaderThatMakesTheDecoderAllocateTooMuchIsRefusedBeforeOpenJpegReadsIt(bool jp2, int width, int height, int tileWidth, int tileHeight, int components)
    {
        byte[] code = Encode(8, 8, Unspecified, false, false, Flat(1), Flat(2), Flat(3));
        Put(code, 8, width);
        Put(code, 12, height);
        Put(code, 24, tileWidth);
        Put(code, 28, tileHeight);
        PutShort(code, 40, components);
        AssertRefusedFast(jp2 ? Wrap(width, height, 3, code, Colr(Srgb + 15)) : code);
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
