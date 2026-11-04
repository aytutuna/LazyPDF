using System.Windows.Controls;
using LazyPDF.App.Documents;
using LazyPDF.App.Tools.Metadata;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// The properties form as the window drives it: what is typed survives other commits, and the file's own limits apply.
[Collection("Application")]
public sealed class MetadataPanelTests
{
    private static DocumentTab Open(byte[]? bytes = null, string? password = null) =>
        new(PdfEditSession.Open(bytes ?? Pdfs.Text(2), password), new FakeRenderer(), null, "a.pdf", password);

    private static MetadataPanel Attach(DocumentTab tab, RecordingHost host)
    {
        var panel = new MetadataPanel();
        panel.Attach(tab, FakeViewer.Create().Viewer, host);
        return panel;
    }

    private static T Find<T>(MetadataPanel panel, string name) where T : class => (T)panel.FindName(name);

    [Fact]
    public Task TypedPropertiesSurviveACommitFromElsewhere() => Sta.Run(() =>
    {
        using var tab = Open();
        var panel = Attach(tab, new RecordingHost());
        Find<TextBox>(panel, "TitleBox").Text = "Report";

        new PdfStamper(tab.Document).AddWatermark(new WatermarkSpec { Text = "DRAFT" });
        tab.Commit("Add watermark");

        Assert.Equal("Report", Find<TextBox>(panel, "TitleBox").Text);
        Assert.True(panel.Action!.CanRun());
        return Task.CompletedTask;
    });

    [Fact]
    public Task TypedPropertiesComeBackWhenThePanelIsShownAgain() => Sta.Run(() =>
    {
        using var tab = Open();
        var panel = Attach(tab, new RecordingHost());
        Find<TextBox>(panel, "TitleBox").Text = "Report";

        panel.Detach();
        panel.Attach(tab, FakeViewer.Create().Viewer, new RecordingHost());

        Assert.Equal("Report", Find<TextBox>(panel, "TitleBox").Text);
        return Task.CompletedTask;
    });

    [Fact]
    public Task SavingWritesTheFormAndTheFormThenMatchesTheFile() => Sta.Run(async () =>
    {
        using var tab = Open();
        var host = new RecordingHost();
        var panel = Attach(tab, host);
        Find<TextBox>(panel, "TitleBox").Text = "Report";

        await panel.Action!.Run();

        Assert.Equal("Report", DocumentMetadata.Read(tab.Document).Title);
        Assert.Equal("Properties changed.", host.Status);
        Assert.Equal("Report", Find<TextBox>(panel, "TitleBox").Text);
        Assert.False(panel.Action.CanRun());
    });

    [Fact]
    public Task AFileThatForbidsChangesKeepsItsProperties() => Sta.Run(async () =>
    {
        using var tab = Open(Pdfs.Restricted(PdfPermissions.All & ~PdfPermissions.Modify), "");
        var host = new RecordingHost();
        var panel = Attach(tab, host);
        Find<TextBox>(panel, "TitleBox").Text = "Report";

        await panel.Action!.Run();

        Assert.Equal("This file cannot be changed", Assert.Single(host.Problems).Title);
        Assert.False(tab.Session.CanUndo);
    });

    [Fact]
    public Task ACertifiedFileAsksBeforeItsPropertiesChange() => Sta.Run(async () =>
    {
        using var tab = Open(StampsPanelTests.Signed(certified: true));
        var host = new RecordingHost();
        var panel = Attach(tab, host);
        Find<TextBox>(panel, "TitleBox").Text = "Report";

        await panel.Action!.Run();
        Assert.Single(host.Notices);
        Assert.False(tab.Session.CanUndo);

        host.Actions[0]!.Run();
        await Sta.Until(() => tab.Session.CanUndo);
    });

    [Fact]
    public Task ACreatedDateOutsideTheSupportedRangeIsNotWritten() => Sta.Run(async () =>
    {
        using var tab = Open();
        var panel = Attach(tab, new RecordingHost());
        Find<TextBox>(panel, "TitleBox").Text = "Report";
        Find<DatePicker>(panel, "CreatedPicker").SelectedDate = new DateTime(1, 1, 1);

        await panel.Action!.Run();

        var read = DocumentMetadata.Read(tab.Document);
        Assert.Equal("Report", read.Title);
        Assert.Null(read.Created);
    });
}
