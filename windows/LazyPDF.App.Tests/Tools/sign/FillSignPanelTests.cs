using System.Windows;
using System.Windows.Controls;
using LazyPDF.App.Documents;
using LazyPDF.App.Tools.FillSign;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

[Collection("Application")]
public sealed class FillSignPanelTests
{
    [Fact]
    public Task ARemovedSignatureIsKeptUntilTheNoticeIsAnswered() => Sta.Run(() =>
    {
        using var dir = new TempDir();
        var saved = new SavedSignatures(dir.Sub("sigs"));
        var item = saved.Add(SavedKind.Signature, new PdfRgbaImage(2, 1, [1, 0, 0, 255, 0, 1, 0, 128]));
        using var tab = new DocumentTab(PdfEditSession.Open(Pdfs.Text(1)), new FakeRenderer(), null, "a.pdf", null);
        var host = new RecordingHost();
        var panel = new FillSignPanel(dir.Sub("sigs"));
        var (viewer, _) = FakeViewer.Create();
        panel.Attach(tab, viewer, host);
        var list = (ListBox)panel.FindName("SavedList");
        var row = (SavedRow)list.Items[0]!;

        var remove = typeof(FillSignPanel).GetMethod("Remove_Click", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)!;
        remove.Invoke(panel, [new Button { DataContext = row }, new RoutedEventArgs()]);

        Assert.True(File.Exists(item.Path));
        Assert.Equal("Delete this signature?", host.Notices[0]);
        Assert.Equal("Delete", host.Actions[0]!.Text);

        host.Actions[0]!.Run();

        Assert.False(File.Exists(item.Path));
        return Task.CompletedTask;
    });
}
