using LazyPDF.App.Documents;
using LazyPDF.App.Tests.Tools.Comment;
using LazyPDF.App.Tools.EditContent;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests.Tools.Edit;

// The edits of the Edit text and images panel, each a real call to Core's page editor on a document in a tab.
[Collection("Application")]
public sealed class PageEditsTests
{
    private static DocumentTab Open(byte[]? bytes = null, string? password = null) =>
        new(PdfEditSession.Open(bytes ?? Pdfs.Text(), password), new FakeRenderer(), null, "t.pdf", password);

    private static PageEdits Edits(DocumentTab tab) => new(tab, new FakeFonts(), new FakeCodec());

    private static string PageText(DocumentTab tab, int page = 0) => new PageEditor(tab.Session, page).Text.Text;

    private static IReadOnlyList<PageObject> Objects(DocumentTab tab, int page = 0) => new PageEditor(tab.Session, page).Objects;

    // What the panel does: the copy is made off the document, then adopted by it.
    private static EditOutcome ReplaceAll(DocumentTab tab, string find, string replacement, CancellationToken cancel = default)
    {
        var edits = Edits(tab);
        return edits.Adopt(edits.ReplaceAll(tab.Session.Current.ToArray(), find, replacement, new TextSearchOptions(), cancel));
    }

    private static byte[] ThreeLines() => PdfFromText.Create("First line of the text.\nSecond line of the text.\nThird line of the text.", new FakeFonts()).Bytes;

    [Fact]
    public void TypingOverALineChangesThePageAndShowsIt()
    {
        using var tab = Open();
        var edits = Edits(tab);
        int raised = 0;
        tab.Changed += (_, _) => raised++;
        var line = ((TextObject)Objects(tab)[0]).Lines[0];

        var outcome = edits.ReplaceLine(0, line, "Goodbye from the tests.");

        Assert.True(outcome.Done);
        Assert.Contains("Goodbye from the tests.", PageText(tab));
        Assert.Equal(1, raised);
        Assert.Equal(1, tab.Revision);
        Assert.True(tab.IsDirty);
    }

    [Fact]
    public void UndoTakesTheTypedLineBack()
    {
        using var tab = Open();
        var line = ((TextObject)Objects(tab)[0]).Lines[0];
        Edits(tab).ReplaceLine(0, line, "Something else entirely.");

        tab.Undo();

        Assert.Contains("Hello from the tests.", PageText(tab));
    }

    [Fact]
    public void LettersNoFontHasAreRefusedWithCoresReasonAndNothingIsCommitted()
    {
        using var tab = Open();
        var line = ((TextObject)Objects(tab)[0]).Lines[0];

        var outcome = Edits(tab).ReplaceLine(0, line, "漢字");

        Assert.False(outcome.Done);
        Assert.False(string.IsNullOrEmpty(outcome.Problem));
        Assert.False(tab.Session.CanUndo);
        Assert.Equal(0, tab.Revision);
    }

    [Fact]
    public void AParagraphTakesMoreLinesAndSaysItGrew()
    {
        using var tab = Open(ThreeLines());
        var block = (TextObject)Objects(tab)[0];

        var outcome = Edits(tab).ReplaceParagraph(0, block.Id, "First line of the text. Second line of the text. Third line of the text. A fourth sentence that needs another line, and a fifth one that needs yet another line, then more.");

        Assert.True(outcome.Done);
        Assert.NotNull(outcome.Note);
        Assert.Contains("fifth", PageText(tab));
    }

    [Fact]
    public void AnObjectThatIsGoneIsReportedNotThrown()
    {
        using var tab = Open();

        var outcome = Edits(tab).Style(0, 999, new TextStyleChange(Size: 20));

        Assert.False(outcome.Done);
        Assert.Equal(EditingText.StaleObject, outcome.Problem);
    }

    [Fact]
    public void ASizeChangeIsReadBackFromThePage()
    {
        using var tab = Open();
        var block = (TextObject)Objects(tab)[0];

        var outcome = Edits(tab).Style(0, block.Id, new TextStyleChange(Size: 24));

        Assert.True(outcome.Done);
        Assert.Equal(24, ((TextObject)Objects(tab)[0]).Size, 1);
    }

    private static System.Windows.Input.KeyEventArgs Pressed(System.Windows.Input.Key key) =>
        new(System.Windows.Input.Keyboard.PrimaryDevice, new System.Windows.Interop.HwndSource(new System.Windows.Interop.HwndSourceParameters()), 0, key) { RoutedEvent = System.Windows.Input.Keyboard.PreviewKeyDownEvent };

    private static InPlaceEditor NewBox(out ViewerStandIn stand)
    {
        var viewer = ViewerStandIn.Create(out stand);
        var look = new EditorLook(new System.Windows.Media.FontFamily("Arial"), 12, System.Windows.Media.Colors.Black, false, false, TextAlignment.Left);
        var editor = new InPlaceEditor(viewer);
        editor.Open(0, new System.Windows.Rect(10, 10, 100, 20), "one", look, wrap: true, lineBreaks: true);
        return editor;
    }

    // The box makes \r\n for Shift+Enter by itself, and Enter keeps the text.
    [Fact]
    public Task ATextBoxKeepsALineBreakAsTwoLines() => Sta.Run(() =>
    {
        using var tab = Open();
        var editor = NewBox(out var stand);
        var box = Assert.IsType<System.Windows.Controls.TextBox>(Assert.Single(stand.Overlays[0].Children));
        bool kept = false;
        editor.Committed += (_, _) => kept = true;

        var shift = Pressed(System.Windows.Input.Key.Enter);
        editor.PressKey(shift, System.Windows.Input.ModifierKeys.Shift);
        Assert.False(shift.Handled);
        Assert.False(kept);
        box.Text = "one\r\ntwo";

        var plain = Pressed(System.Windows.Input.Key.Enter);
        editor.PressKey(plain, System.Windows.Input.ModifierKeys.None);
        Assert.True(plain.Handled);
        Assert.True(kept);

        var outcome = Edits(tab).AddTextBox(0, new PdfRect(100, 400, 400, 500), editor.Text, new TextBoxStyle("Arial", Size: 12));

        Assert.True(outcome.Done);
        Assert.Equal(["one", "two"], ((TextObject)Objects(tab)[^1]).Lines.Select(l => l.Text));
        return Task.CompletedTask;
    });

    [Fact]
    public Task CtrlShiftEnterInATextBoxAddsALineBreakWithoutKeepingIt() => Sta.Run(() =>
    {
        var editor = NewBox(out var stand);
        var box = Assert.IsType<System.Windows.Controls.TextBox>(Assert.Single(stand.Overlays[0].Children));
        box.CaretIndex = 3;
        bool kept = false;
        editor.Committed += (_, _) => kept = true;

        var ctrl = Pressed(System.Windows.Input.Key.Enter);
        editor.PressKey(ctrl, System.Windows.Input.ModifierKeys.Control | System.Windows.Input.ModifierKeys.Shift);
        box.Text += "two";

        Assert.True(ctrl.Handled);
        Assert.False(kept);
        Assert.Equal("one" + Environment.NewLine + "two", editor.Text);
        return Task.CompletedTask;
    });

    [Fact]
    public void ATextBoxIsAddedAndATooSmallOneSaysItOverflows()
    {
        using var tab = Open();
        var edits = Edits(tab);

        var fits = edits.AddTextBox(0, new PdfRect(100, 400, 400, 500), "A new box", new TextBoxStyle("Arial", Size: 12));
        var tight = edits.AddTextBox(0, new PdfRect(100, 300, 160, 312), "Far too many words for such a small box", new TextBoxStyle("Arial", Size: 12));

        Assert.True(fits.Done);
        Assert.Null(fits.Note);
        Assert.Contains("A new box", PageText(tab));
        Assert.True(tight.Done);
        Assert.NotNull(tight.Note);
    }

    [Fact]
    public void APictureIsAddedThroughTheCodecAndUnreadableBytesAreRefused()
    {
        using var tab = Open();
        var edits = Edits(tab);

        var bad = edits.AddImage(0, new PdfRect(50, 400, 250, 500), []);
        var good = edits.AddImage(0, new PdfRect(50, 400, 250, 500), [1, 2, 3]);

        Assert.False(bad.Done);
        Assert.Equal(EditingText.NoImage, bad.Problem);
        Assert.True(good.Done);
        Assert.Single(Objects(tab).OfType<ImageObject>());
    }

    [Fact]
    public void APictureKeepsItsProportionsInsideTheBox()
    {
        using var tab = Open();

        Edits(tab).AddImage(0, new PdfRect(50, 400, 350, 500), [1]);

        var image = Assert.Single(Objects(tab).OfType<ImageObject>());
        Assert.InRange(image.Bounds.Width, 99, 101);
        Assert.InRange(image.Bounds.Height, 99, 101);
        Assert.InRange(image.Bounds.Left, 149, 151);
    }

    [Fact]
    public void ObjectsAreMovedResizedTurnedAndDeletedAsOneStepEach()
    {
        using var tab = Open();
        var edits = Edits(tab);
        edits.AddImage(0, new PdfRect(100, 400, 200, 500), [1]);
        int id = Objects(tab).OfType<ImageObject>().Single().Id;
        var start = Objects(tab)[id].Bounds;

        Assert.True(edits.Move(0, [id], 30, -20).Done);
        var moved = Objects(tab)[id].Bounds;
        Assert.Equal(start.Left + 30, moved.Left, 1);
        Assert.Equal(start.Bottom - 20, moved.Bottom, 1);

        Assert.True(edits.Resize(0, [id], new PdfRect(moved.Left, moved.Bottom, moved.Left + 200, moved.Bottom + 50)).Done);
        Assert.Equal(200, Objects(tab)[id].Bounds.Width, 1);

        Assert.True(edits.Rotate(0, [id], 90).Done);
        Assert.Equal(50, Objects(tab)[id].Bounds.Width, 1);

        Assert.True(edits.Delete(0, [id]).Done);
        Assert.Empty(Objects(tab).OfType<ImageObject>());

        int steps = 0;
        while (tab.Undo()) steps++;
        Assert.Equal(5, steps);
    }

    [Fact]
    public void OpacityOrderAndShapeColoursReachThePage()
    {
        using var tab = Open();
        var edits = Edits(tab);
        var page = new PageEditor(tab.Session, 0, new FakeFonts());
        page.AddRectangle(new PdfRect(100, 400, 200, 500), new ShapeStyle(new RgbColor(0, 0, 255), new RgbColor(255, 0, 0), 2));
        int id = Objects(tab).OfType<PathObject>().Single().Id;

        Assert.True(edits.PathStyle(0, [id], new RgbColor(0, 255, 0), null, 5).Done);
        var path = (PathObject)Objects(tab)[id];
        Assert.Equal(new RgbColor(0, 255, 0), path.FillColor);
        Assert.Equal(5, path.LineWidth, 1);

        Assert.True(edits.Opacity(0, [id], 0.5).Done);
        Assert.Equal(0.5, ((PathObject)Objects(tab)[id]).Opacity, 2);
    }

    [Fact]
    public void ReplaceAllChangesEveryPageInOneStep()
    {
        using var tab = Open(Pdfs.Text(3, "The tests say hello."));
        var outcome = ReplaceAll(tab, "hello", "goodbye");

        Assert.True(outcome.Done);
        Assert.Equal("Replaced 3 times.", outcome.Note);
        for (int p = 0; p < 3; p++) Assert.Contains("goodbye", PageText(tab, p));
        Assert.True(tab.Session.Undo());
        Assert.False(tab.Session.CanUndo);
    }

    [Fact]
    public void ReplaceAllWithNothingFoundSaysSoAndLeavesTheFileClean()
    {
        using var tab = Open();

        var outcome = ReplaceAll(tab, "absent", "x");

        Assert.False(outcome.Done);
        Assert.Equal("Nothing found to replace.", outcome.Problem);
        Assert.False(tab.IsDirty);
    }

    [Fact]
    public void ACancelledReplaceAllLeavesNoHalfEditInTheDocument()
    {
        using var tab = Open(Pdfs.Text(3, "The tests say hello."));
        using var cancelled = new CancellationTokenSource();
        cancelled.Cancel();

        Assert.ThrowsAny<OperationCanceledException>(() => ReplaceAll(tab, "hello", "goodbye", cancelled.Token));

        Assert.False(tab.Document.HasChanges);
        Assert.False(tab.IsDirty);
    }

    [Fact]
    public void ReplaceAllReadsAFileThatNeedsAPassword()
    {
        var plain = PdfDocument.Open(Pdfs.Text(2, "The tests say hello."));
        var security = PdfSecurity.Create("pw", "owner", PdfPermissions.All, PdfCryptStrength.Aes256, plain.FirstId ?? []);
        using var tab = Open(plain.SaveRewrite(new PdfSaveOptions(Security: security)), "pw");

        var outcome = ReplaceAll(tab, "hello", "goodbye");

        Assert.True(outcome.Done);
        Assert.Contains("goodbye", PageText(tab, 1));
    }

    [Fact]
    public void ALinkIsAddedChangedAndRemoved()
    {
        using var tab = Open();
        var edits = Edits(tab);
        var area = new PdfRect(50, 700, 200, 720);

        Assert.True(edits.SetLink(0, area, new UriAction("https://example.com"), null).Done);
        var link = Assert.Single(edits.Links(0));
        Assert.Equal("https://example.com", link.Uri);

        Assert.True(edits.SetLink(0, area, new GoToAction(new PdfDestination(0)), link).Done);
        var changed = Assert.Single(edits.Links(0));
        Assert.Null(changed.Uri);
        Assert.Equal(0, changed.Destination!.PageIndex);

        Assert.True(edits.RemoveLink(0, changed).Done);
        Assert.Empty(edits.Links(0));
    }

    [Theory]
    [InlineData(false, "example.com", "https://example.com")]
    [InlineData(false, "mailto:me@example.com", "mailto:me@example.com")]
    [InlineData(false, " https://example.com/a ", "https://example.com/a")]
    [InlineData(false, "example.com:8080/a", "https://example.com:8080/a")]
    public void AWebAddressGetsItsSchemeWhenItHasNone(bool toPage, string typed, string expected)
    {
        var target = PageEdits.Target(toPage, typed, 3);

        Assert.Equal(expected, ((UriAction)target!).Uri);
    }

    [Theory]
    [InlineData(false, "")]
    [InlineData(false, "two words")]
    [InlineData(true, "0")]
    [InlineData(true, "4")]
    [InlineData(true, "x")]
    public void ATargetThatIsNeitherAnAddressNorAPageOfTheFileIsRefused(bool toPage, string typed) =>
        Assert.Null(PageEdits.Target(toPage, typed, 3));

    [Fact]
    public void APageNumberIsCountedFromOne()
    {
        var target = (GoToAction)PageEdits.Target(true, "3", 3)!;

        Assert.Equal(2, target.Destination.PageIndex);
    }
}
