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

    private static (OcrPanel Panel, DocumentTab Tab, TextBox Box) Picked()
    {
        var tab = new DocumentTab(PdfEditSession.Open(Pdfs.Text(1), (string?)null), new FakeRenderer(), null, "a.pdf", null);
        PdfOcrLayer.Add(tab.Document, [new OcrPageWords(0, [new OcrWord("alpha", new OcrBox(10, 10, 50, 20)), new OcrWord("beta", new OcrBox(70, 10, 50, 20))], 200, 300)], "en");
        tab.Session.Commit("Read");
        var panel = new OcrPanel(new NoRecognizer(), () => new OcrLanguageState([], []));
        panel.Attach(tab, FakeViewer.Create().Viewer, new RecordingHost());
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
        Assert.True(tab.IsDirty);
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
}
