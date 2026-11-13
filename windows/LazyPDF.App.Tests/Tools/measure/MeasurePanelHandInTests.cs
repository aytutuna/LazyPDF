using System.Reflection;
using LazyPDF.App.Documents;
using LazyPDF.App.Tools.Measure;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// Measurements waiting in the list are put into the file when the window hands in before save, undo or close.
[Collection("Application")]
public sealed class MeasurePanelHandInTests
{
    private static DocumentTab Open() =>
        new(PdfEditSession.Open(Pdfs.Text(2), (string?)null), new FakeRenderer(), null, "a.pdf", null);

    private static MeasurePanel Attach(DocumentTab tab)
    {
        var panel = new MeasurePanel();
        panel.Attach(tab, FakeViewer.Create().Viewer, new RecordingHost());
        return panel;
    }

    private static void Wait(MeasurePanel panel, DocumentTab tab)
    {
        var waiting = (List<Pending>)typeof(MeasurePanel).GetField("_waiting", BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(panel)!;
        waiting.Add(new Pending(new MeasureItem(MeasureKind.Distance, 0, [new(10, 10), new(110, 10)]), PageKey.Of(tab.Document.Pages[0])));
    }

    [Fact]
    public Task HandingInWritesTheWaitingMeasurementsAsOneStep() => Sta.Run(() =>
    {
        using var tab = Open();
        var panel = Attach(tab);
        Wait(panel, tab);
        Assert.False(tab.IsDirty);

        Assert.True(panel.HandIn());

        Assert.True(tab.IsDirty);
        Assert.Single(tab.Document.Array(tab.Document.Pages[0].Dictionary, "Annots")!.Items);
        Assert.False(panel.Action!.CanRun());
        Assert.Equal(0, tab.PendingMeasurements);
        return Task.CompletedTask;
    });

    [Fact]
    public Task ASignedFileKeepsTheMeasurementsWaitingAndLetsTheWindowGo() => Sta.Run(() =>
    {
        using var tab = new DocumentTab(PdfEditSession.Open(StampsPanelTests.Signed(certified: false), (string?)null), new FakeRenderer(), null, "a.pdf", null);
        var host = new RecordingHost();
        var panel = new MeasurePanel();
        panel.Attach(tab, FakeViewer.Create().Viewer, host);
        Wait(panel, tab);

        Assert.True(panel.HandIn());

        Assert.Empty(host.Notices);
        Assert.False(tab.IsDirty);
        Assert.Null(tab.Document.Array(tab.Document.Pages[0].Dictionary, "Annots"));
        Assert.Equal(1, tab.PendingMeasurements);
        return Task.CompletedTask;
    });

    [Fact]
    public Task MovingOnLeavesTheWaitingMeasurementsInTheList() => Sta.Run(() =>
    {
        using var tab = Open();
        var panel = Attach(tab);
        Wait(panel, tab);

        Assert.True(panel.HandInOnSwitch());

        Assert.False(tab.IsDirty);
        Assert.Null(tab.Document.Array(tab.Document.Pages[0].Dictionary, "Annots"));
        Assert.True(panel.Action!.CanRun());
        return Task.CompletedTask;
    });

    [Fact]
    public Task HandingInWithNothingWaitingChangesNothing() => Sta.Run(() =>
    {
        using var tab = Open();
        var panel = Attach(tab);

        Assert.True(panel.HandIn());

        Assert.False(tab.IsDirty);
        return Task.CompletedTask;
    });
}
