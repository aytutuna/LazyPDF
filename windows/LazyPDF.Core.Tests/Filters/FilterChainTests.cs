using Xunit;

namespace LazyPDF.Core.Tests;

public class FilterChainTests
{
    private static readonly byte[] Plain = FilterFixtures.Text(5000);

    [Fact]
    public void NoFilterLeavesDataAlone()
    {
        Assert.Same(Plain, PdfFilters.Decode(Plain, null, null));
        Assert.Same(Plain, PdfFilters.Decode(Plain, PdfNull.Instance, null));
        Assert.Same(Plain, PdfFilters.Decode(Plain, new PdfArray([]), null));
    }

    [Fact]
    public void ChainRunsInOrder()
    {
        // Written as Flate, then ASCII85, so read as ASCII85 first.
        var stored = PdfFilterEncoders.Ascii85(PdfFilterEncoders.Flate(Plain));
        Assert.Equal(Plain, PdfFilters.Decode(stored, FilterFixtures.Parse("[/ASCII85Decode /FlateDecode]"), null));
        Assert.Equal(Plain, PdfFilters.Decode(stored, FilterFixtures.Parse("[/A85 /Fl]"), null));
    }

    [Fact]
    public void EachFilterGetsItsOwnParameters()
    {
        int rowLength = 4;
        var rows = new byte[] { 1, 2, 3, 4, 5, 6, 7, 8 };
        var predicted = new byte[] { 2, 1, 2, 3, 4, 2, 4, 4, 4, 4 };
        var stored = PdfFilterEncoders.AsciiHex(PdfFilterEncoders.Flate(predicted));
        var parms = FilterFixtures.Parse($"[null << /Predictor 12 /Columns {rowLength} >>]");
        Assert.Equal(rows, PdfFilters.Decode(stored, FilterFixtures.Parse("[/AHx /Fl]"), parms));
    }

    [Fact]
    public void ADictionaryOfParametersGoesToASingleFilter()
    {
        var predicted = new byte[] { 1, 5, 1, 1 };
        var stored = PdfFilterEncoders.Flate(predicted);
        var result = PdfFilters.Decode(stored, new PdfName("FlateDecode"), FilterFixtures.Parse("<< /Predictor 15 /Columns 3 >>"));
        Assert.Equal(new byte[] { 5, 6, 7 }, result);
    }

    [Theory]
    [InlineData("FlateDecode")]
    [InlineData("Fl")]
    public void FlateNames(string name)
    {
        Assert.Equal(Plain, PdfFilters.Decode(PdfFilterEncoders.Flate(Plain), new PdfName(name), null));
    }

    [Theory]
    [InlineData("LZWDecode")]
    [InlineData("LZW")]
    public void LzwNames(string name)
    {
        Assert.Equal(Plain, PdfFilters.Decode(PdfFilterEncoders.Lzw(Plain), new PdfName(name), null));
    }

    [Fact]
    public void CryptIdentityPassesThrough()
    {
        Assert.Same(Plain, PdfFilters.Decode(Plain, new PdfName("Crypt"), null));
        Assert.Same(Plain, PdfFilters.Decode(Plain, new PdfName("Crypt"), FilterFixtures.Parse("<< /Type /CryptFilterDecodeParms /Name /Identity >>")));
        var stored = PdfFilterEncoders.Flate(Plain);
        Assert.Equal(Plain, PdfFilters.Decode(stored, FilterFixtures.Parse("[/Crypt /FlateDecode]"), FilterFixtures.Parse("[<< /Name /Identity >> null]")));
    }

    [Fact]
    public void CryptWithAnotherNameIsUnsupported()
    {
        var e = Assert.Throws<PdfReadException>(() =>
            PdfFilters.Decode(Plain, new PdfName("Crypt"), FilterFixtures.Parse("<< /Name /StdCF >>")));
        Assert.Equal(PdfReadProblem.Unsupported, e.Problem);
    }

    [Fact]
    public void UnknownFilterIsUnsupported()
    {
        var e = Assert.Throws<PdfReadException>(() => PdfFilters.Decode(Plain, new PdfName("FooDecode"), null));
        Assert.Equal(PdfReadProblem.Unsupported, e.Problem);
    }

    [Fact]
    public void FilterThatIsNotANameIsDamaged()
    {
        var e = Assert.Throws<PdfReadException>(() => PdfFilters.Decode(Plain, new PdfNumber(3), null));
        Assert.Equal(PdfReadProblem.Damaged, e.Problem);
    }

    [Theory]
    [InlineData("DCTDecode", "DCTDecode")]
    [InlineData("DCT", "DCTDecode")]
    [InlineData("JPXDecode", "JPXDecode")]
    [InlineData("JBIG2Decode", "JBIG2Decode")]
    public void CodecIsReportedWithItsInput(string filter, string codec)
    {
        var result = PdfFilters.DecodeToCodec(Plain, new PdfName(filter), null);
        Assert.Equal(codec, result.Codec);
        Assert.Same(Plain, result.Data);
        Assert.Null(result.Parameters);
    }

    [Fact]
    public void ChainStopsAtTheCodecAndKeepsItsParameters()
    {
        var jpeg = new byte[] { 0xFF, 0xD8, 1, 2, 3, 0xFF, 0xD9 };
        var stored = PdfFilterEncoders.Flate(PdfFilterEncoders.Ascii85(jpeg));
        var parms = FilterFixtures.Parse("[null null << /ColorTransform 0 >>]");
        var result = PdfFilters.DecodeToCodec(stored, FilterFixtures.Parse("[/Fl /A85 /DCT]"), parms);
        Assert.Equal("DCTDecode", result.Codec);
        Assert.Equal(jpeg, result.Data);
        Assert.NotNull(result.Parameters);

        var inner = PdfFilterEncoders.Flate(jpeg);
        var chained = PdfFilters.DecodeToCodec(inner, FilterFixtures.Parse("[/Fl /DCTDecode]"), FilterFixtures.Parse("[null << /ColorTransform 0 >>]"));
        Assert.Equal(jpeg, chained.Data);
        Assert.Equal("0", ((PdfNumber)chained.Parameters!["ColorTransform"]!).Text);
    }

    [Fact]
    public void WithoutACodecDecodeToCodecDecodesEverything()
    {
        var result = PdfFilters.DecodeToCodec(PdfFilterEncoders.Flate(Plain), new PdfName("Fl"), null);
        Assert.Null(result.Codec);
        Assert.Equal(Plain, result.Data);
    }

    [Fact]
    public void PlainDecodeRefusesACodec()
    {
        var e = Assert.Throws<PdfReadException>(() => PdfFilters.Decode(Plain, new PdfName("DCTDecode"), null));
        Assert.Equal(PdfReadProblem.Unsupported, e.Problem);
    }

    [Fact]
    public void CapAppliesAcrossTheChain()
    {
        var stored = PdfFilterEncoders.Ascii85(PdfFilterEncoders.Flate(new byte[5_000_000]));
        var e = Assert.Throws<PdfReadException>(() =>
            PdfFilters.Decode(stored, FilterFixtures.Parse("[/A85 /Fl]"), null, 1_000_000));
        Assert.Equal(PdfReadProblem.Unsupported, e.Problem);
    }

    [Fact]
    public void DefaultCapIs256Mebibytes()
    {
        Assert.Equal(256L << 20, PdfFilters.DefaultMaxSize);
    }

    [Fact]
    public void BombThroughTwoFiltersStillStops()
    {
        // Each layer multiplies the size.
        var layer1 = PdfFilterEncoders.Flate(new byte[10_000_000]);
        var layer2 = PdfFilterEncoders.Flate(layer1);
        var e = Assert.Throws<PdfReadException>(() => PdfFilters.Decode(layer2, FilterFixtures.Parse("[/Fl /Fl]"), null, 5_000_000));
        Assert.Equal(PdfReadProblem.Unsupported, e.Problem);
    }
}
