using System.Reflection;
using System.Windows;
using LazyPDF.App.Documents;
using LazyPDF.App.Tools.FillSign;
using LazyPDF.App.Viewer;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// Where a signature or a line of text lands on the page, and that the placing is one undoable step.
[Collection("Application")]
public sealed class FillSignPlacementTests
{
    private static readonly Size Page = new(612, 792);
    private static readonly PdfRgbaImage Ink = new(2, 1, [0, 0, 0, 255, 0, 0, 0, 255]);

    private static DocumentTab NewTab() => new(PdfEditSession.Open(Pdfs.Text()), new FakeRenderer(), null, "a.pdf");

    private static double PageHeight(DocumentTab tab) => new PageGeometry(tab.Document.Pages[0]).Height;

    [Fact]
    public void AClickCentresTheBox()
    {
        var box = FillSignPlacement.Around(new Point(300, 400), 150, 3, Page);

        Assert.Equal(new DisplayRect(225, 375, 150, 50), box);
    }

    [Fact]
    public void AClickAtTheEdgeKeepsTheBoxOnThePage()
    {
        var box = FillSignPlacement.Around(new Point(5, 790), 150, 3, Page);

        Assert.Equal(0, box.X);
        Assert.Equal(742, box.Y);
    }

    [Fact]
    public void ADragKeepsTheProportionsOfThePicture()
    {
        var box = FillSignPlacement.FromDrag(new Point(100, 100), new Point(400, 150), 3, Page);

        Assert.Equal(new DisplayRect(100, 100, 150, 50), box);
    }

    [Fact]
    public void ADragUpAndToTheLeftFillsTheSameCorner()
    {
        var box = FillSignPlacement.FromDrag(new Point(400, 300), new Point(300, 100), 2, Page);

        Assert.Equal(100, box.Width);
        Assert.Equal(50, box.Height);
        Assert.Equal(300, box.X);
        Assert.Equal(250, box.Y);
    }

    [Fact]
    public void ASignatureIsAStampAtTheBoxInPageSpace()
    {
        using var tab = NewTab();

        Assert.True(FillSignPlacement.PlaceImage(tab, 0, new DisplayRect(100, 100, 150, 50), Ink, DateTimeOffset.Now));

        var stamp = Assert.Single(PdfAnnotations.ReadAll(tab.Document));
        Assert.Equal(AnnotationType.Stamp, stamp.Type);
        Assert.Equal(100, stamp.Rect.Left, 3);
        Assert.Equal(PageHeight(tab) - 150, stamp.Rect.Bottom, 3);
        Assert.Equal(150, stamp.Rect.Width, 3);
    }

    [Fact]
    public void PlacingASignatureCanBeUndone()
    {
        using var tab = NewTab();
        FillSignPlacement.PlaceImage(tab, 0, new DisplayRect(10, 10, 60, 20), Ink, DateTimeOffset.Now);

        Assert.True(tab.Undo());

        Assert.Empty(PdfAnnotations.ReadAll(tab.Document));
    }

    [Fact]
    public void TextIsFreeTextWithItsWordsAtTheClick()
    {
        OnSta.Run(() =>
        {
            using var tab = NewTab();

            Assert.True(FillSignPlacement.PlaceText(tab, new FakeFonts(), 0, new Point(72, 200), "Approved", 12, [0, 0, 0], DateTimeOffset.Now));

            var note = Assert.Single(PdfAnnotations.ReadAll(tab.Document));
            Assert.Equal(AnnotationType.FreeText, note.Type);
            Assert.Equal("Approved", note.Contents);
            Assert.Equal(72, note.Rect.Left, 3);
            Assert.True(note.Rect.Top < PageHeight(tab) - 190 && note.Rect.Bottom > PageHeight(tab) - 215);
        });
    }

    [Fact]
    public void PlacedTextKeepsItsColour()
    {
        OnSta.Run(() =>
        {
            using var tab = NewTab();

            FillSignPlacement.PlaceText(tab, new FakeFonts(), 0, new Point(72, 200), "Approved", 12, [0.1, 0.3, 0.8], DateTimeOffset.Now);

            var note = Assert.Single(PdfAnnotations.ReadAll(tab.Document));
            Assert.Contains("0.1 0.3 0.8 rg", note.DefaultAppearance);
        });
    }

    [Fact]
    public void TextTheFontsCannotDrawChangesNothing()
    {
        OnSta.Run(() =>
        {
            using var tab = NewTab();

            Assert.Throws<InvalidOperationException>(() => FillSignPlacement.PlaceText(tab, new FakeFonts(), 0, new Point(72, 200), "Çağrı", 12, [0, 0, 0], DateTimeOffset.Now));

            Assert.False(tab.IsDirty);
            Assert.Empty(PdfAnnotations.ReadAll(tab.Document));
        });
    }

    // A page the viewer has not laid out has no size, so the box is empty, which is found after the picture is in the file.
    [Fact]
    public Task APlacementThatFailsAfterAddingToTheFileIsTakenBack() => Sta.Run(() =>
    {
        using var dir = new TempDir();
        using var tab = new DocumentTab(PdfEditSession.Open(Pdfs.Text(1)), new FakeRenderer(), null, "a.pdf", null);
        var host = new RecordingHost();
        var panel = new FillSignPanel(dir.Sub("sigs"));
        panel.Attach(tab, DispatchProxy.Create<IDocumentViewer, FlatViewer>(), host);
        var flags = BindingFlags.Instance | BindingFlags.NonPublic;
        typeof(FillSignPanel).GetField("_image", flags)!.SetValue(panel, Ink);

        typeof(FillSignPanel).GetMethod("Placed", flags)!.Invoke(panel, [0, new Point(50, 50), null]);

        Assert.Equal("Nothing to place", host.Problems.Single().Title);
        Assert.False(tab.Document.HasChanges);
        Assert.Empty(PdfAnnotations.ReadAll(tab.Document));
        return Task.CompletedTask;
    });

    private class FlatViewer : FakeViewer
    {
        protected override object? Invoke(MethodInfo? method, object?[]? args) => method!.Name == "PageSize" ? new Size(0, 0) : base.Invoke(method, args);
    }

    private static DocumentTab Turned(int degrees)
    {
        var tab = NewTab();
        PageOperations.Rotate(tab.Document, [0], degrees);
        tab.Commit("Rotate");
        return tab;
    }

    private static PdfStream Appearance(DocumentTab tab, PdfAnnotation annotation) =>
        (PdfStream)tab.Document.Resolve(tab.Document.Dict(annotation.Dictionary, "AP")!["N"])!;

    [Theory]
    [InlineData(90, new[] { 0, 1, -1, 0 })]
    [InlineData(180, new[] { -1, 0, 0, -1 })]
    [InlineData(270, new[] { 0, -1, 1, 0 })]
    public void ASignatureOnATurnedPageIsDrawnUprightAndTurnedBack(int degrees, int[] matrix)
    {
        using var tab = Turned(degrees);

        FillSignPlacement.PlaceImage(tab, 0, new DisplayRect(100, 100, 150, 50), Ink, DateTimeOffset.Now);

        var stamp = Assert.Single(PdfAnnotations.ReadAll(tab.Document));
        bool sideways = degrees != 180;
        Assert.Equal(sideways ? 50 : 150, stamp.Rect.Width, 3);
        Assert.Equal(sideways ? 150 : 50, stamp.Rect.Height, 3);
        var form = Appearance(tab, stamp);
        Assert.Equal(new PdfRect(0, 0, 150, 50), tab.Document.Rect(form.Dictionary, "BBox"));
        var turn = tab.Document.Array(form.Dictionary, "Matrix")!.Items.Cast<PdfNumber>().Select(n => (int)n.Value).Take(4);
        Assert.Equal(matrix, turn);
    }

    [Fact]
    public void ASignatureOnAnUprightPageIsNotTurned()
    {
        using var tab = NewTab();
        FillSignPlacement.PlaceImage(tab, 0, new DisplayRect(100, 100, 150, 50), Ink, DateTimeOffset.Now);

        var stamp = Assert.Single(PdfAnnotations.ReadAll(tab.Document));

        Assert.Equal((150, 50), (stamp.Rect.Width, stamp.Rect.Height));
        var matrix = tab.Document.Array(Appearance(tab, stamp).Dictionary, "Matrix")?.Items.Cast<PdfNumber>().Select(n => (int)n.Value);
        Assert.True(matrix is null || matrix.SequenceEqual([1, 0, 0, 1, 0, 0]));
    }

    [Fact]
    public void TextOnATurnedPageHasRoomForItsLines()
    {
        OnSta.Run(() =>
        {
            using var tab = Turned(90);

            FillSignPlacement.PlaceText(tab, new FakeFonts(), 0, new Point(72, 200), "4 November 2026", 12, [0, 0, 0], DateTimeOffset.Now);

            var note = Assert.Single(PdfAnnotations.ReadAll(tab.Document));
            var form = Appearance(tab, note);
            var shown = tab.Document.Rect(form.Dictionary, "BBox")!.Value;
            Assert.True(shown.Width > shown.Height);
            Assert.Equal(shown.Width, note.Rect.Height, 3);
            Assert.Equal(shown.Height, note.Rect.Width, 3);
            Assert.NotNull(form.Dictionary["Matrix"]);
        });
    }

    [Theory]
    [InlineData(MarkShape.Check, AnnotationType.Ink, 0)]
    [InlineData(MarkShape.Cross, AnnotationType.Ink, 0)]
    [InlineData(MarkShape.Dot, AnnotationType.Circle, 0)]
    [InlineData(MarkShape.Line, AnnotationType.Line, 0)]
    [InlineData(MarkShape.Check, AnnotationType.Ink, 90)]
    [InlineData(MarkShape.Cross, AnnotationType.Ink, 90)]
    [InlineData(MarkShape.Dot, AnnotationType.Circle, 90)]
    [InlineData(MarkShape.Line, AnnotationType.Line, 90)]
    public void EachMarkIsOneAnnotationKeptOnThePage(MarkShape shape, AnnotationType type, int degrees)
    {
        using var tab = degrees == 0 ? NewTab() : Turned(degrees);
        var geometry = new PageGeometry(tab.Document.Pages[0]);

        Assert.True(FillSignPlacement.PlaceMark(tab, 0, shape, new Point(3, geometry.Height - 2), null, 24, [0.8, 0.1, 0.1], DateTimeOffset.Now));

        var mark = Assert.Single(PdfAnnotations.ReadAll(tab.Document));
        Assert.Equal(type, mark.Type);
        var page = tab.Document.Pages[0].MediaBox;
        Assert.True(mark.Rect.Left >= page.Left - 2 && mark.Rect.Bottom >= page.Bottom - 2 && mark.Rect.Right <= page.Right + 2 && mark.Rect.Top <= page.Top + 2);
        if (shape == MarkShape.Dot) Assert.NotNull(mark.InteriorColor);
        Assert.True(tab.Undo());
        Assert.Empty(PdfAnnotations.ReadAll(tab.Document));
    }

    [Theory]
    [InlineData(MarkShape.Check)]
    [InlineData(MarkShape.Cross)]
    [InlineData(MarkShape.Dot)]
    public void ASlippedClickStillMakesAMarkOfTheChosenSize(MarkShape shape)
    {
        using var tab = NewTab();

        FillSignPlacement.PlaceMark(tab, 0, shape, new Point(200, 200), new Point(206, 201), 24, [0, 0, 0], DateTimeOffset.Now);

        var mark = Assert.Single(PdfAnnotations.ReadAll(tab.Document));
        Assert.True(mark.Rect.Width > 20);
    }

    [Fact]
    public void ALineTakesTheDragAsItsEnds()
    {
        using var tab = NewTab();

        FillSignPlacement.PlaceMark(tab, 0, MarkShape.Line, new Point(100, 100), new Point(300, 100), 12, [0, 0, 0], DateTimeOffset.Now);

        var line = Assert.Single(PdfAnnotations.ReadAll(tab.Document));
        Assert.True(line.Rect.Width > 200 && line.Rect.Width < 205);
    }

    [Fact]
    public void ASignedFileIsCautionedAndAPlainOneIsNot()
    {
        using var signed = NewTab();
        using var ada = PdfDigitalId.Create("Ada", null, DateTimeOffset.Now.AddDays(-1), years: 1, keyBits: 2048);
        PdfSigner.Sign(signed.Session, new PdfSignRequest(ada, DateTimeOffset.Now) { Fonts = new FakeFonts() });
        using var plain = NewTab();

        Assert.NotNull(FillSignPlacement.Caution(signed.Document));
        Assert.Null(FillSignPlacement.Caution(plain.Document));
    }

    [Fact]
    public void AFileThatForbidsCommentsRefusesStampsAndText()
    {
        var locked = PdfDocument.Open(Pdfs.Restricted(PdfPermissions.Print), "");
        var owner = PdfDocument.Open(Pdfs.Restricted(PdfPermissions.Print), "owner");

        Assert.NotNull(FillSignPlacement.Refusal(locked));
        Assert.Null(FillSignPlacement.Refusal(owner));
        Assert.Null(FillSignPlacement.Refusal(PdfDocument.Open(Pdfs.Text())));
    }
}
