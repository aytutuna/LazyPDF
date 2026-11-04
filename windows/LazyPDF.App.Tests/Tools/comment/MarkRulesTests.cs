using System.Windows;
using LazyPDF.App.Tools.Comment;
using LazyPDF.App.Viewer;
using LazyPDF.Core;
using Xunit;
using FontStyles = LazyPDF.Core.FontStyles;

namespace LazyPDF.App.Tests.Tools.Comment;

// Marks on turned pages, which marks may be touched, what a restyle keeps, and what the file allows.
public sealed class MarkRulesTests
{
    private static readonly MarkStyle Red = MarkStyle.Default with { Color = [0.9, 0.1, 0.1] };

    private static CommentFixture Turned(int degrees)
    {
        var f = new CommentFixture();
        f.Document.Pages[0].Dictionary["Rotate"] = new PdfNumber(degrees);
        return f;
    }

    [Theory]
    [InlineData(90)]
    [InlineData(180)]
    [InlineData(270)]
    public void AStampOnATurnedPageStaysUprightAtItsNaturalSize(int degrees)
    {
        using var f = Turned(degrees);

        var stamp = f.Marker.AddStamp(0, new Point(200, 300), "Approved", MarkStyle.Default);

        Assert.True(stamp.Flags.HasFlag(AnnotationFlags.NoRotate));
        Assert.Equal(Marker.StampWidth, stamp.Rect.Width, 0.5);
        Assert.Equal(Marker.StampHeight, stamp.Rect.Height, 0.5);
        var box = f.Marker.BoxOf(stamp);
        Assert.Equal(200 - Marker.StampWidth / 2, box.X, 0.5);
        Assert.Equal(300 - Marker.StampHeight / 2, box.Y, 0.5);
        Assert.Equal(Marker.StampWidth, box.Width, 0.5);
        Assert.Equal(Marker.StampHeight, box.Height, 0.5);
    }

    [Fact]
    public void AStampOnAnUpPageIsNotMarkedToStayUpright()
    {
        using var f = new CommentFixture();

        var stamp = f.Marker.AddStamp(0, new Point(200, 300), "Approved", MarkStyle.Default);

        Assert.False(stamp.Flags.HasFlag(AnnotationFlags.NoRotate));
    }

    [Theory]
    [InlineData(90)]
    [InlineData(270)]
    public void ATextBoxOnATurnedPageKeepsTheSizeItWasDrawnAt(int degrees)
    {
        using var f = Turned(degrees);

        var made = f.Marker.Add(MarkTool.TextBox, 0, [new Point(60, 80), new Point(260, 140)], Red, "Hello");

        Assert.True(made.Flags.HasFlag(AnnotationFlags.NoRotate));
        var box = f.Marker.BoxOf(made);
        Assert.Equal(60, box.X, 0.5);
        Assert.Equal(80, box.Y, 0.5);
        Assert.Equal(200, box.Width, 0.5);
        Assert.Equal(60, box.Height, 0.5);
    }

    [Fact]
    public void ResizingAnUprightMarkGivesTheNewBoxBack()
    {
        using var f = Turned(90);
        var stamp = f.Marker.AddStamp(0, new Point(200, 300), "Approved", MarkStyle.Default);

        var resized = f.Marker.Resize(stamp, new Rect(100, 150, 220, 70));

        var box = f.Marker.BoxOf(resized);
        Assert.Equal(100, box.X, 0.5);
        Assert.Equal(150, box.Y, 0.5);
        Assert.Equal(220, box.Width, 0.5);
        Assert.Equal(70, box.Height, 0.5);
    }

    [Fact]
    public void ACalloutOnATurnedPageIsABoxWithAnArrowToTheSpot()
    {
        using var f = Turned(90);

        var made = f.Marker.Add(MarkTool.Callout, 0, [new Point(100, 100), new Point(300, 200)], Red, "See the chart");

        Assert.Equal(AnnotationType.FreeText, made.Type);
        Assert.True(made.Flags.HasFlag(AnnotationFlags.NoRotate));
        Assert.Contains(f.Marks(), a => a.Type == AnnotationType.Line);
    }

    [Fact]
    public void ResizingACalloutKeepsItsTextBoxInsideItsRectangle()
    {
        using var f = new CommentFixture();
        var made = f.Marker.Add(MarkTool.Callout, 0, [new Point(40, 100), new Point(380, 200)], Red, "See the chart");
        var box = f.Marker.BoxOf(made);

        var resized = f.Marker.Resize(made, new Rect(box.X, box.Y, box.Width / 2, box.Height));

        var inset = resized.RectDifference;
        Assert.Equal(4, inset.Count);
        Assert.True(inset[0] + inset[2] < resized.Rect.Width);
        Assert.True(inset[1] + inset[3] < resized.Rect.Height);
        Assert.Equal(made.RectDifference[0] / 2, inset[0], 0.5);
    }

    [Fact]
    public void OpacityAppliesToStampsAndNotesWhenTheyArePlaced()
    {
        using var f = new CommentFixture();
        var faint = Red with { Opacity = 0.4 };

        var stamp = f.Marker.AddStamp(0, new Point(200, 300), "Approved", faint);
        var note = f.Marker.Add(MarkTool.Note, 0, [new Point(100, 100)], faint, "Check");

        Assert.Equal(0.4, stamp.Opacity, 0.001);
        Assert.Equal(0.4, note.Opacity, 0.001);
    }

    [Theory]
    [InlineData(AnnotationFlags.Locked)]
    [InlineData(AnnotationFlags.ReadOnly)]
    public void AMarkTheFileLocksCannotBePickedOrErased(AnnotationFlags flag)
    {
        using var f = new CommentFixture();
        var stamp = f.Marker.AddStamp(0, new Point(200, 300), "Approved", MarkStyle.Default);
        stamp.Dictionary["F"] = new PdfNumber((int)(AnnotationFlags.Print | flag));

        Assert.Null(f.Marker.At(0, new Point(200, 300), 4));
        Assert.Empty(f.Marker.Along(0, [new Point(100, 300), new Point(300, 300)], 4));
    }

    [Fact]
    public void AHollowRectangleLeavesTheMarkInsideItReachable()
    {
        using var f = new CommentFixture();
        var quad = new TextQuad(100, 700, 180, 700, 180, 712, 100, 712);
        f.Marker.Markup(AnnotationType.Highlight, [new SelectedRun(0, default, "Hello", [quad])], MarkStyle.Default);
        var (_, top) = f.Geometry.ToDisplay(0, 706);
        f.Marker.Add(MarkTool.Rectangle, 0, [new Point(60, top - 40), new Point(300, top + 40)], Red);
        var inside = new Point(140, top);

        Assert.Equal(AnnotationType.Highlight, f.Marker.At(0, inside, 4)!.Type);
        Assert.Equal(AnnotationType.Square, f.Marker.At(0, new Point(60, top), 4)!.Type);
    }

    [Fact]
    public void AHollowOvalIsFoundOnItsOutlineOnly()
    {
        using var f = new CommentFixture();
        f.Marker.Add(MarkTool.Oval, 0, [new Point(100, 100), new Point(300, 200)], Red);

        Assert.NotNull(f.Marker.At(0, new Point(200, 100), 4));
        Assert.NotNull(f.Marker.At(0, new Point(100, 150), 4));
        Assert.Null(f.Marker.At(0, new Point(200, 150), 4));
    }

    [Fact]
    public void AFastStrokeStillCrossesAThinLineBetweenItsSamples()
    {
        using var f = new CommentFixture();
        f.Marker.Add(MarkTool.Line, 0, [new Point(200, 50), new Point(200, 250)], Red);

        var hit = f.Marker.Along(0, [new Point(100, 150), new Point(300, 150)], 4);

        Assert.Single(hit);
        Assert.Empty(f.Marker.Along(0, [new Point(100, 150), new Point(150, 150)], 4));
    }

    [Fact]
    public void ErasingInsideAHollowRectangleLeavesTheRectangle()
    {
        using var f = new CommentFixture();
        f.Marker.Add(MarkTool.Rectangle, 0, [new Point(50, 50), new Point(350, 250)], Red);
        f.Marker.Add(MarkTool.Pencil, 0, [new Point(100, 100), new Point(200, 100), new Point(200, 200)], Red);

        var hit = f.Marker.Along(0, [new Point(150, 80), new Point(150, 120)], 4);

        Assert.Equal(AnnotationType.Ink, Assert.Single(hit).Type);
    }

    [Fact]
    public void ATextBoxIsReadBackAsTheFontItWasSetIn()
    {
        using var f = new CommentFixture();
        var look = Red with { Family = "Times New Roman", Size = 18, Font = FontStyles.Bold | FontStyles.Italic };

        var made = f.Marker.Add(MarkTool.TextBox, 0, [new Point(60, 80), new Point(260, 140)], look, "Hello");

        var text = Marker.TextOf(made);
        Assert.Equal("Times New Roman", text.Family);
        Assert.Equal(18, text.Size);
        Assert.Equal(FontStyles.Bold | FontStyles.Italic, text.Font);
        Assert.Equal([0.9, 0.1, 0.1], text.TextColor!);
    }

    [Fact]
    public void ChangingTheFontOfATextBoxKeepsItsColourAndAlignment()
    {
        using var f = new CommentFixture();
        var made = f.Marker.Add(MarkTool.TextBox, 0, [new Point(60, 80), new Point(260, 140)], Red, "Hello");

        var changed = f.Marker.Restyle(made, Red with { Family = "Courier New", Size = 10, Font = FontStyles.Regular });

        var text = Marker.TextOf(changed);
        Assert.Equal("Courier New", text.Family);
        Assert.Equal(10, text.Size);
        Assert.Equal([0.9, 0.1, 0.1], text.TextColor!);
        Assert.Equal(made.Alignment, changed.Alignment);
    }

    [Fact]
    public void ColouringATextBoxPaintsTheFrameAndTheText()
    {
        using var f = new CommentFixture();
        var made = f.Marker.Add(MarkTool.TextBox, 0, [new Point(60, 80), new Point(260, 140)], Red with { Family = "Times New Roman", Size = 16 }, "Hello");

        var blue = f.Marker.Recolor(made, [0, 0, 1]);

        Assert.Equal([0.0, 0, 1], blue.Color!);
        var text = Marker.TextOf(blue);
        Assert.Equal([0.0, 0, 1], text.TextColor!);
        Assert.Equal("Times New Roman", text.Family);
        Assert.Equal(16, text.Size);
    }

    [Theory]
    [InlineData(new[] { 0.5 }, new[] { 0.5, 0.5, 0.5 })]
    [InlineData(new[] { 1.0, 0, 0 }, new[] { 1.0, 0, 0 })]
    [InlineData(new[] { 0.0, 0, 0, 1 }, new[] { 0.0, 0, 0 })]
    public void AColourOfAnyKindIsShownAsRgb(double[] given, double[] rgb) => Assert.Equal(rgb, Marker.RgbOf(given));

    [Fact]
    public void NoColourAndTransparentHaveNoRgb()
    {
        Assert.Null(Marker.RgbOf(null));
        Assert.Null(Marker.RgbOf([]));
    }

    private static void Certify(PdfDocument document, int? level)
    {
        var signature = new PdfDictionary { ["Type"] = new PdfName("Sig") };
        if (level is { } p)
        {
            var parameters = new PdfDictionary { ["P"] = new PdfNumber(p) };
            var reference = new PdfDictionary { ["TransformMethod"] = new PdfName("DocMDP"), ["TransformParams"] = parameters };
            signature["Reference"] = new PdfArray([reference]);
        }
        document.Catalog["Perms"] = new PdfDictionary { ["DocMDP"] = document.Add(signature) };
    }

    [Fact]
    public void AFileThatIsNotCertifiedTakesComments()
    {
        using var f = new CommentFixture();

        Assert.True(Exchange.CanComment(f.Document));
    }

    [Theory]
    [InlineData(1, false)]
    [InlineData(2, false)]
    [InlineData(3, true)]
    [InlineData(null, false)]
    public void ACertificationSetsWhetherCommentsMayBeAdded(int? level, bool allowed)
    {
        using var f = new CommentFixture();
        Certify(f.Document, level);

        Assert.True(f.Document.IsCertified);
        Assert.Equal(allowed, Exchange.CanComment(f.Document));
    }

    [Fact]
    public void AFileWithoutTheAnnotateRightRefusesComments()
    {
        var session = PdfEditSession.Open(Pdfs.Restricted(PdfPermissions.Print), "");
        using var tab = new LazyPDF.App.Documents.DocumentTab(session, new FakeRenderer(), null, "locked.pdf");

        Assert.False(Exchange.CanComment(tab.Document));
    }

    [Fact]
    public void ExportingFileWithNoCommentsCountsNone()
    {
        using var f = new CommentFixture();

        Assert.Equal(0, Exchange.Export(f.Document, "a.pdf", xfdf: false).Count);
    }

    [Fact]
    public void XfdfCountsWhatItCannotHold()
    {
        using var f = new CommentFixture();
        f.Marker.Add(MarkTool.Rectangle, 0, [new Point(60, 80), new Point(260, 140)], Red);
        f.Marker.AddAttachment(0, new Point(300, 100), "data.csv", [1, 2, 3]);
        f.Tab.Commit("Marks");

        var xfdf = Exchange.Export(f.Document, "a.pdf", xfdf: true);
        var fdf = Exchange.Export(f.Document, "a.pdf", xfdf: false);

        Assert.Equal(2, xfdf.Count);
        Assert.Equal(1, xfdf.Left);
        Assert.Equal(0, fdf.Left);
    }

    [Fact]
    public void ImportingTwiceReportsTheCopiesAsSkipped()
    {
        using var source = new CommentFixture();
        source.Marker.Add(MarkTool.Rectangle, 0, [new Point(60, 80), new Point(260, 140)], Red);
        source.Tab.Commit("Marks");
        using var target = new CommentFixture();
        byte[] data = Exchange.Export(source.Document, null, xfdf: false).Data;
        Exchange.Import(target.Document, data, xfdf: false, new FakeFonts());
        target.Tab.Commit("Import comments");

        var again = Exchange.Import(target.Document, data, xfdf: false, new FakeFonts());

        Assert.Equal(0, again.Imported);
        Assert.True(again.Skipped > 0);
    }

    [Fact]
    public void FlatteningStopsBetweenPagesWhenCancelled()
    {
        using var f = new CommentFixture(3);
        foreach (int page in new[] { 0, 1, 2 }) f.Marker.Add(MarkTool.Rectangle, page, [new Point(60, 80), new Point(260, 140)], Red);
        using var stop = new CancellationTokenSource();
        stop.Cancel();

        Assert.Throws<OperationCanceledException>(() => Exchange.Flatten(f.Document, stop.Token));
    }

    [Fact]
    public void ADiscardedFlattenLeavesTheFileAsItWas()
    {
        using var f = new CommentFixture();
        f.Marker.Add(MarkTool.Rectangle, 0, [new Point(60, 80), new Point(260, 140)], Red);
        f.Tab.Commit("Marks");

        Assert.Equal(1, Exchange.Flatten(f.Document, CancellationToken.None));
        f.Tab.Session.Discard();

        Assert.Single(f.Marks());
        Assert.False(f.Tab.Session.IsDirty && f.Document.HasChanges);
    }
}
