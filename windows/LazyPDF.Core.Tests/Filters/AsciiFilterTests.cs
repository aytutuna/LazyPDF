using System.Text;
using Xunit;

namespace LazyPDF.Core.Tests;

public class AsciiFilterTests
{
    private static byte[] Ascii(string text) => Encoding.ASCII.GetBytes(text);

    private static byte[] Decode(string filter, byte[] data) => PdfFilters.Decode(data, new PdfName(filter), null);

    [Fact]
    public void HexIgnoresSpaceAndStopsAtTheMarker()
    {
        Assert.Equal(new byte[] { 0x48, 0x65, 0x6C, 0x6C, 0x6F }, Decode("ASCIIHexDecode", Ascii("48 65\n6c6C\t6F>junk")));
    }

    [Fact]
    public void HexOddLastDigitIsPaddedWithZero()
    {
        Assert.Equal(new byte[] { 0xAB, 0xC0 }, Decode("AHx", Ascii("ABC>")));
    }

    [Fact]
    public void HexWithoutMarkerDecodesToTheEnd()
    {
        Assert.Equal(new byte[] { 0x01, 0x02 }, Decode("AHx", Ascii("0102")));
    }

    [Fact]
    public void HexWithAStrayCharacterIsDamaged()
    {
        var e = Assert.Throws<PdfReadException>(() => Decode("AHx", Ascii("12G4>")));
        Assert.Equal(PdfReadProblem.Damaged, e.Problem);
    }

    [Fact]
    public void HexEncoderRoundTrips()
    {
        var data = FilterFixtures.RandomBytes(1000);
        var encoded = PdfFilterEncoders.AsciiHex(data);
        Assert.Equal((byte)'>', encoded[^1]);
        Assert.Equal(data, Decode("AHx", encoded));
    }

    [Fact]
    public void Ascii85KnownAnswer()
    {
        Assert.Equal("Man is distinguished", Encoding.ASCII.GetString(Decode("ASCII85Decode", Ascii("9jqo^BlbD-BleB1DJ+*+F(f,q~>"))));
        Assert.Equal(Ascii("9jqo^BlbD-BleB1DJ+*+F(f,q~>"), PdfFilterEncoders.Ascii85(Ascii("Man is distinguished")));
    }

    [Fact]
    public void Ascii85ZStandsForFourZeroBytes()
    {
        Assert.Equal(new byte[8], Decode("A85", Ascii("zz~>")));
        Assert.Equal(Ascii("z~>"), PdfFilterEncoders.Ascii85(new byte[4]));
    }

    [Fact]
    public void Ascii85AcceptsThePrefixAndWhiteSpace()
    {
        Assert.Equal("Man ", Encoding.ASCII.GetString(Decode("A85", Ascii("<~9jq\n o^~>"))));
    }

    [Fact]
    public void Ascii85WithoutTheEndMarkerDecodesToTheEnd()
    {
        Assert.Equal("Man ", Encoding.ASCII.GetString(Decode("A85", Ascii("9jqo^"))));
    }

    [Fact]
    public void Ascii85OutsideTheAlphabetIsDamaged()
    {
        var e = Assert.Throws<PdfReadException>(() => Decode("A85", Ascii("9jq{o^~>")));
        Assert.Equal(PdfReadProblem.Damaged, e.Problem);
    }

    [Theory]
    [InlineData(0)]
    [InlineData(1)]
    [InlineData(2)]
    [InlineData(3)]
    [InlineData(4)]
    [InlineData(5)]
    [InlineData(1001)]
    public void Ascii85RoundTripsEveryTailLength(int length)
    {
        var data = FilterFixtures.RandomBytes(length, length + 1);
        Assert.Equal(data, Decode("A85", PdfFilterEncoders.Ascii85(data)));
    }

    [Fact]
    public void RunLengthDecodes()
    {
        // Three literal bytes, four copies of 7, end of data, then bytes that must not be read.
        var encoded = new byte[] { 2, 10, 20, 30, 253, 7, 128, 0, 99 };
        Assert.Equal(new byte[] { 10, 20, 30, 7, 7, 7, 7 }, Decode("RunLengthDecode", encoded));
    }

    [Fact]
    public void RunLengthCutShortGivesWhatIsThere()
    {
        Assert.Equal(new byte[] { 1, 2 }, Decode("RL", [4, 1, 2]));
        Assert.Equal(new byte[] { 1 }, Decode("RL", [0, 1, 250]));
    }

    [Fact]
    public void RunLengthEncoderRoundTrips()
    {
        var mixed = new List<byte>();
        mixed.AddRange(FilterFixtures.RandomBytes(300, 2));
        mixed.AddRange(new byte[500]);
        mixed.AddRange(FilterFixtures.RandomBytes(130, 4));
        mixed.AddRange(Enumerable.Repeat((byte)9, 129));
        mixed.Add(5);
        foreach (var data in new[] { mixed.ToArray(), [], [1], [1, 1], [1, 2, 2], new byte[128], new byte[129] })
            Assert.Equal(data, Decode("RunLengthDecode", PdfFilterEncoders.RunLength(data)));
    }

    [Fact]
    public void RunLengthShrinksRuns()
    {
        Assert.True(PdfFilterEncoders.RunLength(new byte[10_000]).Length < 200);
    }

    [Fact]
    public void RunLengthBombStopsAtTheCap()
    {
        var packed = PdfFilterEncoders.RunLength(new byte[1_000_000]);
        var e = Assert.Throws<PdfReadException>(() => PdfFilters.Decode(packed, new PdfName("RL"), null, 10_000));
        Assert.Equal(PdfReadProblem.Unsupported, e.Problem);
    }
}
