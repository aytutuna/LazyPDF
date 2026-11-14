using System.Reflection;
using System.Windows.Controls;
using LazyPDF.App.Documents;
using LazyPDF.App.Tools.Ocr;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// A word typed in the panel's box and not yet applied goes into the file when the window hands in before save, undo or close.
[Collection("Application")]
public sealed class OcrPanelHandInTests
{
    private sealed class NoRecognizer : ITextRecognizer
    {
        public Task<IReadOnlyList<OcrWord>> RecognizeAsync(PdfRgbaImage image, string language, CancellationToken cancellation = default) =>
            Task.FromResult<IReadOnlyList<OcrWord>>([]);
    }

    private static (OcrPanel Panel, DocumentTab Tab, TextBox Box) Picked(byte[]? bytes = null) => Picked(bytes, new RecordingHost());

    private static (OcrPanel Panel, DocumentTab Tab, TextBox Box) Picked(byte[]? bytes, RecordingHost host)
    {
        var tab = new DocumentTab(PdfEditSession.Open(bytes ?? Pdfs.Text(1), (string?)null), new FakeRenderer(), null, "a.pdf", null);
        PdfOcrLayer.Add(tab.Document, [new OcrPageWords(0, [new OcrWord("alpha", new OcrBox(10, 10, 50, 20)), new OcrWord("beta", new OcrBox(70, 10, 50, 20))], 200, 300)], "en");
        tab.Session.Commit("Read");
        var panel = new OcrPanel(new NoRecognizer(), () => new OcrLanguageState([], []));
        panel.Attach(tab, FakeViewer.Create().Viewer, host);
        typeof(OcrPanel).GetMethod("Pick", BindingFlags.Instance | BindingFlags.NonPublic, [typeof(int), typeof(int), typeof(bool)])!
            .Invoke(panel, [0, 1, false]);
        return (panel, tab, (TextBox)panel.FindName("WordBox"));
    }

    private static string[] Words(DocumentTab tab) =>
        [.. PdfOcrLayer.Words(tab.Document, tab.Document.Pages[0]).Select(w => w.Text)];

    [Fact]
    public Task HandingInPutsTheTypedWordIntoTheFile() => Sta.Run(() =>
    {
        var (panel, tab, box) = Picked();
        using var guard = tab;
        box.Text = " gamma ";

        Assert.True(panel.HandIn());

        Assert.Equal(["alpha", "gamma"], Words(tab));
        Assert.Equal(Loc.T("Correct word"), tab.Session.UndoLabel);
        Assert.False(tab.Document.HasChanges);
        return Task.CompletedTask;
    });

    [Fact]
    public Task HandingInWithTheWordUnchangedLeavesTheFileAlone() => Sta.Run(() =>
    {
        var (panel, tab, _) = Picked();
        using var guard = tab;

        Assert.True(panel.HandIn());

        Assert.False(tab.Document.HasChanges);
        Assert.Equal("Read", tab.Session.UndoLabel);
        return Task.CompletedTask;
    });

    [Fact]
    public Task ASignedFileKeepsTheTypedWordWaitingAndLetsTheWindowGo() => Sta.Run(() =>
    {
        var (panel, tab, box) = Picked(StampsPanelTests.Signed(certified: false, pages: 1));
        using var guard = tab;
        box.Text = "gamma";

        Assert.True(panel.HandIn());

        Assert.Equal(["alpha", "beta"], Words(tab));
        Assert.Equal("Read", tab.Session.UndoLabel);
        Assert.Equal(1, tab.PendingWords);
        Assert.True(tab.HasUnappliedWork);
        return Task.CompletedTask;
    });

    [Fact]
    public Task AWordKeptWaitingForASignedFileComesBackWhenTheTabIsShownAgain() => Sta.Run(() =>
    {
        var (panel, tab, box) = Picked(StampsPanelTests.Signed(certified: false, pages: 1));
        using var guard = tab;
        box.Text = "gamma";

        Assert.True(panel.HandInOnSwitch());
        panel.Detach();

        Assert.Equal(1, tab.PendingWords);
        panel.Attach(tab, FakeViewer.Create().Viewer, new RecordingHost());
        Assert.Equal("gamma", ((TextBox)panel.FindName("WordBox")).Text);
        Assert.Equal(1, tab.PendingWords);
        Assert.Equal(["alpha", "beta"], Words(tab));
        return Task.CompletedTask;
    });

    [Fact]
    public Task AWordKeptForASignedFileIsStillWaitingWhenItsPageIsNotInView() => Sta.Run(() =>
    {
        var (panel, tab, box) = Picked(StampsPanelTests.Signed(certified: false, pages: 1));
        using var guard = tab;
        box.Text = "gamma";
        panel.HandIn();
        panel.Detach();
        panel.Attach(tab, FakeViewer.Create().Viewer, new RecordingHost());
        ((CheckBox)panel.FindName("WordsToggle")).IsChecked = false;

        Assert.True(panel.HandIn());

        Assert.Equal(1, tab.PendingWords);
        Assert.Equal("gamma", ((TextBox)panel.FindName("WordBox")).Text);
        return Task.CompletedTask;
    });

    [Fact]
    public Task AWaitingWordIsFoundAgainAfterTheFileChangesAndDroppedWhenItIsGone() => Sta.Run(() =>
    {
        var host = new RecordingHost();
        var (panel, tab, box) = Picked(StampsPanelTests.Signed(certified: false, pages: 1), host);
        using var guard = tab;
        box.Text = "gamma";
        panel.HandIn();

        tab.Document.Catalog["Extra"] = new PdfDictionary();
        tab.Commit("Edit");

        Assert.Equal(1, tab.PendingWords);
        Assert.Equal("gamma", box.Text);

        Assert.True(tab.Undo());
        Assert.True(tab.Undo());

        Assert.Equal(0, tab.PendingWords);
        Assert.False(tab.HasUnappliedWork);
        Assert.Contains("no longer in the file", host.Status);
        return Task.CompletedTask;
    });

    [Fact]
    public Task AWaitingWordSurvivesTheTurningOfItsPage() => Sta.Run(() =>
    {
        var host = new RecordingHost();
        var (panel, tab, box) = Picked(StampsPanelTests.Signed(certified: false, pages: 1), host);
        using var guard = tab;
        box.Text = "gamma";
        panel.HandIn();

        tab.Document.Pages[0].Dictionary["Rotate"] = new PdfNumber(90);
        tab.Commit("Rotate");

        Assert.Equal(1, tab.PendingWords);
        Assert.Equal("gamma", box.Text);
        Assert.DoesNotContain("no longer in the file", host.Status);
        return Task.CompletedTask;
    });
}
