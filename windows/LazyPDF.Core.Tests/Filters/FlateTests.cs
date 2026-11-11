using System.IO.Compression;
using Xunit;

namespace LazyPDF.Core.Tests;

public class FlateTests
{
    private static PdfName Name(string value) => new(value);

    [Theory]
    [InlineData(CompressionLevel.Optimal)]
    [InlineData(CompressionLevel.Fastest)]
    [InlineData(CompressionLevel.NoCompression)]
    [InlineData(CompressionLevel.SmallestSize)]
    public void EncodedDataDecodesAtEveryLevel(CompressionLevel level)
    {
        var data = FilterFixtures.Text(50_000);
        var packed = PdfFilterEncoders.Flate(data, level);
        Assert.Equal(data, PdfFilters.Decode(packed, Name("FlateDecode"), null));
    }

    [Fact]
    public void SmallestSizeIsNotLargerThanFastest()
    {
        var data = FilterFixtures.Text(50_000);
        Assert.True(PdfFilterEncoders.Flate(data, CompressionLevel.SmallestSize).Length <= PdfFilterEncoders.Flate(data, CompressionLevel.Fastest).Length);
    }

    [Fact]
    public void EmptyDataIsEmpty()
    {
        Assert.Empty(PdfFilters.Decode([], Name("FlateDecode"), null));
        Assert.Empty(PdfFilters.Decode(PdfFilterEncoders.Flate([]), Name("Fl"), null));
    }

    [Fact]
    public void CleanEmptyStreamIsEmpty()
    {
        Assert.Empty(PdfFilters.Decode([0x78, 0x9C, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01], Name("FlateDecode"), null));
        Assert.Empty(PdfFilters.Decode([0x03, 0x00], Name("FlateDecode"), null));
    }

    [Theory]
    [InlineData(new byte[] { 0x78, 0x9C })]
    [InlineData(new byte[] { 0xFF, 0xFF, 0xFF })]
    [InlineData(new byte[] { 0x78, 0x9C, 0x01, 0x05, 0x00 })]
    public void EmptyResultWithoutACleanEndIsDamaged(byte[] data)
    {
        var e = Assert.Throws<PdfReadException>(() => PdfFilters.Decode(data, Name("FlateDecode"), null));
        Assert.Equal(PdfReadProblem.Damaged, e.Problem);
        Assert.Equal("A compressed stream does not inflate.", e.Message);
    }

    [Fact]
    public void TruncatedDataGivesWhatDecoded()
    {
        var data = FilterFixtures.RandomBytes(40_000);
        var packed = PdfFilterEncoders.Flate(data, CompressionLevel.NoCompression);
        var decoded = PdfFilters.Decode(packed[..(packed.Length / 2)], Name("FlateDecode"), null);
        Assert.NotEmpty(decoded);
        Assert.True(decoded.Length < data.Length);
        Assert.Equal(data[..decoded.Length], decoded);
    }

    [Fact]
    public void StrictDecodingTakesABreakOffForDamage()
    {
        var data = FilterFixtures.Text(100_000);
        var packed = PdfFilterEncoders.Flate(data);
        var cut = packed[..(packed.Length / 2)];
        Assert.NotEmpty(PdfFilters.Decode(cut, Name("FlateDecode"), null));
        var e = Assert.Throws<PdfReadException>(() => PdfFilters.Decode(cut, Name("FlateDecode"), null, PdfFilters.DefaultMaxSize, strict: true));
        Assert.Equal(PdfReadProblem.Damaged, e.Problem);
        Assert.Equal("A compressed stream breaks off.", e.Message);
        Assert.Equal(data, PdfFilters.Decode(packed, Name("FlateDecode"), null, PdfFilters.DefaultMaxSize, strict: true));
        Assert.Equal(data, PdfFilters.Decode(packed[..^4], Name("FlateDecode"), null, PdfFilters.DefaultMaxSize, strict: true));
    }

    [Fact]
    public void BadChecksumStillGivesTheData()
    {
        var data = FilterFixtures.Text(10_000);
        var packed = PdfFilterEncoders.Flate(data);
        packed[^1] ^= 0xFF;
        Assert.Equal(data, PdfFilters.Decode(packed, Name("FlateDecode"), null));
    }

    [Fact]
    public void MissingChecksumStillGivesTheData()
    {
        var data = FilterFixtures.Text(10_000);
        var packed = PdfFilterEncoders.Flate(data);
        Assert.Equal(data, PdfFilters.Decode(packed[..^4], Name("FlateDecode"), null));
    }

    [Fact]
    public void RawDeflateIsAccepted()
    {
        var data = FilterFixtures.Text(10_000);
        using var output = new MemoryStream();
        using (var d = new DeflateStream(output, CompressionLevel.Optimal, leaveOpen: true)) d.Write(data);
        Assert.Equal(data, PdfFilters.Inflate(output.ToArray()));
    }

    [Fact]
    public void GarbageIsDamaged()
    {
        var e = Assert.Throws<PdfReadException>(() => PdfFilters.Decode(FilterFixtures.RandomBytes(500, 3), Name("FlateDecode"), null));
        Assert.Equal(PdfReadProblem.Damaged, e.Problem);
    }

    [Fact]
    public void ExpansionPastTheCapIsUnsupported()
    {
        var packed = PdfFilterEncoders.Flate(new byte[20_000_000]);
        Assert.True(packed.Length < 100_000);
        var e = Assert.Throws<PdfReadException>(() => PdfFilters.Decode(packed, Name("FlateDecode"), null, 1_000_000));
        Assert.Equal(PdfReadProblem.Unsupported, e.Problem);
        Assert.Equal(20_000_000, PdfFilters.Decode(packed, Name("FlateDecode"), null, 20_000_000).Length);
    }
}
