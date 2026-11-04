using LazyPDF.App.Documents;
using LazyPDF.App.Tools.EditContent;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests.Tools.Edit;

// Pictures, shapes, links, the copy a replace-all makes, and the permission check, on real documents.
public sealed class ObjectEditsTests
{
    private const string DirectLink = "/Annots [<< /Type /Annot /Subtype /Link /Rect [50 700 200 720] /Border [0 0 2] /C [1 0 0] /A << /S /URI /URI (https://old.example) >> >>]";

    private static DocumentTab Open(byte[]? bytes = null) =>
        new(PdfEditSession.Open(bytes ?? EditPdf.Make("")), new FakeRenderer(), null, "t.pdf");

    private static PageEdits Edits(DocumentTab tab) => new(tab, new FakeFonts(), new FakeCodec());

    private static IReadOnlyList<PageObject> Objects(DocumentTab tab) => new PageEditor(tab.Session, 0).Objects;

    private static ImageObject Picture(DocumentTab tab) => Objects(tab).OfType<ImageObject>().Single();

    private static DocumentTab WithPicture(string pageKeys = "")
    {
        var tab = Open(EditPdf.Make("", pageKeys));
        Edits(tab).AddImage(0, new PdfRect(100, 500, 200, 600), [1]);
        return tab;
    }

    [Fact]
    public void ACroppedPictureMovesWithItsCrop()
    {
        using var tab = WithPicture();
        var edits = Edits(tab);
        Assert.True(edits.Crop(0, Picture(tab).Id, new PdfRect(100, 500, 150, 550)).Done);
        var cropped = Picture(tab).Bounds;
        Assert.Equal(50, cropped.Width, 1);

        Assert.True(edits.Move(0, [Picture(tab).Id], 200, 0).Done);

        var moved = Picture(tab).Bounds;
        Assert.Equal(50, moved.Width, 1);
        Assert.Equal(cropped.Left + 200, moved.Left, 1);
    }

    [Fact]
    public void ACroppedPictureResizesAndTurnsWithItsCrop()
    {
        using var tab = WithPicture();
        var edits = Edits(tab);
        edits.Crop(0, Picture(tab).Id, new PdfRect(100, 500, 150, 550));
        var cropped = Picture(tab).Bounds;

        Assert.True(edits.Resize(0, [Picture(tab).Id], new PdfRect(cropped.Left, cropped.Bottom, cropped.Left + 100, cropped.Bottom + 100)).Done);
        Assert.Equal(100, Picture(tab).Bounds.Width, 1);

        Assert.True(edits.Rotate(0, [Picture(tab).Id], 90).Done);
        Assert.Equal(100, Picture(tab).Bounds.Height, 1);
    }

    // Where the picture's own right and up point on the page as shown.
    private static ((double X, double Y) Right, (double X, double Y) Up) Directions(DocumentTab tab)
    {
        var g = new PageGeometry(tab.Document.Pages[0]).Matrix;
        var m = Picture(tab).Placement;
        return ((g.A * m.A + g.C * m.B, g.B * m.A + g.D * m.B), (g.A * m.C + g.C * m.D, g.B * m.C + g.D * m.D));
    }

    [Theory]
    [InlineData("")]
    [InlineData("/Rotate 90")]
    [InlineData("/Rotate 180")]
    [InlineData("/Rotate 270")]
    public void FlippingAcrossMirrorsLeftToRightOnThePageAsShown(string pageKeys)
    {
        using var tab = WithPicture(pageKeys);
        var (right, up) = Directions(tab);

        Assert.True(Edits(tab).Flip(0, [Picture(tab).Id], true, 0).Done);

        var (rightAfter, upAfter) = Directions(tab);
        Assert.Equal(-right.X, rightAfter.X, 1);
        Assert.Equal(right.Y, rightAfter.Y, 1);
        Assert.Equal(up.X, upAfter.X, 1);
        Assert.Equal(up.Y, upAfter.Y, 1);
    }

    [Fact]
    public void FlippingDownMirrorsTopToBottomOnATurnedPage()
    {
        using var tab = WithPicture("/Rotate 90");
        var (right, up) = Directions(tab);

        Assert.True(Edits(tab).Flip(0, [Picture(tab).Id], false, 0).Done);

        var (rightAfter, upAfter) = Directions(tab);
        Assert.Equal(right.X, rightAfter.X, 1);
        Assert.Equal(-up.Y, upAfter.Y, 1);
    }

    [Fact]
    public void TheViewTurnedAQuarterSwapsTheFlipToo()
    {
        using var tab = WithPicture();
        var (right, up) = Directions(tab);

        Assert.True(Edits(tab).Flip(0, [Picture(tab).Id], true, 90).Done);

        var (rightAfter, upAfter) = Directions(tab);
        Assert.Equal(right.X, rightAfter.X, 1);
        Assert.Equal(-up.Y, upAfter.Y, 1);
    }

    [Fact]
    public void AFillOnAShapeWithoutOneIsRefusedInsteadOfChangingNothing()
    {
        using var tab = Open();
        new PageEditor(tab.Session, 0, new FakeFonts()).AddEllipse(new PdfRect(100, 400, 200, 500), new ShapeStyle(new RgbColor(255, 0, 0), null, 2));
        int id = Objects(tab).OfType<PathObject>().Single().Id;

        var fill = Edits(tab).PathStyle(0, [id], new RgbColor(0, 0, 255), null, null);
        var line = Edits(tab).PathStyle(0, [id], null, new RgbColor(0, 0, 255), null);

        Assert.False(fill.Done);
        Assert.NotNull(fill.Problem);
        Assert.True(line.Done);
        Assert.Equal(new RgbColor(0, 0, 255), ((PathObject)Objects(tab)[id]).StrokeColor);
    }

    [Fact]
    public void ALinkGivenDirectlyOnThePageIsChangedWhereItIs()
    {
        using var tab = Open(EditPdf.Make("", DirectLink));
        var edits = Edits(tab);
        var link = Assert.Single(edits.Links(0));
        Assert.Null(link.Reference);

        Assert.True(edits.SetLink(0, link.Rect, new UriAction("https://new.example"), link).Done);

        var changed = Assert.Single(edits.Links(0));
        Assert.Equal("https://new.example", changed.Uri);
        var annots = tab.Document.Array(tab.Document.Pages[0].Dictionary, "Annots")!;
        var annot = Assert.IsType<PdfDictionary>(Assert.Single(annots.Items));
        Assert.True(annot.ContainsKey("Border"));
        Assert.True(annot.ContainsKey("C"));
    }

    [Fact]
    public void ALinkGivenDirectlyOnThePageCanBeRemoved()
    {
        using var tab = Open(EditPdf.Make("", DirectLink));
        var edits = Edits(tab);

        Assert.True(edits.RemoveLink(0, Assert.Single(edits.Links(0))).Done);

        Assert.Empty(edits.Links(0));
    }

    [Fact]
    public void ChangingALinkKeepsItsAnnotation()
    {
        using var tab = Open();
        var edits = Edits(tab);
        var area = new PdfRect(50, 700, 200, 720);
        edits.SetLink(0, area, new UriAction("https://one.example"), null);
        var link = Assert.Single(edits.Links(0));

        edits.SetLink(0, area, new GoToAction(new PdfDestination(0)), link);

        var changed = Assert.Single(edits.Links(0));
        Assert.Equal(link.Reference, changed.Reference);
        Assert.Equal("Change link", tab.Session.UndoLabel);
    }

    [Fact]
    public void AReplaceAllMadeOnACopyIsOneStepOnTheDocument()
    {
        using var tab = Open(Pdfs.Text(2, "The tests say hello."));
        var edits = Edits(tab);
        var made = edits.ReplaceAll(tab.Session.Current.ToArray(), "hello", "goodbye", new TextSearchOptions(), default);
        Assert.False(tab.IsDirty);

        var outcome = edits.Adopt(made);

        Assert.True(outcome.Done);
        Assert.Equal("Replace text", tab.Session.UndoLabel);
        Assert.True(tab.Session.Undo());
        Assert.False(tab.Session.CanUndo);
    }

    [Fact]
    public void AReplaceAllIsRefusedWhenTheDocumentMovedOnWhileItRan()
    {
        using var tab = Open(Pdfs.Text(2, "The tests say hello."));
        var edits = Edits(tab);
        var made = edits.ReplaceAll(tab.Session.Current.ToArray(), "hello", "goodbye", new TextSearchOptions(), default);
        Pdfs.Retitle(tab.Session, "Changed meanwhile");
        tab.Commit("Title");

        var outcome = edits.Adopt(made);

        Assert.False(outcome.Done);
        Assert.NotNull(outcome.Problem);
        Assert.Equal("Title", tab.Session.UndoLabel);
    }

    [Fact]
    public void AReplaceAllIsRefusedWhenAnUndoWentBackWhileItRan()
    {
        using var tab = Open(Pdfs.Text(2, "The tests say hello."));
        Pdfs.Retitle(tab.Session, "First");
        tab.Commit("Title");
        var edits = Edits(tab);
        var made = edits.ReplaceAll(tab.Session.Current.ToArray(), "hello", "goodbye", new TextSearchOptions(), default);
        tab.Undo();

        var outcome = edits.Adopt(made);

        Assert.False(outcome.Done);
        Assert.False(tab.Session.CanUndo);
    }

    [Fact]
    public void ACancelledReplaceAllNeverTouchesTheDocument()
    {
        using var tab = Open(Pdfs.Text(3, "The tests say hello."));
        using var cancelled = new CancellationTokenSource();
        cancelled.Cancel();
        var bytes = tab.Session.Current.ToArray();

        Assert.ThrowsAny<OperationCanceledException>(() => Edits(tab).ReplaceAll(bytes, "hello", "goodbye", new TextSearchOptions(), cancelled.Token));

        Assert.False(tab.IsDirty);
        Assert.True(tab.Session.Current.Span.SequenceEqual(bytes));
    }

    [Fact]
    public void AFileThatForbidsChangesIsRefusedUntilItIsOpenedAsOwner()
    {
        var locked = PdfDocument.Open(Pdfs.Restricted(PdfPermissions.Print));
        var owner = PdfDocument.Open(Pdfs.Restricted(PdfPermissions.Print), "owner");

        Assert.NotNull(Clearance.Refusal(locked));
        Assert.Null(Clearance.Refusal(owner));
        Assert.Null(Clearance.Refusal(PdfDocument.Open(Pdfs.Text())));
    }

    [Fact]
    public void AFileThatAllowsModifyingIsNotRefused()
    {
        Assert.Null(Clearance.Refusal(PdfDocument.Open(Pdfs.Restricted(PdfPermissions.Print | PdfPermissions.Modify))));
    }
}
