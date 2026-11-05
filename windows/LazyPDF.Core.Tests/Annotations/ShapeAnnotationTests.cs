using LazyPDF.Core;
using Xunit;
using static LazyPDF.Core.Tests.AnnotationFixtures;

namespace LazyPDF.Core.Tests;

public class ShapeAnnotationTests
{
    private const double Slack = 2.5;

    private static (PdfDocument Document, PdfAnnotationWriter Writer, PdfPage Page) Start()
    {
        var document = Blank();
        return (document, new PdfAnnotationWriter(document), document.Pages[0]);
    }

    private static Recorder Draw(PdfDocument document, PdfAnnotation annotation)
    {
        var recorder = new Recorder();
        new ContentInterpreter(document).Run(Normal(document, annotation), recorder);
        return recorder;
    }

    [Fact]
    public void SquareStrokesInsideItsRectangle()
    {
        var (document, writer, page) = Start();
        var square = writer.AddSquare(page, new PdfRect(100, 600, 200, 650), new AnnotationStyle([0, 0, 1], Width: 4, Fill: [1, 1, 0]), new AnnotationInfo("A"));
        var path = Draw(document, square).Paths.Single().Path;
        Assert.Equal("B", path.Operator);
        Assert.Equal(new PdfRect(2, 2, 98, 48), path.Bounds);
        Assert.Equal([0d, 0d, 1d], square.Color);
        Assert.Equal([1d, 1d, 0d], square.InteriorColor);
        Assert.Equal(4, square.Border.Width);
    }

    [Fact]
    public void CircleIsFourCurves()
    {
        var (document, writer, page) = Start();
        var circle = writer.AddCircle(page, new PdfRect(100, 600, 160, 660));
        var path = Draw(document, circle).Paths.Single().Path;
        Assert.Equal("S", path.Operator);
        Assert.Equal(4, path.Segments.Count(s => s.Kind == PathSegmentKind.Curve));
        Assert.Equal(59, path.Bounds.Width, 0.1);
    }

    [Fact]
    public void ZeroWidthWithoutFillDrawsNothing()
    {
        var (document, writer, page) = Start();
        var square = writer.AddSquare(page, new PdfRect(100, 600, 200, 650), new AnnotationStyle(Width: 0));
        Assert.DoesNotContain(Draw(document, square).Paths, p => p.Path.Stroke || p.Path.Fill);
    }

    [Fact]
    public void DashedBorderSetsTheDashPattern()
    {
        var (document, writer, page) = Start();
        var square = writer.AddSquare(page, new PdfRect(100, 600, 200, 650), new AnnotationStyle(Dash: [4, 2]));
        Assert.Equal(BorderStyle.Dashed, square.Border.Style);
        Assert.Equal([4d, 2d], square.Border.Dash);
        var dash = Appearance(document, square).Single(o => o.Operator == "d");
        Assert.Equal(2, ((PdfArray)dash.Operands[0]).Items.Count);
    }

    [Theory]
    [InlineData(AnnotationType.Square)]
    [InlineData(AnnotationType.Circle)]
    public void CloudBorderMakesScallopsWithinTheBox(AnnotationType kind)
    {
        var (document, writer, page) = Start();
        var rect = new PdfRect(100, 600, 260, 700);
        var cloud = kind == AnnotationType.Square
            ? writer.AddSquare(page, rect, new AnnotationStyle(Cloud: 2))
            : writer.AddCircle(page, rect, new AnnotationStyle(Cloud: 2));
        Assert.Equal(2, cloud.Cloud);
        Assert.Equal(4, cloud.RectDifference.Count);
        var path = Draw(document, cloud).Paths.Single().Path;
        Assert.True(path.Segments.Count(s => s.Kind == PathSegmentKind.Curve) > 20);
        // The arcs stay inside the appearance's box, or the viewer would clip them. The bounds count
        // control points, which stand a third further out than the curve does.
        Assert.True(path.Bounds.Left >= -Slack && path.Bounds.Bottom >= -Slack);
        Assert.True(path.Bounds.Right <= rect.Width + Slack && path.Bounds.Top <= rect.Height + Slack);
    }

    [Fact]
    public void CloudPolygonBulgesOutwardWhicheverWayItIsDrawn()
    {
        var (document, writer, page) = Start();
        (double, double)[] ccw = [(100, 600), (200, 600), (200, 700), (100, 700)];
        foreach (var points in new[] { ccw, [.. ccw.Reverse()] })
        {
            var cloud = writer.AddCloud(page, points);
            var bounds = Draw(document, cloud).Paths.Single().Path.Bounds;
            Assert.True(bounds.Width > 100 + 3, "the arcs should stick out past the corners");
            Assert.True(bounds.Right <= cloud.Rect.Width + Slack && bounds.Left >= -Slack);
            Assert.Equal("PolygonCloud", document.Name(cloud.Dictionary, "IT"));
            Assert.Equal(1, cloud.Cloud);
        }
    }

    [Fact]
    public void LineDrawsFromOnePointToTheOther()
    {
        var (document, writer, page) = Start();
        var line = writer.AddLine(page, (100, 600), (300, 650), new AnnotationStyle(Width: 2));
        Assert.Equal([100d, 600d, 300d, 650d], line.Line);
        var path = Draw(document, line).Paths.Single().Path;
        Assert.Equal(2, path.Segments.Count);
        Assert.Equal(100 - line.Rect.Left, path.Segments[0].X1, 3);
        Assert.Equal(650 - line.Rect.Bottom, path.Segments[1].Y1, 3);
    }

    [Theory]
    [InlineData(LineEnding.Square)]
    [InlineData(LineEnding.Circle)]
    [InlineData(LineEnding.Diamond)]
    [InlineData(LineEnding.OpenArrow)]
    [InlineData(LineEnding.ClosedArrow)]
    [InlineData(LineEnding.Butt)]
    [InlineData(LineEnding.ROpenArrow)]
    [InlineData(LineEnding.RClosedArrow)]
    [InlineData(LineEnding.Slash)]
    public void EveryLineEndingIsDrawnAndKeptInsideTheBox(LineEnding ending)
    {
        var (document, writer, page) = Start();
        var line = writer.AddLine(page, (100, 600), (300, 650), new AnnotationStyle([1, 0, 0], 2, Fill: [0, 1, 0]), null, ending, ending);
        Assert.Equal(ending, line.StartEnding);
        Assert.Equal(ending, line.EndEnding);
        var recorder = Draw(document, line);
        Assert.Equal(3, recorder.Paths.Count);
        foreach (var (path, _) in recorder.Paths)
        {
            Assert.True(path.Bounds.Left >= -0.01 && path.Bounds.Bottom >= -0.01);
            Assert.True(path.Bounds.Right <= line.Rect.Width + 0.01 && path.Bounds.Top <= line.Rect.Height + 0.01);
        }
        bool closed = ending is LineEnding.ClosedArrow or LineEnding.RClosedArrow or LineEnding.Square or LineEnding.Circle or LineEnding.Diamond;
        Assert.Equal(closed, recorder.Paths.Skip(1).All(p => p.Path.Fill));
    }

    [Fact]
    public void ArrowHeadSitsAtTheEndPoint()
    {
        var (document, writer, page) = Start();
        var arrow = writer.AddArrow(page, (100, 600), (300, 600), new AnnotationStyle(Width: 2));
        Assert.Equal("LineArrow", document.Name(arrow.Dictionary, "IT"));
        Assert.Equal(LineEnding.OpenArrow, arrow.EndEnding);
        var head = Draw(document, arrow).Paths.Last().Path;
        var tip = head.Segments[1];
        Assert.Equal(300 - arrow.Rect.Left, tip.X1, 3);
        Assert.Equal(600 - arrow.Rect.Bottom, tip.Y1, 3);
        Assert.True(head.Segments[0].X1 < tip.X1);
    }

    [Fact]
    public void PolyLineAndPolygonUseTheirVertices()
    {
        var (document, writer, page) = Start();
        (double, double)[] points = [(100, 600), (150, 650), (200, 600), (250, 650)];
        var polyline = writer.AddPolyLine(page, points, new AnnotationStyle([0, 0, 1]), null, LineEnding.None, LineEnding.ClosedArrow);
        var polygon = writer.AddPolygon(page, points, new AnnotationStyle([0, 0, 1], Fill: [1, 0.8, 0.8]));
        Assert.Equal(8, polyline.Vertices.Count);
        Assert.Equal(AnnotationType.PolyLine, polyline.Type);
        Assert.Equal(AnnotationType.Polygon, polygon.Type);
        Assert.Equal(4, Draw(document, polyline).Paths[0].Path.Segments.Count);
        var filled = Draw(document, polygon).Paths.Single().Path;
        Assert.Equal("B", filled.Operator);
        Assert.Equal(5, filled.Segments.Count);
    }

    [Fact]
    public void InkStrokesAreSmoothedWithRoundCaps()
    {
        var (document, writer, page) = Start();
        (double, double)[] stroke = [(100, 600), (110, 620), (130, 625), (150, 610), (170, 640)];
        var ink = writer.AddInk(page, [stroke, [(300, 600)]], new AnnotationStyle([0, 0, 0], 3));
        Assert.Equal(2, ink.InkList.Count);
        Assert.Equal(10, ink.InkList[0].Count);
        var ops = Appearance(document, ink);
        Assert.Contains(ops, o => o.Operator == "J");
        Assert.Contains(ops, o => o.Operator == "c");
        Assert.Equal(2, ops.Count(o => o.Operator == "S"));
    }

    [Fact]
    public void OpacityGoesIntoTheAppearance()
    {
        var (document, writer, page) = Start();
        var ink = writer.AddInk(page, [[(100, 600), (120, 640)]], new AnnotationStyle(Opacity: 0.4));
        Assert.Equal(0.4, ink.Opacity);
        var state = document.Dict(document.Dict(document.Dict(Normal(document, ink).Dictionary, "Resources"), "ExtGState"), "GS1")!;
        Assert.Equal(0.4, document.Number(state, "CA"));
        Assert.Equal("Normal", document.Name(state, "BM"));
    }

    [Fact]
    public void ShapesReopenInPdfPig()
    {
        var (document, writer, page) = Start();
        writer.AddSquare(page, new PdfRect(10, 10, 60, 60));
        writer.AddCircle(page, new PdfRect(70, 10, 120, 60));
        writer.AddLine(page, (10, 100), (100, 120));
        writer.AddPolygon(page, [(10, 200), (50, 250), (90, 200)]);
        writer.AddInk(page, [[(10, 300), (20, 320)]]);
        Reopen(document);
        using var pig = UglyToad.PdfPig.PdfDocument.Open(document.SaveRewrite());
        var types = pig.GetPage(1).GetAnnotations().Select(a => a.Type).ToList();
        Assert.Equal(5, types.Count);
        Assert.Contains(UglyToad.PdfPig.Annotations.AnnotationType.Ink, types);
    }

    [Fact]
    public void RefusesDegenerateInput()
    {
        var (_, writer, page) = Start();
        Assert.Throws<ArgumentException>(() => writer.AddPolygon(page, [(1, 1), (2, 2)]));
        Assert.Throws<ArgumentException>(() => writer.AddPolyLine(page, [(1, 1)]));
        Assert.Throws<ArgumentException>(() => writer.AddInk(page, []));
        Assert.Throws<ArgumentException>(() => writer.AddSquare(page, new PdfRect(5, 5, 5, 5), new AnnotationStyle(Width: 0)));
        Assert.Throws<ArgumentException>(() => writer.AddStamp(page, new PdfRect(5, 5, 5, 5), "Draft"));
        Assert.Throws<ArgumentException>(() => writer.AddFreeText(page, new PdfRect(5, 5, 5, 5), "x"));
        Assert.Throws<ArgumentException>(() => writer.AddImageStamp(page, new PdfRect(5, 5, 5, 5), 1, 1, [0, 0, 0, 255]));
    }

    [Fact]
    public void CloudBorderOfAnInfiniteEdgeStaysSmall()
    {
        (double X, double Y)[] corners = [(double.NegativeInfinity, 0), (10, 0), (10, 50), (double.NegativeInfinity, 50)];
        Assert.Equal(4, CloudBorder.Resample(corners, 10).Count);
        Assert.Equal(4, CloudBorder.RectPoints(double.NegativeInfinity, 0, 10, 50, 10).Count);
    }
}
