using System.Reflection;
using LazyPDF.App.Documents;
using LazyPDF.App.Tools.Measure;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// Measurements waiting in the panel against the file changing under them.
[Collection("Application")]
public sealed class MeasurePendingTests
{
    private static Pending On(PdfDocument document, int page) =>
        new(new MeasureItem(MeasureKind.Distance, page, [new(0, 0), new(10, 0)]), PageKey.Of(document.Pages[page]));

    [Fact]
    public void ATurnedPageDropsItsMeasurementsAndTheOthersStay()
    {
        var document = PdfDocument.Open(Pdfs.Text(3));
        var waiting = new[] { On(document, 0), On(document, 2) };

        document.Pages[2].Dictionary["Rotate"] = new PdfNumber(90L);

        var kept = Pending.Keep(waiting, document);
        Assert.Equal([0], kept.Select(p => p.Item.Page));
    }

    [Fact]
    public void ADeletedPageMovesTheMeasurementsAfterItUp()
    {
        var document = PdfDocument.Open(Pdfs.Text(3));
        var waiting = new[] { On(document, 0), On(document, 1), On(document, 2) };

        PageOperations.Delete(document, [0]);

        var kept = Pending.Keep(waiting, document);
        Assert.Equal([0, 1], kept.Select(p => p.Item.Page));
    }

    [Fact]
    public void AFileOpenedAgainFromTheSameBytesKeepsEverything()
    {
        var bytes = Pdfs.Text(2);
        var waiting = new[] { On(PdfDocument.Open(bytes), 1) };

        Assert.Single(Pending.Keep(waiting, PdfDocument.Open(bytes)));
    }

    [Fact]
    public Task AFailedWriteChangesNothingAndKeepsTheList() => Sta.Run(() =>
    {
        using var tab = new DocumentTab(PdfEditSession.Open(Pdfs.Text(1)), new FakeRenderer(), null, "a.pdf", null);
        var host = new RecordingHost();
        var panel = new MeasurePanel();
        panel.Attach(tab, FakeViewer.Create().Viewer, host);
        var waiting = (List<Pending>)typeof(MeasurePanel).GetField("_waiting", BindingFlags.NonPublic | BindingFlags.Instance)!.GetValue(panel)!;
        waiting.Add(On(tab.Document, 0) with { Item = new MeasureItem(MeasureKind.Distance, 5, [new(0, 0), new(10, 0)]) });
        int revision = tab.Revision;

        typeof(MeasurePanel).GetMethod("Add", BindingFlags.NonPublic | BindingFlags.Instance)!.Invoke(panel, [tab]);

        Assert.Equal(revision, tab.Revision);
        Assert.Single(host.Problems);
        Assert.Single(waiting);
        return Task.CompletedTask;
    });
}
