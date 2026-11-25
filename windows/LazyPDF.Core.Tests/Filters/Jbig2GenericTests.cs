using Xunit;

namespace LazyPDF.Core.Tests;

public class Jbig2GenericTests
{
    internal static byte[] Decode(byte[] stream, PdfObject? parameters = null) =>
        PdfFilters.Decode(stream, new PdfName("JBIG2Decode"), parameters);

    public static IEnumerable<object[]> Cases()
    {
        foreach (int template in new[] { 0, 1, 2, 3 })
        {
            foreach (bool prediction in new[] { false, true })
            {
                yield return [template, prediction, 61, 40];
                yield return [template, prediction, 3, 9];
                yield return [template, prediction, 1, 5];
                yield return [template, prediction, 150, 20];
            }
        }
    }

    [Theory]
    [MemberData(nameof(Cases))]
    public void RoundTripsWithTheNominalAdaptivePixels(int template, bool prediction, int width, int height)
    {
        var bm = prediction ? Bm.Repeating(width, height, 7) : Bm.Text(width, height, template + 1);
        Assert.Equal(bm.Packed(), Decode(Jbig2Segments.Generic(bm, template, prediction)));
    }

    [Theory]
    [InlineData(0, false)]
    [InlineData(0, true)]
    [InlineData(1, false)]
    [InlineData(2, true)]
    [InlineData(3, false)]
    public void RoundTripsWithMovedAdaptivePixels(int template, bool prediction)
    {
        int[] at = template == 0 ? [-5, -2, 4, -1, 6, -3, -7, -1] : [-6, -3];
        var bm = Bm.Text(90, 33, 11 + template);
        Assert.Equal(bm.Packed(), Decode(Jbig2Segments.Generic(bm, template, prediction, at)));
    }

    [Fact]
    public void AdaptivePixelOnTheCurrentRowAndFarAway()
    {
        var bm = Bm.Text(70, 40, 3);
        Assert.Equal(bm.Packed(), Decode(Jbig2Segments.Generic(bm, 0, false, [-20, 0, 5, -9, -100, -2, 100, -1])));
    }

    [Fact]
    public void EmptyAndFilledPages()
    {
        var blank = new Bm(33, 10);
        Assert.Equal(blank.Packed(), Decode(Jbig2Segments.Generic(blank, 0, false)));
        var black = new Bm(33, 10);
        Array.Fill(black.Px, (byte)1);
        Assert.Equal(black.Packed(), Decode(Jbig2Segments.Generic(black, 2, true)));
    }

    [Fact]
    public void RegionsAreComposedOntoThePageWithTheirOperators()
    {
        var back = Bm.Text(40, 20, 5);
        var front = Bm.Text(16, 8, 6);
        var e = new ArithEncoder();
        Jbig2Encode.Generic(e, back, 0, false);
        byte[] backCoded = e.Finish();
        e = new ArithEncoder();
        Jbig2Encode.Generic(e, front, 0, false);
        byte[] frontCoded = e.Finish();
        foreach (var (op, combine) in new (int, Func<int, int, int>)[] { (0, (d, s) => d | s), (1, (d, s) => d & s), (2, (d, s) => d ^ s), (3, (d, s) => 1 ^ d ^ s), (4, (d, s) => s) })
        {
            var stream = Jbig2Segments.Cat(
                Jbig2Segments.Segment(0, 48, Jbig2Segments.PageInfo(40, 20)),
                Jbig2Segments.Segment(1, 38, Jbig2Segments.GenericData(back, backCoded, 0, false, false, null)),
                Jbig2Segments.Segment(2, 38, Jbig2Segments.GenericData(front, frontCoded, 0, false, false, null, 9, 4, op)));
            var expected = new Bm(40, 20);
            Array.Copy(back.Px, expected.Px, back.Px.Length);
            for (int y = 0; y < 8; y++)
            {
                for (int x = 0; x < 16; x++) expected[9 + x, 4 + y] = combine(expected[9 + x, 4 + y], front[x, y]);
            }
            Assert.Equal(expected.Packed(), Decode(stream));
        }
    }

    [Fact]
    public void PageDefaultPixelFillsTheBackground()
    {
        var bm = Bm.Text(20, 10, 2);
        var e = new ArithEncoder();
        Jbig2Encode.Generic(e, bm, 0, false);
        var stream = Jbig2Segments.Cat(
            Jbig2Segments.Segment(0, 48, Jbig2Segments.PageInfo(24, 12, 4)),
            Jbig2Segments.Segment(1, 38, Jbig2Segments.GenericData(bm, e.Finish(), 0, false, false, null, 2, 1, 2)));
        var expected = new Bm(24, 12);
        Array.Fill(expected.Px, (byte)1);
        for (int y = 0; y < 10; y++)
        {
            for (int x = 0; x < 20; x++) expected[2 + x, 1 + y] ^= (byte)bm[x, y];
        }
        Assert.Equal(expected.Packed(), Decode(stream));
    }

    [Fact]
    public void StripedPageWithAnUnknownHeightGrowsWithItsStripes()
    {
        var bm = Bm.Text(50, 30, 9);
        var top = bm.Sub(0, 0, 50, 12);
        var bottom = bm.Sub(0, 12, 50, 18);
        var e = new ArithEncoder();
        Jbig2Encode.Generic(e, top, 1, false);
        var f = new ArithEncoder();
        Jbig2Encode.Generic(f, bottom, 1, false);
        var stream = Jbig2Segments.Cat(
            Jbig2Segments.Segment(0, 48, Jbig2Segments.PageInfo(50, -1, 0)),
            Jbig2Segments.Segment(1, 38, Jbig2Segments.GenericData(top, e.Finish(), 1, false, false, null, 0, 0)),
            Jbig2Segments.Segment(2, 50, Jbig2Segments.U32(11)),
            Jbig2Segments.Segment(3, 38, Jbig2Segments.GenericData(bottom, f.Finish(), 1, false, false, null, 0, 12)),
            Jbig2Segments.Segment(4, 50, Jbig2Segments.U32(29)));
        Assert.Equal(bm.Packed(), Decode(stream));
    }

    [Fact]
    public void GenericRegionOfUnknownLengthEndsAtItsMarker()
    {
        var bm = Bm.Text(40, 25, 4);
        var e = new ArithEncoder();
        Jbig2Encode.Generic(e, bm, 0, false);
        byte[] data = Jbig2Segments.Cat(Jbig2Segments.GenericData(bm, e.Finish(), 0, false, false, null), Jbig2Segments.U32(25));
        var region = Jbig2Segments.Segment(1, 38, data);
        // The length field is the last four bytes of the header: 0xFFFFFFFF.
        int lengthAt = region.Length - data.Length - 4;
        region[lengthAt] = region[lengthAt + 1] = region[lengthAt + 2] = region[lengthAt + 3] = 0xff;
        var stream = Jbig2Segments.Cat(Jbig2Segments.Segment(0, 48, Jbig2Segments.PageInfo(40, 25)), region, Jbig2Segments.Segment(2, 49, []));
        Assert.Equal(bm.Packed(), Decode(stream));
    }
}
