using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class RedactPathTests
{
    private static readonly PdfRect Hole = new(200, 200, 300, 300);

    private static (RedactionResult Result, Recorder Paths) Run(string content, PdfRect? mark = null)
    {
        using var document = RedactionKit.Page(content);
        var result = new PdfRedactor(document).Apply([RedactionMark.FromRect(0, mark ?? Hole)]);
        using var output = RedactionKit.Open(result);
        var recorder = ContentTestPdf.Run(output);
        // The last path is the cover over the mark.
        Assert.Equal(mark ?? Hole, recorder.Paths[^1].Path.Bounds);
        recorder.Paths.RemoveAt(recorder.Paths.Count - 1);
        return (result, recorder);
    }

    private static List<List<(double X, double Y)>> Subpaths(PathInfo p)
    {
        var all = new List<List<(double X, double Y)>>();
        foreach (var s in p.Segments)
        {
            if (s.Kind == PathSegmentKind.Move) all.Add([]);
            if (s.Kind != PathSegmentKind.Close) all[^1].Add((s.X1, s.Y1));
        }
        return all;
    }

    private static double Area(PathInfo p) => Subpaths(p).Sum(sub => Geometry.Area(sub));

    private static List<PdfRect> Boxes(Recorder recorder) =>
        [.. recorder.Paths.SelectMany(p => Subpaths(p.Path)).Select(sub => new PdfRect(sub.Min(q => q.X), sub.Min(q => q.Y), sub.Max(q => q.X), sub.Max(q => q.Y)))];

    [Fact]
    public void BackgroundRectangleIsCutIntoTheRectanglesAroundTheMark()
    {
        var (result, recorder) = Run("0.9 g 100 100 400 400 re f");
        var pieces = Boxes(recorder);
        Assert.Equal(4, pieces.Count);
        Assert.Equal(400 * 400 - 100 * 100, recorder.Paths.Sum(p => Area(p.Path)), 1e-6);
        Assert.All(pieces, p => Assert.True(p.Intersect(Hole).IsEmpty));
        Assert.All(recorder.Paths, p => Assert.Equal(0.9, p.State.FillColor.Components[0], 6));
        Assert.Equal(1, result.Report.Paths);
    }

    [Fact]
    public void RectangleCrossingAnEdgeLeavesWhatIsOutside()
    {
        var (_, recorder) = Run("0 0 1 rg 250 100 200 150 re f");
        Assert.Equal(200 * 150 - 50 * 50, recorder.Paths.Sum(p => Area(p.Path)), 1e-6);
        Assert.All(Boxes(recorder), p => Assert.True(p.Intersect(Hole).IsEmpty));
    }

    [Fact]
    public void RectangleInsideTheMarkGoes()
    {
        var (result, recorder) = Run("1 0 0 rg 220 220 20 20 re f 0 0 1 rg 400 400 20 20 re f");
        Assert.Single(recorder.Paths);
        Assert.Equal(400, recorder.Paths[0].Path.Bounds.Left);
        Assert.Equal(1, result.Report.Paths);
    }

    [Fact]
    public void RectangleRotatedOnThePageIsCutInPageSpace()
    {
        // A quarter turn puts the rectangle at x 200..300, y 150..300: the mark takes its upper two thirds.
        var (_, recorder) = Run("q 0 1 -1 0 300 150 cm 0 0 150 100 re f Q");
        Assert.Equal(100 * 50, recorder.Paths.Sum(p => Area(p.Path)), 1e-6);
        Assert.All(Boxes(recorder), p => Assert.True(p.Intersect(Hole).IsEmpty));
    }

    [Fact]
    public void StrokedLineThroughTheMarkIsRemovedAndOthersStay()
    {
        var (result, recorder) = Run("2 w 100 250 m 500 250 l S 100 500 m 500 500 l S 100 150 m 500 150 l S");
        Assert.Equal(2, recorder.Paths.Count);
        Assert.DoesNotContain(recorder.Paths, p => p.Path.Bounds.Bottom == 250);
        Assert.Equal(1, result.Report.Paths);
    }

    [Fact]
    public void ThickLineNearTheMarkIsRemovedBecauseOfItsWidth()
    {
        var (_, thin) = Run("1 w 100 195 m 500 195 l S");
        var (_, thick) = Run("20 w 100 195 m 500 195 l S");
        Assert.Single(thin.Paths);
        Assert.Empty(thick.Paths);
    }

    [Fact]
    public void CurvedAndFilledAndStrokedShapesCrossingAreRemoved()
    {
        var (_, recorder) = Run("250 250 m 250 400 400 400 400 250 c f 100 100 150 150 re B 0 g 400 100 50 50 re f");
        Assert.Single(recorder.Paths);
        Assert.Equal(400, recorder.Paths[0].Path.Bounds.Left);
    }

    [Fact]
    public void ShapeAroundTheMarkWithoutTouchingItStays()
    {
        // A ring: its outline surrounds the mark, its fill (even-odd) does not cover it.
        var (_, recorder) = Run("100 100 m 400 100 l 400 400 l 100 400 l h 150 150 m 350 150 l 350 350 l 150 350 l h f*");
        Assert.Equal("f*", Assert.Single(recorder.Paths).Path.Operator);
    }

    [Fact]
    public void OutlinedGlyphShapeIsRemoved()
    {
        var (_, recorder) = Run("210 210 m 230 210 l 220 240 l h f 10 10 m 30 10 l 20 40 l h f");
        Assert.Single(recorder.Paths);
    }

    [Fact]
    public void ClippingPathIsKeptAndCutsNothing()
    {
        var (_, recorder) = Run("q 150 150 200 200 re W n 0 g 10 10 20 20 re f Q");
        Assert.Equal(2, recorder.Paths.Count);
        Assert.Equal(150, recorder.Paths[1].State.Clip.Left);
    }

    [Fact]
    public void ShadingUnderTheMarkLeavesAHole()
    {
        using var document = RedactionKit.Page("/Sh1 sh", "/Shading <</Sh1 << /ShadingType 2 /ColorSpace /DeviceGray /Coords [0 0 600 0] /Function << /FunctionType 2 /Domain [0 1] /C0 [0] /C1 [1] /N 1 >> >> >>");
        var result = new PdfRedactor(document).Apply([RedactionMark.FromRect(0, Hole)]);
        using var output = RedactionKit.Open(result);
        string content = RedactionKit.Latin(output);
        Assert.Contains("W*", content);
        Assert.Contains("Sh1 sh", content);
    }

    [Fact]
    public void TilingPatternPaintedUnderTheMarkIsRemovedFromThatUse()
    {
        using var document = RedactionKit.Page("/Pattern cs /P1 scn 150 150 200 200 re f /Pattern cs /P1 scn 400 400 50 50 re f",
            "/Pattern <</P1 6 0 R>>", pdf => pdf.Stream(6, "/Type /Pattern /PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 10 10] /XStep 10 /YStep 10 /Resources <<>>", "0 0 5 5 re f"));
        var result = new PdfRedactor(document).Apply([RedactionMark.FromRect(0, Hole)]);
        using var output = RedactionKit.Open(result);
        var paths = ContentTestPdf.Run(output).Paths;
        Assert.Equal(2, paths.Count(p => p.Path.Bounds.Left >= 400 || p.Path.Bounds.Width <= 10));
        Assert.DoesNotContain(paths, p => p.Path.Bounds.Left == 150);
        Assert.Equal(1, result.Report.Paths);
    }
}
