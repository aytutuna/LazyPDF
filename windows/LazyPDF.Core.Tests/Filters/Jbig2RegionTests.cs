using Xunit;

namespace LazyPDF.Core.Tests;

public class Jbig2RegionTests
{
    private static byte[] Decode(byte[] stream) => Jbig2GenericTests.Decode(stream);

    [Theory]
    [InlineData(1, 7)]
    [InlineData(8, 8)]
    [InlineData(61, 40)]
    [InlineData(200, 17)]
    public void MmrGenericRegionRoundTrips(int width, int height)
    {
        var bm = Bm.Text(width, height, width);
        byte[] coded = CcittEncoder.Encode(bm.Packed(), width, height);
        var stream = Jbig2Segments.Cat(
            Jbig2Segments.Segment(0, 48, Jbig2Segments.PageInfo(width, height)),
            Jbig2Segments.Segment(1, 38, Jbig2Segments.GenericData(bm, coded, 0, true, false, null)));
        Assert.Equal(bm.Packed(), Decode(stream));
    }

    [Fact]
    public void MmrRegionOfUnknownLengthEndsAtItsMarker()
    {
        var bm = Bm.Text(40, 25, 4);
        byte[] coded = CcittEncoder.Encode(bm.Packed(), 40, 25);
        byte[] data = Jbig2Segments.Cat(Jbig2Segments.GenericData(bm, coded, 0, true, false, null), [0, 0], Jbig2Segments.U32(25));
        var region = Jbig2Segments.Segment(1, 38, data);
        int lengthAt = region.Length - data.Length - 4;
        for (int i = 0; i < 4; i++) region[lengthAt + i] = 0xff;
        var stream = Jbig2Segments.Cat(Jbig2Segments.Segment(0, 48, Jbig2Segments.PageInfo(40, 25)), region);
        Assert.Equal(bm.Packed(), Decode(stream));
    }

    private static byte[] RefinementData(Bm target, Bm reference, int template, bool prediction, int[]? at, int op = 0)
    {
        var e = new ArithEncoder();
        Jbig2Encode.Refinement(e, target, template, reference, 0, 0, prediction, at);
        return Jbig2Segments.Cat(Jbig2Segments.RegionInfo(target.Width, target.Height, 0, 0, op), [(byte)(template | (prediction ? 2 : 0))],
            template == 0 ? Jbig2Segments.At(at ?? [-1, -1, -1, -1]) : [], e.Finish());
    }

    /// <summary>The reference with a few pixels changed, so that most of a refinement is predicted.</summary>
    private static Bm Disturb(Bm bm, int seed)
    {
        var copy = new Bm(bm.Width, bm.Height);
        bm.Px.CopyTo(copy.Px, 0);
        var random = new Random(seed);
        for (int i = 0; i < bm.Width * bm.Height / 25 + 1; i++) copy[random.Next(bm.Width), random.Next(bm.Height)] ^= 1;
        return copy;
    }

    [Theory]
    [InlineData(0, false, false)]
    [InlineData(0, true, false)]
    [InlineData(1, false, false)]
    [InlineData(1, true, false)]
    [InlineData(0, false, true)]
    [InlineData(0, true, true)]
    public void RefinementRegionRefinesAnIntermediateRegion(int template, bool prediction, bool movedPixels)
    {
        var target = Bm.Text(55, 33, 21);
        var reference = Disturb(target, 5);
        var e = new ArithEncoder();
        Jbig2Encode.Generic(e, reference, 0, false);
        int[]? at = movedPixels ? [-2, -1, 1, -2] : null;
        var stream = Jbig2Segments.Cat(
            Jbig2Segments.Segment(0, 48, Jbig2Segments.PageInfo(55, 33)),
            Jbig2Segments.Segment(1, 36, Jbig2Segments.GenericData(reference, e.Finish(), 0, false, false, null)),
            Jbig2Segments.Segment(2, 42, RefinementData(target, reference, template, prediction, at), [1]));
        Assert.Equal(target.Packed(), Decode(stream));
    }

    [Fact]
    public void IntermediateRegionAloneDrawsNothing()
    {
        var bm = Bm.Text(20, 10, 2);
        var e = new ArithEncoder();
        Jbig2Encode.Generic(e, bm, 0, false);
        var stream = Jbig2Segments.Cat(
            Jbig2Segments.Segment(0, 48, Jbig2Segments.PageInfo(20, 10)),
            Jbig2Segments.Segment(1, 36, Jbig2Segments.GenericData(bm, e.Finish(), 0, false, false, null)));
        Assert.Equal(new Bm(20, 10).Packed(), Decode(stream));
    }

    [Theory]
    [InlineData(0)]
    [InlineData(1)]
    public void RefinementRegionWithoutAReferenceRefinesThePage(int template)
    {
        var target = Bm.Text(48, 30, 8);
        var coarse = Disturb(target, 3);
        var e = new ArithEncoder();
        Jbig2Encode.Generic(e, coarse, 2, false);
        // The region of the refinement is the whole page and replaces what is there.
        var stream = Jbig2Segments.Cat(
            Jbig2Segments.Segment(0, 48, Jbig2Segments.PageInfo(48, 30)),
            Jbig2Segments.Segment(1, 38, Jbig2Segments.GenericData(coarse, e.Finish(), 2, false, false, null)),
            Jbig2Segments.Segment(2, 42, RefinementData(target, coarse, template, true, null, 4)));
        Assert.Equal(target.Packed(), Decode(stream));
    }

    [Fact]
    public void RefinementOfARegionOfAnotherSizeIsLeftOut()
    {
        var target = Bm.Text(48, 30, 8);
        var other = Bm.Text(40, 30, 9);
        var e = new ArithEncoder();
        Jbig2Encode.Generic(e, other, 0, false);
        var stream = Jbig2Segments.Cat(
            Jbig2Segments.Segment(0, 48, Jbig2Segments.PageInfo(48, 30)),
            Jbig2Segments.Segment(1, 36, Jbig2Segments.GenericData(other, e.Finish(), 0, false, false, null)),
            Jbig2Segments.Segment(2, 42, RefinementData(target, target, 0, false, null), [1]));
        Assert.Equal(PdfReadProblem.Damaged, Assert.Throws<PdfReadException>(() => Decode(stream)).Problem);
    }
}
