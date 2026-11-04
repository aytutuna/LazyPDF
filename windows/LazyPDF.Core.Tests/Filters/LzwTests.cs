using Xunit;

namespace LazyPDF.Core.Tests;

public class LzwTests
{
    private static byte[] Decode(byte[] data, string? parms = null) =>
        PdfFilters.Decode(data, new PdfName("LZWDecode"), parms is null ? null : FilterFixtures.Dict(parms));

    private static readonly byte[] SpecPlain = [45, 45, 45, 45, 45, 65, 45, 45, 45, 66];
    private static readonly byte[] SpecCoded = [0x80, 0x0B, 0x60, 0x50, 0x22, 0x0C, 0x0C, 0x85, 0x01];

    [Fact]
    public void SpecExampleDecodes()
    {
        // ISO 32000-1 7.4.4.2.
        Assert.Equal(SpecPlain, Decode(SpecCoded));
    }

    [Fact]
    public void EncoderMatchesTheSpecExample()
    {
        Assert.Equal(SpecCoded, PdfFilterEncoders.Lzw(SpecPlain));
    }

    [Theory]
    [InlineData(0, true)]
    [InlineData(1, true)]
    [InlineData(2, true)]
    [InlineData(300, true)]
    [InlineData(5000, true)]
    [InlineData(200_000, true)]
    [InlineData(0, false)]
    [InlineData(5000, false)]
    [InlineData(200_000, false)]
    public void TextRoundTripsAcrossCodeWidthsAndTableResets(int length, bool early)
    {
        var data = FilterFixtures.Text(length);
        var encoded = PdfFilterEncoders.Lzw(data, early);
        Assert.Equal(data, Decode(encoded, early ? null : "<< /EarlyChange 0 >>"));
    }

    [Fact]
    public void RandomDataRoundTripsAndRepeatedBytesToo()
    {
        var random = FilterFixtures.RandomBytes(100_000, 8);
        Assert.Equal(random, Decode(PdfFilterEncoders.Lzw(random)));
        var flat = new byte[300_000];
        Assert.Equal(flat, Decode(PdfFilterEncoders.Lzw(flat)));
    }

    [Fact]
    public void WrongEarlyChangeDoesNotMatch()
    {
        var data = FilterFixtures.Text(20_000);
        var decoded = Decode(PdfFilterEncoders.Lzw(data, earlyChange: true), "<< /EarlyChange 0 >>");
        Assert.NotEqual(data, decoded);
    }

    [Fact]
    public void CodeBeyondTheTableEndsTheOutput()
    {
        // Clear, a literal, then code 400 which is not in the table.
        var bits = new List<bool>();
        void Put(int code)
        {
            for (int i = 8; i >= 0; i--) bits.Add((code >> i & 1) != 0);
        }
        Put(256);
        Put(65);
        Put(400);
        Put(66);
        var bytes = new byte[(bits.Count + 7) / 8];
        for (int i = 0; i < bits.Count; i++)
        {
            if (bits[i]) bytes[i / 8] |= (byte)(0x80 >> i % 8);
        }
        Assert.Equal(new byte[] { 65 }, Decode(bytes));
    }

    [Fact]
    public void MissingEndCodeGivesWhatDecoded()
    {
        var data = FilterFixtures.Text(1000);
        var encoded = PdfFilterEncoders.Lzw(data);
        var decoded = Decode(encoded[..(encoded.Length / 2)]);
        Assert.NotEmpty(decoded);
        Assert.Equal(data[..decoded.Length], decoded);
    }

    [Fact]
    public void ExpansionPastTheCapIsUnsupported()
    {
        var encoded = PdfFilterEncoders.Lzw(new byte[2_000_000]);
        var e = Assert.Throws<PdfReadException>(() => PdfFilters.Decode(encoded, new PdfName("LZW"), null, 100_000));
        Assert.Equal(PdfReadProblem.Unsupported, e.Problem);
    }
}
