using System.Text;
using System.Windows.Controls;
using LazyPDF.App.Documents;
using LazyPDF.App.Panels.Attachments;
using LazyPDF.App.Services;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

[Collection("Application")]
public sealed class AttachmentsPanelTests
{
    [Fact]
    public Task OpenAsksFirstAndWritesNoCopyUntilAnswered() => Sta.Run(() =>
    {
        using var tab = new DocumentTab(PdfEditSession.Open(Pdfs.Text(1)), new FakeRenderer(), null, "a.pdf", null);
        PdfAttachments.Add(tab.Document, "notes.txt", Encoding.UTF8.GetBytes("hello"));
        tab.Commit("Attach");
        var host = new RecordingHost();
        var panel = new AttachmentsSidePanel();
        panel.Attach(tab, FakeViewer.Create().Viewer, host);
        var files = (ListBox)panel.FindName("Files");
        files.SelectedIndex = 0;
        int copies = Directory.Exists(AppFolders.OpenedAttachments) ? Directory.GetDirectories(AppFolders.OpenedAttachments).Length : 0;

        ((Button)panel.FindName("OpenButton")).RaiseEvent(new System.Windows.RoutedEventArgs(Button.ClickEvent));

        Assert.Equal(["Open this attachment?"], host.Notices);
        Assert.Equal("Open", host.Actions.Single()!.Text);
        int after = Directory.Exists(AppFolders.OpenedAttachments) ? Directory.GetDirectories(AppFolders.OpenedAttachments).Length : 0;
        Assert.Equal(copies, after);
        return Task.CompletedTask;
    });

    [Fact]
    public Task AnswerAfterDetachingDoesNothing() => Sta.Run(() =>
    {
        using var tab = new DocumentTab(PdfEditSession.Open(Pdfs.Text(1)), new FakeRenderer(), null, "a.pdf", null);
        PdfAttachments.Add(tab.Document, "notes.txt", Encoding.UTF8.GetBytes("hello"));
        tab.Commit("Attach");
        var host = new RecordingHost();
        var panel = new AttachmentsSidePanel();
        panel.Attach(tab, FakeViewer.Create().Viewer, host);
        ((ListBox)panel.FindName("Files")).SelectedIndex = 0;
        ((Button)panel.FindName("OpenButton")).RaiseEvent(new System.Windows.RoutedEventArgs(Button.ClickEvent));
        panel.Detach();
        int copies = Directory.Exists(AppFolders.OpenedAttachments) ? Directory.GetDirectories(AppFolders.OpenedAttachments).Length : 0;

        host.Actions.Single()!.Run();

        int after = Directory.Exists(AppFolders.OpenedAttachments) ? Directory.GetDirectories(AppFolders.OpenedAttachments).Length : 0;
        Assert.Equal(copies, after);
        return Task.CompletedTask;
    });

    [Fact]
    public Task AnswerAfterTheDocumentChangedDoesNothing() => Sta.Run(() =>
    {
        using var tab = new DocumentTab(PdfEditSession.Open(Pdfs.Text(1)), new FakeRenderer(), null, "a.pdf", null);
        PdfAttachments.Add(tab.Document, "notes.txt", Encoding.UTF8.GetBytes("hello"));
        tab.Commit("Attach");
        var host = new RecordingHost();
        var panel = new AttachmentsSidePanel();
        panel.Attach(tab, FakeViewer.Create().Viewer, host);
        ((ListBox)panel.FindName("Files")).SelectedIndex = 0;
        ((Button)panel.FindName("OpenButton")).RaiseEvent(new System.Windows.RoutedEventArgs(Button.ClickEvent));
        PdfAttachments.Add(tab.Document, "other.txt", Encoding.UTF8.GetBytes("world"));
        tab.Commit("Attach");
        int copies = Directory.Exists(AppFolders.OpenedAttachments) ? Directory.GetDirectories(AppFolders.OpenedAttachments).Length : 0;

        host.Actions.Single()!.Run();

        int after = Directory.Exists(AppFolders.OpenedAttachments) ? Directory.GetDirectories(AppFolders.OpenedAttachments).Length : 0;
        Assert.Equal(copies, after);
        return Task.CompletedTask;
    });

    private static (DocumentTab Tab, AttachmentsSidePanel Panel, RecordingHost Host) Panel(byte[] pdf)
    {
        var tab = new DocumentTab(PdfEditSession.Open(pdf), new FakeRenderer(), null, "a.pdf", null);
        PdfAttachments.Add(tab.Document, "notes.txt", Encoding.UTF8.GetBytes("hello"));
        tab.Commit("Attach");
        var host = new RecordingHost();
        var panel = new AttachmentsSidePanel();
        panel.Attach(tab, FakeViewer.Create().Viewer, host);
        ((ListBox)panel.FindName("Files")).SelectedIndex = 0;
        return (tab, panel, host);
    }

    private static void Click(AttachmentsSidePanel panel, string name) =>
        ((Button)panel.FindName(name)).RaiseEvent(new System.Windows.RoutedEventArgs(Button.ClickEvent));

    [Fact]
    public Task DeleteRemovesTheSelectedFileInOneUndoStep() => Sta.Run(() =>
    {
        var (tab, panel, host) = Panel(Pdfs.Text(1));
        using var _ = tab;

        Click(panel, "DeleteButton");

        Assert.Empty(PdfAttachments.List(tab.Document));
        Assert.Equal("Attachment deleted.", host.Status);
        Assert.True(tab.Undo());
        Assert.Single(PdfAttachments.List(tab.Document));
        return Task.CompletedTask;
    });

    [Fact]
    public Task DeleteFollowsTheSelection() => Sta.Run(() =>
    {
        var (tab, panel, _) = Panel(Pdfs.Text(1));
        using var _ = tab;
        var delete = (Button)panel.FindName("DeleteButton");
        Assert.True(delete.IsEnabled);

        ((ListBox)panel.FindName("Files")).SelectedIndex = -1;

        Assert.False(delete.IsEnabled);
        return Task.CompletedTask;
    });

    [Fact]
    public Task ASignedFileAsksBeforeDeleting() => Sta.Run(() =>
    {
        var (tab, panel, host) = Panel(StampsPanelTests.Signed(certified: false));
        using var _ = tab;

        Click(panel, "DeleteButton");

        Assert.Equal(["Check before going on"], host.Notices);
        Assert.Single(PdfAttachments.List(tab.Document));
        return Task.CompletedTask;
    });

    [Fact]
    public Task GoingOnAnywayDeletesTheFileOnASignedFile() => Sta.Run(() =>
    {
        var (tab, panel, host) = Panel(StampsPanelTests.Signed(certified: false));
        using var _ = tab;
        Click(panel, "DeleteButton");

        host.Actions.Single()!.Run();

        Assert.Empty(PdfAttachments.List(tab.Document));
        Assert.Equal("Attachment deleted.", host.Status);
        return Task.CompletedTask;
    });

    [Fact]
    public Task GoingOnAnywayDeletesTheRowAskedFor() => Sta.Run(() =>
    {
        var (tab, panel, host) = Panel(StampsPanelTests.Signed(certified: false));
        using var _ = tab;
        PdfAttachments.Add(tab.Document, "other.txt", Encoding.UTF8.GetBytes("two"));
        tab.Commit("Attach");
        var files = (ListBox)panel.FindName("Files");
        files.SelectedIndex = 0;
        string asked = ((AttachmentRow)files.SelectedItem).Name;
        Click(panel, "DeleteButton");
        files.SelectedIndex = 1;

        host.Actions.Single()!.Run();

        var left = PdfAttachments.List(tab.Document);
        Assert.Single(left);
        Assert.NotEqual(asked, left[0].FileName);
        return Task.CompletedTask;
    });

    [Fact]
    public Task ARestrictedFileRefusesAndDisablesBothButtons() => Sta.Run(() =>
    {
        var (tab, panel, host) = Panel(Pdfs.Restricted(PdfPermissions.All & ~PdfPermissions.Modify));
        using var _ = tab;

        Assert.False(((Button)panel.FindName("AddButton")).IsEnabled);
        Assert.False(((Button)panel.FindName("DeleteButton")).IsEnabled);
        Click(panel, "DeleteButton");

        Assert.Single(PdfAttachments.List(tab.Document));
        return Task.CompletedTask;
    });

    [Fact]
    public void SaveAllKeepsTwoAttachmentsWithOneName()
    {
        var document = PdfEditSession.Open(Pdfs.Text(1)).Document;
        PdfAttachments.Add(document, "a.txt", Encoding.UTF8.GetBytes("one"));
        PdfAttachments.Add(document, "a.txt", Encoding.UTF8.GetBytes("two"));
        var rows = PdfAttachments.List(document).Select(a => new AttachmentRow(a, "")).ToList();
        string folder = Directory.CreateTempSubdirectory().FullName;
        try
        {
            var (saved, unreadable) = AttachmentsSidePanel.SaveAllTo(document, rows, folder, CancellationToken.None);

            Assert.Equal((2, 0), (saved, unreadable));
            Assert.Equal("one", File.ReadAllText(Path.Combine(folder, "a.txt")));
            Assert.Equal("two", File.ReadAllText(Path.Combine(folder, "a (2).txt")));
        }
        finally
        {
            Directory.Delete(folder, true);
        }
    }
}
