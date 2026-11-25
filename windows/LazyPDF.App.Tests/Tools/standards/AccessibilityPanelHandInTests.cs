using System.Reflection;
using LazyPDF.App.Documents;
using LazyPDF.App.Tools.Accessibility;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// Figure descriptions typed for a signed file stay waiting when the window hands in, and the close question counts them.
[Collection("Application")]
public sealed class AccessibilityPanelHandInTests
{
    [Fact]
    public Task ASignedFileKeepsTheTypedDescriptionWaitingAndLetsTheWindowGo() => Sta.Run(() =>
    {
        var document = PdfDocument.Open(PdfFromPictures.Create([new byte[] { 1 }], new FakeCodec()).Bytes);
        AutoTagger.Tag(document);
        var perms = new PdfDictionary();
        perms["UR3"] = document.Add(new PdfDictionary());
        document.Catalog["Perms"] = perms;
        using var tab = new DocumentTab(PdfEditSession.Open(document.SaveRewrite(new PdfSaveOptions()), (string?)null), new FakeRenderer(), null, "a.pdf", null);
        var host = new RecordingHost();
        var panel = new AccessibilityPanel();
        panel.Attach(tab, FakeViewer.Create().Viewer, host);

        var state = typeof(AccessibilityPanel).GetField("_state", BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(panel)!;
        var figure = Assert.Single(FigureFinder.List(StructureTree.Read(tab.Document)!));
        state.GetType().GetProperty("Checked")!.SetValue(state, new List<FigureRow> { figure });
        ((Dictionary<int, string>)state.GetType().GetProperty("Drafts")!.GetValue(state)!)[figure.Key] = "A grey square.";
        typeof(AccessibilityPanel).GetMethod("SyncPending", BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(panel, null);

        Assert.True(panel.HandIn());

        Assert.Empty(host.Notices);
        Assert.False(tab.IsDirty);
        Assert.Equal(1, tab.PendingDescriptions);
        Assert.True(tab.HasUnappliedWork);
        return Task.CompletedTask;
    });
}
