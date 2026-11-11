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
}
