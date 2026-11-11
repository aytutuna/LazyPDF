using LazyPDF.App.Tools.Measure;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// Measurements written into a real file and read back by the engine.
public sealed class MeasureWriterTests
{
    private static readonly MeasureScale Scale = new(1, LengthUnit.Inch, 10, LengthUnit.Metre);
    private static readonly DateTimeOffset Date = new(2026, 1, 5, 9, 0, 0, TimeSpan.Zero);

    private static readonly MeasureItem Line = new(MeasureKind.Distance, 0, [new(100, 100), new(172, 100)]);
    private static readonly MeasureItem Room = new(MeasureKind.Area, 0, [new(100, 200), new(172, 200), new(172, 272), new(100, 272)]);

    private static IReadOnlyList<PdfAnnotation> WriteAndReopen(params MeasureItem[] items) => WriteAndReopen(out _, items);

    private static IReadOnlyList<PdfAnnotation> WriteAndReopen(out PdfDocument reopened, params MeasureItem[] items)
    {
        var session = PdfEditSession.Open(Pdfs.Text());
        int count = MeasureWriter.Write(session.Document, items, Scale, "Sam", Date);
        Assert.Equal(items.Length, count);
        Assert.True(session.Commit("Measure"));
        reopened = PdfDocument.Open(session.Current.ToArray());
        return PdfAnnotations.Read(reopened, reopened.Pages[0]);
    }

    [Fact]
    public void TheScaleIsFoundAgainInTheFile()
    {
        WriteAndReopen(out var document, Line);

        Assert.Equal(Scale, MeasureScale.Find(document));
        Assert.Null(MeasureScale.Find(PdfDocument.Open(Pdfs.Text())));
    }

    [Fact]
    public void ScalesThePanelCannotShowAreSkipped()
    {
        var session = PdfEditSession.Open(Pdfs.Text());
        var usable = new MeasureScale(1, LengthUnit.Millimetre, 10, LengthUnit.Metre);
        MeasureWriter.Write(session.Document, [Line], new MeasureScale(1, LengthUnit.Metre, 1, LengthUnit.Metre), "Sam", Date);
        MeasureWriter.Write(session.Document, [Line], usable, "Sam", Date);
        Assert.True(session.Commit("Measure"));

        Assert.Equal(usable, MeasureScale.Find(PdfDocument.Open(session.Current.ToArray())));
    }

    [Fact]
    public void ADistanceIsALineWithItsScale()
    {
        var all = WriteAndReopen(out var document, Line);

        var line = Assert.Single(all, a => a.Type == AnnotationType.Line);
        Assert.Equal("Distance: 10 m", line.Contents);
        Assert.Equal("Sam", line.Title);
        Assert.Equal(4, line.Line.Count);
        var measure = Assert.IsType<PdfDictionary>(line.Dictionary["Measure"]);
        Assert.Equal("Measure", ((PdfName)measure["Type"]!).Value);
        Assert.Equal("RL", ((PdfName)measure["Subtype"]!).Value);
        var x = Assert.IsType<PdfDictionary>(Assert.Single(((PdfArray)measure["X"]!).Items));
        Assert.Equal(10d / 72, ((PdfNumber)x["C"]!).Value, 9);
        Assert.Equal("m", PdfText.Read(document, x, "U"));
        var distance = Assert.IsType<PdfDictionary>(Assert.Single(((PdfArray)measure["D"]!).Items));
        Assert.Equal(1, ((PdfNumber)distance["C"]!).Value);
        var area = Assert.IsType<PdfDictionary>(Assert.Single(((PdfArray)measure["A"]!).Items));
        Assert.Equal(1, ((PdfNumber)area["C"]!).Value);
    }

    [Fact]
    public void XFollowsTheUserUnitOfThePageAndNothingElseDoes()
    {
        var session = PdfEditSession.Open(Pdfs.Text());
        session.Document.Pages[0].Dictionary["UserUnit"] = new PdfNumber(2L);
        MeasureWriter.Write(session.Document, [Line], Scale, "Sam", Date);
        session.Commit("Measure");

        var reopened = PdfDocument.Open(session.Current.ToArray());
        var line = PdfAnnotations.Read(reopened, reopened.Pages[0]).Single(a => a.Type == AnnotationType.Line);
        var measure = Assert.IsType<PdfDictionary>(line.Dictionary["Measure"]);
        double C(string key) => ((PdfNumber)Assert.IsType<PdfDictionary>(Assert.Single(((PdfArray)measure[key]!).Items))["C"]!).Value;
        Assert.Equal(2 * 10d / 72, C("X"), 9);
        Assert.Equal(1, C("D"));
        Assert.EndsWith("10 m", line.Contents);
    }

    [Fact]
    public void APerimeterIsAnOpenPolylineThatComesBackToItsStart()
    {
        var walk = new MeasureItem(MeasureKind.Perimeter, 0, [new(100, 100), new(172, 100), new(172, 172)]);

        var all = WriteAndReopen(walk);

        var polyline = Assert.Single(all, a => a.Type == AnnotationType.PolyLine);
        Assert.Equal("PolyLineDimension", ((PdfName)polyline.Dictionary["IT"]!).Value);
        Assert.Equal(4, polyline.Vertices.Count / 2);
        Assert.Equal(polyline.Vertices[0], polyline.Vertices[6], 6);
        Assert.Equal(polyline.Vertices[1], polyline.Vertices[7], 6);
        Assert.DoesNotContain(all, a => a.Type == AnnotationType.Polygon);
    }

    [Fact]
    public void OnATurnedPageTheValueBoxIsShownUprightWhereTheMiddleIs()
    {
        var session = PdfEditSession.Open(Pdfs.Text());
        var page = session.Document.Pages[0];
        page.Dictionary["Rotate"] = new PdfNumber(90L);
        MeasureWriter.Write(session.Document, [Line], Scale, "Sam", Date);
        session.Commit("Measure");

        var reopened = PdfDocument.Open(session.Current.ToArray());
        var label = PdfAnnotations.Read(reopened, reopened.Pages[0]).Single(a => a.Type == AnnotationType.FreeText);
        var shown = new PageGeometry(reopened.Pages[0]).ToDisplay(label.Rect);
        Assert.True(shown.Width > shown.Height);
        Assert.Equal(136, shown.X + shown.Width / 2, 6);
        Assert.Equal(100, shown.Y + shown.Height / 2, 6);
        var form = Assert.IsType<PdfStream>(reopened.Resolve(((PdfDictionary)label.Dictionary["AP"]!)["N"]));
        Assert.Equal([0d, 1, -1, 0, 0, 0], ((PdfArray)form.Dictionary["Matrix"]!).Items.Select(n => ((PdfNumber)n).Value));
    }

    [Fact]
    public void AMeasurementOnAPageThatIsGoneWritesNothing()
    {
        var session = PdfEditSession.Open(Pdfs.Text());
        var gone = new MeasureItem(MeasureKind.Distance, 4, [new(0, 0), new(10, 0)]);

        Assert.ThrowsAny<ArgumentException>(() => MeasureWriter.Write(session.Document, [Line, gone], Scale, "Sam", Date));

        Assert.False(session.Commit("Measure"));
    }

    [Fact]
    public void AGroupSeparatorThatNoStandardFontHasDoesNotCostTheValueBox()
    {
        var before = System.Globalization.CultureInfo.CurrentCulture;
        System.Globalization.CultureInfo.CurrentCulture = new System.Globalization.CultureInfo("fr-FR");
        try
        {
            var odd = new MeasureScale(1, LengthUnit.Inch, 1234, LengthUnit.Millimetre);
            var session = PdfEditSession.Open(Pdfs.Text());
            var item = new MeasureItem(MeasureKind.Distance, 0, [new(0, 0), new(72, 0)]);

            MeasureWriter.Write(session.Document, [item], odd, "Sam", Date, new LazyPDF.App.Services.SystemFontSource());
            session.Commit("Measure");

            var reopened = PdfDocument.Open(session.Current.ToArray());
            var label = Assert.Single(PdfAnnotations.Read(reopened, reopened.Pages[0]), a => a.Type == AnnotationType.FreeText);
            Assert.Equal("1 234 mm", label.Contents);
        }
        finally
        {
            System.Globalization.CultureInfo.CurrentCulture = before;
        }
    }
}
