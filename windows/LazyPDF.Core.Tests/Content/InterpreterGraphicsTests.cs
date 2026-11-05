using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class InterpreterGraphicsTests
{
    private static Recorder Run(string content, string resources = "", params string[] objects) =>
        ContentTestPdf.Run(ContentTestPdf.Page(content, resources, objects));

    [Fact]
    public void RectangleFillReportsBoundsAndColour()
    {
        var r = Run("1 0 0 rg 10 20 100 50 re f");
        var (path, state) = Assert.Single(r.Paths);
        Assert.Equal("f", path.Operator);
        Assert.True(path.Fill);
        Assert.False(path.Stroke);
        Assert.Equal(new PdfRect(10, 20, 110, 70), path.Bounds);
        Assert.Equal(new RgbColor(255, 0, 0), state.FillColor.Rgb);
        Assert.Equal("DeviceRGB", state.FillColor.Space.Family);
        Assert.Equal(5, path.Segments.Count);
    }

    [Fact]
    public void StrokeBoundsGrowByHalfTheLineWidth()
    {
        var path = Run("10 w 0 0 100 100 re S").Paths[0].Path;
        Assert.True(path.Stroke);
        Assert.Equal(new PdfRect(-5, -5, 105, 105), path.InkBounds);
        Assert.Equal(new PdfRect(0, 0, 100, 100), path.Bounds);
    }

    [Fact]
    public void PathsAreInTheStartingSpace()
    {
        var path = Run("q 2 0 0 2 100 100 cm 0 0 10 10 re f Q").Paths[0].Path;
        Assert.Equal(new PdfRect(100, 100, 120, 120), path.Bounds);
    }

    [Fact]
    public void CurvesCountTheirControlPoints()
    {
        var path = Run("0 0 m 50 100 100 100 150 0 c f").Paths[0].Path;
        Assert.Equal(100, path.Bounds.Top);
        Assert.Equal(PathSegmentKind.Curve, path.Segments[1].Kind);
        var v = Run("10 10 m 50 60 90 10 v f").Paths[0].Path.Segments[1];
        Assert.Equal((10, 10), (v.X1, v.Y1));
        var y = Run("10 10 m 50 60 90 10 y f").Paths[0].Path.Segments[1];
        Assert.Equal((90, 10), (y.X2, y.Y2));
    }

    [Fact]
    public void ClipShrinksTheBoundingBox()
    {
        var r = Run("0 0 100 100 re W n 50 50 200 200 re f 20 20 10 10 re W n 0 0 5 5 re f");
        Assert.Equal(4, r.Paths.Count);
        Assert.True(r.Paths[0].Path.Clips);
        Assert.Equal("n", r.Paths[0].Path.Operator);
        Assert.Equal(new PdfRect(0, 0, 100, 100), r.Paths[1].State.Clip);
        Assert.Equal(new PdfRect(20, 20, 30, 30), r.Paths[3].State.Clip);
    }

    [Fact]
    public void ThePageCropBoxIsTheFirstClip()
    {
        Assert.Equal(new PdfRect(0, 0, 600, 800), Run("0 0 1 1 re f").Paths[0].State.Clip);
    }

    [Fact]
    public void QAndQRestoreTheState()
    {
        var r = Run("q 5 w 1 0 0 rg 2 0 0 2 0 0 cm Q 0 0 1 1 re S");
        var state = r.Paths[0].State;
        Assert.Equal(1, state.LineWidth);
        Assert.Equal(PdfMatrix.Identity, state.Ctm);
        Assert.Equal(new RgbColor(0, 0, 0), state.FillColor.Rgb);
    }

    [Fact]
    public void AnUnmatchedQIsIgnoredAndTheStackIsCapped()
    {
        var content = "Q Q " + string.Concat(Enumerable.Repeat("q 2 w ", 1000)) + string.Concat(Enumerable.Repeat("Q ", 1000)) + "0 0 1 1 re S";
        var state = Run(content).Paths[0].State;
        Assert.Equal(1, state.LineWidth);
    }

    [Fact]
    public void LineStateAndDash()
    {
        var s = Run("3 w 1 J 2 j 4 M [3 2] 1 d 0 0 1 1 re S").Paths[0].State;
        Assert.Equal((3, 1, 2, 4), (s.LineWidth, s.LineCap, s.LineJoin, s.MiterLimit));
        Assert.Equal([3.0, 2.0], s.Dash);
        Assert.Equal(1, s.DashPhase);
    }

    [Fact]
    public void ExtGStateSetsAlphaBlendAndLines()
    {
        var s = Run("/G gs 0 0 1 1 re f", "/ExtGState <</G <</CA 0.5 /ca 0.25 /BM /Multiply /LW 7 /SMask /None>>>>").Paths[0].State;
        Assert.Equal(0.5, s.StrokeAlpha);
        Assert.Equal(0.25, s.FillAlpha);
        Assert.Equal("Multiply", s.BlendMode);
        Assert.Equal(7, s.LineWidth);
        Assert.Null(s.SoftMask);
    }

    [Fact]
    public void ColourSpacesAndValues()
    {
        string resources = "/ColorSpace <</Cs1 [/Separation /Spot /DeviceCMYK <</FunctionType 2 /Domain [0 1] /C0 [0 0 0 0] /C1 [0 1 1 0] /N 1>>] /Cs2 [/Indexed /DeviceRGB 1 <FF0000 00FF00>]>>";
        var r = Run("/Cs1 cs 1 sc 0 0 1 1 re f /Cs2 cs 1 sc 0 0 1 1 re f 0 0 0 1 k 0 0 1 1 re f 0.5 g 0 0 1 1 re f 0 1 0 0 K 0 0 1 1 re S", resources);
        Assert.Equal("Separation", r.Paths[0].State.FillColor.Space.Family);
        Assert.Equal(new RgbColor(255, 0, 0), r.Paths[0].State.FillColor.Rgb);
        Assert.Equal("Indexed", r.Paths[1].State.FillColor.Space.Family);
        Assert.Equal(new RgbColor(0, 255, 0), r.Paths[1].State.FillColor.Rgb);
        Assert.Equal(new RgbColor(0, 0, 0), r.Paths[2].State.FillColor.Rgb);
        Assert.Equal(new RgbColor(128, 128, 128), r.Paths[3].State.FillColor.Rgb);
        Assert.Equal("DeviceCMYK", r.Paths[4].State.StrokeColor.Space.Family);
    }

    [Fact]
    public void InitialColourOfASpaceIsBlackOrFull()
    {
        var r = Run("/DeviceCMYK cs 0 0 1 1 re f");
        Assert.Equal([0.0, 0, 0, 1], r.Paths[0].State.FillColor.Components);
    }

    [Fact]
    public void ImageXObjectsReportPlacementAndSize()
    {
        var document = ContentTestPdf.Page("q 100 0 0 50 10 20 cm /Im Do Q", "/XObject <</Im 5 0 R>>", pdf => pdf.Stream(5, "/Type /XObject /Subtype /Image /Width 8 /Height 4 /ColorSpace /DeviceGray /BitsPerComponent 8", new byte[32]));
        var i = Assert.Single(ContentTestPdf.Run(document).Images);
        Assert.Equal(("Im", 8, 4, false), (i.Name, i.Width, i.Height, i.IsMask));
        Assert.Equal(new PdfRect(10, 20, 110, 70), i.Bounds);
        Assert.NotNull(i.Stream);
    }

    [Fact]
    public void InlineImagesAreExpandedAndPlaced()
    {
        var r = Run("q 40 0 0 40 5 5 cm BI /W 2 /H 2 /BPC 8 /CS /G ID abcd\nEI Q");
        var i = Assert.Single(r.Images);
        Assert.Null(i.Name);
        Assert.NotNull(i.Inline);
        Assert.Equal((2, 2), (i.Width, i.Height));
        Assert.Equal(new PdfRect(5, 5, 45, 45), i.Bounds);
        Assert.NotNull(i.Dictionary["BitsPerComponent"]);
    }

    [Fact]
    public void ShadingsAreReported()
    {
        var r = Run("0 0 50 50 re W n /Sh sh", "/Shading <</Sh <</ShadingType 2 /ColorSpace /DeviceRGB /Coords [0 0 1 1]>>>>");
        var s = Assert.Single(r.Shadings);
        Assert.Equal(new PdfRect(0, 0, 50, 50), s.Bounds);
        Assert.IsType<PdfDictionary>(s.Shading);
    }

    [Fact]
    public void MarkedContentCarriesMcidAndOptionalContent()
    {
        var r = Run("/Span <</MCID 4>> BDC /OC /Lyr BDC /P1 BMC 0 0 1 1 re f EMC EMC EMC",
            "/Properties <</Lyr 5 0 R>>", "<</Type /OCG /Name (Layer)>>");
        Assert.Equal(["begin Span 4", "begin OC", "begin P1", "end P1", "end OC", "end Span"], r.Events);
        Assert.Equal(4, r.Where[0].Mcid);
    }

    [Fact]
    public void AnMcidOutsideTheIntRangeIsNoStructureElement()
    {
        var r = Run("/Span <</MCID 4294967301>> BDC 0 0 1 1 re f EMC");
        Assert.Equal(["begin Span", "end Span"], r.Events);
        Assert.Null(r.Where[0].Mcid);
    }

    [Fact]
    public void BoundsAreNotANumberWhenTheMatrixOverflows()
    {
        string big = "1" + new string('0', 308);
        var path = Run($"{big} 0 0 {big} 0 0 cm {big} 0 0 {big} 0 0 cm 0 0 5 5 re f").Paths[0].Path;
        Assert.True(double.IsNaN(path.Bounds.Left));
        Assert.True(double.IsNaN(path.Bounds.Top));
    }

    [Fact]
    public void UnclosedMarkedContentIsClosedAtTheEnd()
    {
        var r = Run("/A BMC /B BMC 0 0 1 1 re f");
        Assert.Equal(["begin A", "begin B", "end B", "end A"], r.Events);
    }

    [Fact]
    public void ExtraEmcIsIgnored()
    {
        Assert.Empty(Run("EMC EMC 0 0 1 1 re f").Events);
    }

    [Fact]
    public void OptionalContentIsOnTheContext()
    {
        PdfDictionary? seen = null;
        var document = ContentTestPdf.Page("/OC /Lyr BDC 0 0 1 1 re f EMC", "/Properties <</Lyr 5 0 R>>", "<</Type /OCG /Name (L)>>");
        new ContentInterpreter(document).Run(document.Pages[0], new OcVisitor(d => seen = d));
        Assert.NotNull(seen);
        Assert.Equal("OCG", ((PdfName)seen!["Type"]!).Value);
    }

    private sealed class OcVisitor(Action<PdfDictionary?> found) : ContentVisitor
    {
        public override void PaintPath(ContentContext context, PathInfo path) => found(context.OptionalContent);
    }
}
