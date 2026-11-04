using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class RedactGeometryTests
{
    private static MarkArea Area(double x1, double y1, double x2, double y2) => MarkArea.Of(RedactionMark.FromRect(0, new PdfRect(x1, y1, x2, y2)).Quads[0]);

    [Fact]
    public void QuadsInAnyCornerOrderMakeTheSameArea()
    {
        var a = new MarkArea([(0, 0), (10, 0), (10, 5), (0, 5)]);
        var b = new MarkArea([(10, 5), (0, 0), (0, 5), (10, 0)]);
        Assert.Equal(50, a.Area, 6);
        Assert.Equal(a.Points, b.Points);
    }

    [Fact]
    public void GlyphMeetsOnlyWhenTheMarkReachesItsMiddle()
    {
        var glyph = Geometry.Corners(PdfMatrix.Identity, 0, 0, 10, 10);
        Assert.True(Geometry.GlyphMeets(glyph, Area(4, 4, 6, 6)));
        Assert.True(Geometry.GlyphMeets(glyph, Area(-5, -5, 3, 3)));
        Assert.False(Geometry.GlyphMeets(glyph, Area(9, -5, 20, 20)));
        Assert.False(Geometry.GlyphMeets(glyph, Area(10, 0, 20, 10)));
        Assert.False(Geometry.GlyphMeets(glyph, Area(-20, 0, 0, 10)));
    }

    [Fact]
    public void ZeroWidthGlyphIsTestedAtItsPoint()
    {
        var mark = Area(0, 0, 10, 10);
        Assert.True(Geometry.GlyphMeets(Geometry.Corners(PdfMatrix.Identity, 5, 0, 5, 10), mark));
        Assert.False(Geometry.GlyphMeets(Geometry.Corners(PdfMatrix.Identity, 15, 0, 15, 10), mark));
    }

    [Fact]
    public void RotatedGlyphIsTestedInItsOwnFrame()
    {
        var turned = new PdfMatrix(0, 1, -1, 0, 0, 0);
        var glyph = Geometry.Corners(turned, 0, 0, 10, 2);
        Assert.True(Geometry.GlyphMeets(glyph, Area(-3, 2, 0, 6)));
        Assert.False(Geometry.GlyphMeets(glyph, Area(5, 2, 8, 6)));
    }

    [Fact]
    public void SegmentDistance()
    {
        var mark = Area(0, 0, 10, 10);
        Assert.Equal(0, Geometry.Distance((-5, 5), (15, 5), mark));
        Assert.Equal(0, Geometry.Distance((5, 5), (6, 6), mark));
        Assert.Equal(3, Geometry.Distance((-3, 20), (-3, -20), mark), 6);
        Assert.Equal(5, Geometry.Distance((15, 0), (15, 10), mark), 6);
        Assert.Equal(Math.Sqrt(50), Geometry.Distance((-5, 15), (-5, 20), mark), 6);
    }

    [Fact]
    public void FillRuleInsideTest()
    {
        var ring = new List<List<(double X, double Y)>> { new() { (0, 0), (10, 0), (10, 10), (0, 10) }, new() { (3, 3), (7, 3), (7, 7), (3, 7) } };
        Assert.True(Geometry.Inside(ring, false, 5, 5));
        Assert.False(Geometry.Inside(ring, true, 5, 5));
        Assert.True(Geometry.Inside(ring, true, 1, 1));
        Assert.False(Geometry.Inside(ring, true, 20, 5));
    }
}
