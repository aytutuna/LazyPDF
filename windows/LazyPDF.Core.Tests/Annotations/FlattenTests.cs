using LazyPDF.Core;
using Xunit;
using static LazyPDF.Core.Tests.AnnotationFixtures;

namespace LazyPDF.Core.Tests;

public class FlattenTests
{
    private static readonly MarkupQuad[] Line = [MarkupQuad.FromRect(new PdfRect(100, 500, 300, 514))];

    private static Recorder Run(PdfDocument document, int page = 0)
    {
        var recorder = new Recorder();
        new ContentInterpreter(document).Run(document.Pages[page], recorder);
        return recorder;
    }

    [Fact]
    public void AppearancesLandInThePageWhereTheAnnotationWas()
    {
        var document = Blank();
        var writer = new PdfAnnotationWriter(document);
        writer.AddTextMarkup(document.Pages[0], AnnotationType.Highlight, Line);
        writer.AddSquare(document.Pages[0], new PdfRect(200, 200, 300, 260), new AnnotationStyle(Width: 4));

        Assert.Equal(2, PdfAnnotationFlattener.Flatten(document, document.Pages[0]));
        Assert.Empty(PdfAnnotations.Read(document, document.Pages[0]));
        var paths = Run(document).Paths;
        Assert.Equal(2, paths.Count);
        Assert.Equal(new PdfRect(100, 500, 300, 514), paths[0].Path.Bounds);
        Assert.Equal(new PdfRect(202, 202, 298, 258), paths[1].Path.Bounds);
        Assert.Equal("Multiply", paths[0].State.BlendMode);
        Reopen(document);
    }

    [Fact]
    public void PageContentIsWrappedSoItsStateCannotLeakIn()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 600 800] /Resources <</Font <</F1 5 0 R>>>>>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R>>");
        pdf.Stream(4, "", "0.5 0 0 0.5 0 0 cm 1 0 0 rg q BT /F1 20 Tf 100 100 Td (Page) Tj ET");
        pdf.Obj(5, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>");
        var document = PdfDocument.Open(pdf.Finish());
        new PdfAnnotationWriter(document).AddSquare(document.Pages[0], new PdfRect(200, 200, 300, 260), new AnnotationStyle(Width: 4));

        PdfAnnotationFlattener.Flatten(document, document.Pages[0]);
        var recorder = Run(document);
        Assert.Equal("Page", recorder.Text);
        Assert.Equal(new PdfRect(202, 202, 298, 258), recorder.Paths.Single().Path.Bounds);
        Assert.NotNull(document.Dict(document.Dict(document.Pages[0].Dictionary, "Resources"), "Font"));
        Assert.Null(document.Dict(document.Dict(document.Get(2) as PdfDictionary, "Resources"), "XObject"));
        var reopened = Reopen(document);
        using var pig = UglyToad.PdfPig.PdfDocument.Open(reopened.SaveRewrite());
        Assert.Equal("Page", pig.GetPage(1).Text);
        Assert.Empty(pig.GetPage(1).GetAnnotations());
    }

    [Fact]
    public void FlattenedFreeTextIsTextOnThePage()
    {
        var document = Blank();
        new PdfAnnotationWriter(document).AddFreeText(document.Pages[0], new PdfRect(100, 600, 300, 640), "Flat words");
        PdfAnnotationFlattener.FlattenAll(document);
        Assert.Equal("Flat words", Run(document).Text);
        using var pig = UglyToad.PdfPig.PdfDocument.Open(Reopen(document).SaveRewrite());
        Assert.Contains("Flat", pig.GetPage(1).Text);
    }

    [Fact]
    public void HiddenAndNoViewAnnotationsStayAsTheyAre()
    {
        var document = Blank();
        var writer = new PdfAnnotationWriter(document);
        var page = document.Pages[0];
        writer.AddSquare(page, new PdfRect(10, 10, 50, 50), null, new AnnotationInfo(Flags: AnnotationFlags.Hidden));
        writer.AddSquare(page, new PdfRect(60, 10, 100, 50), null, new AnnotationInfo(Flags: AnnotationFlags.NoView | AnnotationFlags.Print));
        writer.AddSquare(page, new PdfRect(110, 10, 150, 50));
        Assert.Equal(1, PdfAnnotationFlattener.Flatten(document, page));
        Assert.Equal(2, PdfAnnotations.Read(document, page).Count);
    }

    [Fact]
    public void ByTypeLeavesTheOthers()
    {
        var document = Blank();
        var writer = new PdfAnnotationWriter(document);
        var page = document.Pages[0];
        writer.AddTextMarkup(page, AnnotationType.Highlight, Line);
        writer.AddSquare(page, new PdfRect(10, 10, 50, 50));
        writer.AddCircle(page, new PdfRect(60, 10, 100, 50));
        Assert.Equal(2, PdfAnnotationFlattener.Flatten(document, page, new HashSet<AnnotationType> { AnnotationType.Highlight, AnnotationType.Circle }));
        Assert.Equal(AnnotationType.Square, Assert.Single(PdfAnnotations.Read(document, page)).Type);
    }

    [Fact]
    public void AllMeansWhatOnlyShowsSomething()
    {
        var document = Blank(1, pdf =>
        {
            pdf.Obj(20, "<</Type /Annot /Subtype /Link /Rect [0 0 50 50] /Border [0 0 1] /AP <</N 30 0 R>>>>");
            pdf.Obj(21, "<</Type /Annot /Subtype /Widget /Rect [0 0 50 50] /AP <</N 30 0 R>>>>");
            pdf.Obj(22, "<</Type /Annot /Subtype /FileAttachment /Rect [0 0 50 50] /AP <</N 30 0 R>>>>");
            pdf.Obj(23, "<</Type /Annot /Subtype /Redact /Rect [0 0 50 50] /AP <</N 30 0 R>>>>");
            pdf.Obj(24, "<</Type /Annot /Subtype /Stamp /Rect [0 0 50 50] /AP <</N 30 0 R>>>>");
            pdf.Obj(25, "<</Type /Annot /Subtype /Watermark /Rect [0 0 50 50] /AP <</N 30 0 R>>>>");
            pdf.Obj(26, "<</Type /Annot /Subtype /Square /Rect [0 0 50 50]>>");
            pdf.Stream(30, "/BBox [0 0 50 50]", "0 0 50 50 re f");
        }, "/Annots [20 0 R 21 0 R 22 0 R 23 0 R 24 0 R 25 0 R 26 0 R]");
        Assert.Equal(2, PdfAnnotationFlattener.FlattenAll(document));
        Assert.Equal(["Link", "Widget", "FileAttachment", "Redact", "Square"], PdfAnnotations.Read(document, document.Pages[0]).Select(a => a.Subtype));
        Assert.Equal(2, PdfAnnotationFlattener.Flatten(document, document.Pages[0], new HashSet<AnnotationType> { AnnotationType.Widget, AnnotationType.Link }));
        Assert.Equal(3, PdfAnnotations.Read(document, document.Pages[0]).Count);
    }

    [Fact]
    public void WidgetsFlattenThroughTheirAppearanceState()
    {
        var document = Blank(1, pdf =>
        {
            pdf.Obj(20, "<</Type /Annot /Subtype /Widget /FT /Btn /Rect [10 10 30 30] /AS /Yes /AP <</N <</Yes 30 0 R /Off 31 0 R>>>>>>");
            pdf.Obj(21, "<</Type /Annot /Subtype /Widget /FT /Btn /Rect [40 10 60 30] /AS /Off /AP <</N <</Yes 30 0 R>>>>>>");
            pdf.Stream(30, "/BBox [0 0 20 20]", "0 0 20 20 re f");
            pdf.Stream(31, "/BBox [0 0 20 20]", "");
        }, "/Annots [20 0 R 21 0 R]");
        var widgets = new HashSet<AnnotationType> { AnnotationType.Widget };
        Assert.Equal(1, PdfAnnotationFlattener.Flatten(document, document.Pages[0], widgets));
        Assert.Equal(new PdfRect(10, 10, 30, 30), Run(document).Paths.Single().Path.Bounds);
        Assert.Single(PdfAnnotations.Read(document, document.Pages[0]));
    }

    [Fact]
    public void FormMatrixAndBoxAreFittedToTheRectangle()
    {
        var document = Blank(1, pdf =>
        {
            pdf.Obj(20, "<</Type /Annot /Subtype /Stamp /Rect [100 100 300 150] /AP <</N 30 0 R>>>>");
            pdf.Stream(30, "/Subtype /Form /BBox [0 0 10 20] /Matrix [0 1 -1 0 0 0]", "0 0 10 20 re f");
        }, "/Annots [20 0 R]");
        PdfAnnotationFlattener.FlattenAll(document);
        var bounds = Run(document).Paths.Single().Path.Bounds;
        Assert.Equal(100, bounds.Left, 3);
        Assert.Equal(300, bounds.Right, 3);
        Assert.Equal(100, bounds.Bottom, 3);
        Assert.Equal(150, bounds.Top, 3);
    }

    [Fact]
    public void PopupsAndRepliesGoWithTheirParent()
    {
        var document = Blank(1);
        var writer = new PdfAnnotationWriter(document);
        var square = writer.AddSquare(document.Pages[0], new PdfRect(10, 10, 80, 80), null, new AnnotationInfo("A", "box"));
        var reply = PdfComments.Reply(document, square, "re", "B", new DateTimeOffset(2026, 1, 1, 0, 0, 0, TimeSpan.Zero));
        PdfComments.Reply(document, reply, "re re", "C", new DateTimeOffset(2026, 1, 2, 0, 0, 0, TimeSpan.Zero));
        var keep = writer.AddCircle(document.Pages[0], new PdfRect(100, 10, 180, 80));
        Assert.Equal(1, PdfAnnotationFlattener.Flatten(document, document.Pages[0], new HashSet<AnnotationType> { AnnotationType.Square }));
        Assert.Equal(keep.Name, Assert.Single(PdfAnnotations.Read(document, document.Pages[0])).Name);
        Assert.Null(document.Get(square.Reference!.Number));
    }

    [Fact]
    public void NothingToDoLeavesThePageUntouched()
    {
        var document = Blank();
        Assert.Equal(0, PdfAnnotationFlattener.FlattenAll(document));
        Assert.Null(document.Pages[0].Dictionary["Contents"]);
        var bytes = document.SaveIncremental();
        Assert.Equal(document.Length, bytes.Length);
    }

    [Fact]
    public void AnAnnotationWithoutAnAppearanceStays()
    {
        var document = Blank(1, pdf => pdf.Obj(20, "<</Type /Annot /Subtype /Square /Rect [0 0 50 50]>>"), "/Annots [20 0 R]");
        Assert.Equal(0, PdfAnnotationFlattener.FlattenAll(document));
        Assert.Single(PdfAnnotations.Read(document, document.Pages[0]));
    }
}
