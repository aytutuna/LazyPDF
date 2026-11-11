using System.Windows.Controls;
using System.Windows.Input;
using LazyPDF.App.Documents;
using LazyPDF.App.Panels.Bookmarks;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

[Collection("Application")]
public sealed class BookmarksPanelTests
{
    private static string EnterOnEntry(PdfDestination destination)
    {
        using var tab = new DocumentTab(PdfEditSession.Open(Pdfs.Text(2)), new FakeRenderer(), null, "a.pdf", null);
        Outline.Read(tab.Document).Add(new OutlineItem { Title = "Entry", Destination = destination });
        tab.Commit("Bookmark");
        var host = new RecordingHost();
        var panel = new BookmarksSidePanel();
        panel.Attach(tab, FakeViewer.Create().Viewer, host);
        var window = new System.Windows.Window { Content = panel, Width = 300, Height = 300 };
        window.Show();
        var tree = (TreeView)panel.FindName("Tree");
        tree.UpdateLayout();
        ((TreeViewItem)tree.ItemContainerGenerator.ContainerFromIndex(0)).IsSelected = true;

        tree.RaiseEvent(new KeyEventArgs(Keyboard.PrimaryDevice, System.Windows.PresentationSource.FromVisual(panel)!, 0, Key.Enter) { RoutedEvent = Keyboard.PreviewKeyDownEvent });

        window.Close();
        return host.Status;
    }

    [Fact]
    public Task AMissingPageIsSaid() => Sta.Run(() =>
    {
        Assert.Equal("This bookmark points to a page that is not in the file.", EnterOnEntry(new PdfDestination(7)));
        return Task.CompletedTask;
    });

    [Fact]
    public Task AGoodEntryIsSilent() => Sta.Run(() =>
    {
        Assert.Equal("", EnterOnEntry(new PdfDestination(1)));
        return Task.CompletedTask;
    });
}
