using Xunit;

namespace LazyPDF.Core.Tests;

public class CcittTests
{
    private const string Eol = "000000000001";

    private static byte[] Bits(params string[] parts)
    {
        string all = string.Concat(parts);
        var bytes = new byte[(all.Length + 7) / 8];
        for (int i = 0; i < all.Length; i++)
        {
            if (all[i] == '1') bytes[i / 8] |= (byte)(0x80 >> (i % 8));
        }
        return bytes;
    }

    /// <summary>Rows of packed pixels with white as 1 and black as 0, padding bits white; or the other way round.</summary>
    private static byte[] Pack(int width, int height, Func<int, int, bool> black, bool blackIs1 = false)
    {
        int stride = (width + 7) / 8;
        var packed = new byte[stride * height];
        if (!blackIs1) Array.Fill(packed, (byte)0xFF);
        for (int y = 0; y < height; y++)
        {
            for (int x = 0; x < width; x++)
            {
                if (!black(x, y)) continue;
                if (blackIs1) packed[y * stride + (x >> 3)] |= (byte)(0x80 >> (x & 7));
                else packed[y * stride + (x >> 3)] &= (byte)~(0x80 >> (x & 7));
            }
        }
        return packed;
    }

    private static byte[] Decode(byte[] data, string parms) =>
        PdfFilters.Decode(data, new PdfName("CCITTFaxDecode"), FilterFixtures.Dict(parms));

    private static string Parms(int k, int width, int? rows = null, bool align = false, bool blackIs1 = false, bool eol = false) =>
        $"<< /K {k} /Columns {width} {(rows is { } r ? $"/Rows {r}" : "")} /EncodedByteAlign {align.ToString().ToLowerInvariant()} " +
        $"/BlackIs1 {blackIs1.ToString().ToLowerInvariant()} /EndOfLine {eol.ToString().ToLowerInvariant()} >>";

    public static IEnumerable<object[]> Images()
    {
        yield return [61, 40, (Func<int, int, bool>)((x, y) => (x / 7 + y / 3) % 2 == 0)];
        yield return [100, 20, (Func<int, int, bool>)((x, y) => false)];
        yield return [33, 9, (Func<int, int, bool>)((x, y) => true)];
        yield return [17, 6, (Func<int, int, bool>)((x, y) => x == 16 && y == 5 || x == 0 && y == 0)];
        yield return [80, 80, (Func<int, int, bool>)((x, y) => Math.Abs(x - y) < 3)];
        yield return [90, 50, (Func<int, int, bool>)((x, y) => ((x * 31 + y * 17) * 2654435761L >> 20 & 7) == 0)];
        yield return [6100, 7, (Func<int, int, bool>)((x, y) => x % 5000 < 3000 + y * 100 && x > 40)];
        yield return [1, 12, (Func<int, int, bool>)((x, y) => y % 3 == 0)];
        yield return [8, 16, (Func<int, int, bool>)((x, y) => (x + y) % 5 < 2)];
    }

    [Theory]
    [MemberData(nameof(Images))]
    public void GroupFourRoundTrips(int width, int height, Func<int, int, bool> black)
    {
        var packed = Pack(width, height, black);
        var encoded = CcittEncoder.Encode(packed, width, height);
        Assert.Equal(packed, Decode(encoded, Parms(-1, width, height)));
        Assert.Equal(packed, Decode(encoded, Parms(-1, width)));
    }

    [Theory]
    [MemberData(nameof(Images))]
    public void BlackIs1FlipsTheColours(int width, int height, Func<int, int, bool> black)
    {
        var encoded = CcittEncoder.Encode(Pack(width, height, black), width, height);
        Assert.Equal(Pack(width, height, black, blackIs1: true), Decode(encoded, Parms(-1, width, height, blackIs1: true)));
    }

    [Theory]
    [MemberData(nameof(Images))]
    public void GroupThreeOneDimensionalRoundTrips(int width, int height, Func<int, int, bool> black)
    {
        var packed = Pack(width, height, black);
        foreach (var (eol, align) in new[] { (false, false), (true, false), (false, true), (true, true) })
        {
            var encoded = CcittEncoder.EncodeG3(packed, width, height, 0, eol, align);
            Assert.True(packed.AsSpan().SequenceEqual(Decode(encoded, Parms(0, width, height, align, eol: eol))), $"rows eol={eol} align={align}");
            Assert.True(packed.AsSpan().SequenceEqual(Decode(encoded, Parms(0, width, align: align, eol: eol))), $"norows eol={eol} align={align}");
        }
    }

    [Theory]
    [MemberData(nameof(Images))]
    public void GroupThreeMixedRoundTrips(int width, int height, Func<int, int, bool> black)
    {
        var packed = Pack(width, height, black);
        foreach (int k in new[] { 2, 4 })
        {
            foreach (bool align in new[] { false, true })
            {
                var encoded = CcittEncoder.EncodeG3(packed, width, height, k, eol: true, align);
                Assert.Equal(packed, Decode(encoded, Parms(k, width, height, align, eol: true)));
                Assert.Equal(packed, Decode(encoded, Parms(k, width, align: align, eol: true)));
            }
        }
    }

    [Fact]
    public void GroupFourKnownAnswer()
    {
        // Row 1 all white: V0. Row 2 black from 2 to 4: horizontal (white 2, black 3), then V0 for the end.
        var data = Bits("1", "001", "0111", "10", "1", Eol, Eol);
        Assert.Equal(new byte[] { 0xFF, 0xC7 }, Decode(data, Parms(-1, 8)));
    }

    [Fact]
    public void GroupThreeKnownAnswer()
    {
        // One row, width 16: white 3 (1000), black 2 (11), white 11 (10101).
        Assert.Equal(new byte[] { 0b11100111, 0xFF }, Decode(Bits("1000", "11", "01000"), Parms(0, 16)));
    }

    [Fact]
    public void EndOfLineFlagIsNotNeededToAcceptEols()
    {
        var packed = Pack(40, 10, (x, y) => (x + y) % 6 < 2);
        var encoded = CcittEncoder.EncodeG3(packed, 40, 10, 0, eol: true, align: false);
        Assert.Equal(packed, Decode(encoded, Parms(0, 40, eol: false)));
    }

    [Fact]
    public void MissingRowsAreWhite()
    {
        var packed = Pack(20, 5, (x, y) => true);
        var encoded = CcittEncoder.Encode(packed, 20, 5);
        var decoded = Decode(encoded, Parms(-1, 20, 9));
        Assert.Equal(9 * 3, decoded.Length);
        Assert.Equal(packed, decoded[..(5 * 3)]);
        Assert.All(decoded[(5 * 3)..], b => Assert.Equal(0xFF, b));
    }

    [Fact]
    public void FewerRowsThanTheDataHoldStopsEarly()
    {
        var packed = Pack(20, 8, (x, y) => (x + y) % 3 == 0);
        var encoded = CcittEncoder.Encode(packed, 20, 8);
        Assert.Equal(packed[..(3 * 3)], Decode(encoded, Parms(-1, 20, 3)));
    }

    [Fact]
    public void TruncatedGroupFourKeepsTheRowsBeforeTheBreak()
    {
        var packed = Pack(64, 40, (x, y) => (x / 5 + y / 2) % 2 == 0);
        var encoded = CcittEncoder.Encode(packed, 64, 40);
        var decoded = Decode(encoded[..(encoded.Length / 2)], Parms(-1, 64, 40));
        Assert.Equal(packed.Length, decoded.Length);
        Assert.Equal(packed[..(8 * 10)], decoded[..(8 * 10)]);
    }

    [Fact]
    public void GroupThreeResynchronisesAtTheNextEol()
    {
        // Rows: white; a bad code with a few stray bits; black.
        var data = Bits(Eol, "10011", Eol, "000000001", "101", Eol, "00110101", "000101", Eol, Eol, Eol);
        var decoded = Decode(data, Parms(0, 8, 3));
        Assert.Equal(new byte[] { 0xFF, 0xFF, 0x00 }, decoded);
    }

    [Fact]
    public void ReturnToControlEndsTheData()
    {
        var data = Bits(Eol, "10011", Eol, "00110101", "000101", Eol, Eol, Eol, Eol, Eol, Eol, "1010101");
        Assert.Equal(new byte[] { 0xFF, 0x00 }, Decode(data, Parms(0, 8)));
    }

    [Fact]
    public void GarbageDoesNotThrowAndStaysBounded()
    {
        var garbage = FilterFixtures.RandomBytes(20_000, 11);
        foreach (int k in new[] { -1, 0, 3 })
        {
            var decoded = Decode(garbage, Parms(k, 200));
            Assert.True(decoded.Length % 25 == 0);
            var withRows = Decode(garbage, Parms(k, 200, 100));
            Assert.Equal(2500, withRows.Length);
        }
    }

    [Fact]
    public void ZeroBytesDecodeToNothing()
    {
        Assert.Empty(Decode(new byte[100], Parms(-1, 64)));
        Assert.Empty(Decode([], Parms(0, 64)));
        Assert.Equal(8 * 3, Decode([], Parms(0, 24, 8)).Length);
    }

    [Fact]
    public void ColumnsOutOfRangeAreDamaged()
    {
        var e = Assert.Throws<PdfReadException>(() => Decode([1, 2, 3], Parms(-1, 0)));
        Assert.Equal(PdfReadProblem.Damaged, e.Problem);
        e = Assert.Throws<PdfReadException>(() => Decode([1, 2, 3], Parms(-1, 1 << 24)));
        Assert.Equal(PdfReadProblem.Damaged, e.Problem);
    }

    [Fact]
    public void RowsTimesWidthPastTheCapIsUnsupportedBeforeAllocating()
    {
        var e = Assert.Throws<PdfReadException>(() =>
            PdfFilters.Decode([0xFF], new PdfName("CCF"), FilterFixtures.Dict("<< /K -1 /Columns 100000 /Rows 2000000000 >>")));
        Assert.Equal(PdfReadProblem.Unsupported, e.Problem);
    }

    [Fact]
    public void ManyOneBitRowsStopAtTheCap()
    {
        // Each V0 bit is a whole row of 128 KB: the cap, not the data size, bounds the output.
        var data = new byte[200_000];
        Array.Fill(data, (byte)0xFF);
        var e = Assert.Throws<PdfReadException>(() =>
            PdfFilters.Decode(data, new PdfName("CCITTFaxDecode"), FilterFixtures.Dict("<< /K -1 /Columns 1000000 >>"), 50_000_000));
        Assert.Equal(PdfReadProblem.Unsupported, e.Problem);
    }

    [Fact]
    public void DefaultColumnsAre1728()
    {
        var packed = Pack(1728, 3, (x, y) => x > 100 && x < 900);
        var encoded = CcittEncoder.Encode(packed, 1728, 3);
        Assert.Equal(packed, PdfFilters.Decode(encoded, new PdfName("CCF"), FilterFixtures.Dict("<< /K -1 >>")));
    }

    [Fact]
    public void ChainsWithAsciiAndFlate()
    {
        var packed = Pack(70, 30, (x, y) => (x * y) % 11 < 4);
        var encoded = CcittEncoder.Encode(packed, 70, 30);
        var stored = PdfFilterEncoders.Ascii85(PdfFilterEncoders.Flate(encoded));
        var parms = FilterFixtures.Parse("[null null << /K -1 /Columns 70 /Rows 30 >>]");
        Assert.Equal(packed, PdfFilters.Decode(stored, FilterFixtures.Parse("[/A85 /Fl /CCF]"), parms));
    }

    [Fact]
    public void EmptyHorizontalRunsCannotPushVerticalCodesPastTheRow()
    {
        string empty = "001" + "0000110111" + "00110101";
        var data = Bits("0000010", empty, empty, empty, empty, "000010", "010");
        var thrown = Record.Exception(() => Decode(data, Parms(-1, 8, 1)));
        Assert.True(thrown is null or PdfReadException, thrown?.ToString());
    }
}
