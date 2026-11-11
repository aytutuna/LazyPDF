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
    private static string EnterOnEntry(PdfDestination destination) => EnterOnEntry(new OutlineItem { Title = "Entry", Destination = destination });

    private static string EnterOnEntry(OutlineItem item)
    {
        using var tab = new DocumentTab(PdfEditSession.Open(Pdfs.Text(2)), new FakeRenderer(), null, "a.pdf", null);
        var outline = Outline.Read(tab.Document);
        outline.Add(item);
        outline.Write(tab.Document);
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
        Assert.Equal("This bookmark points to a page that is not in the file.", EnterOnEntry(new PdfDestination(-1, Name: "nowhere")));
        return Task.CompletedTask;
    });

    [Fact]
    public Task AGoodEntryIsSilent() => Sta.Run(() =>
    {
        Assert.Equal("", EnterOnEntry(new PdfDestination(1)));
        return Task.CompletedTask;
    });

    [Fact]
    public Task AnotherFileIsSaid() => Sta.Run(() =>
    {
        const string said = "This bookmark goes to another file, which Lazy PDF does not open from here.";
        Assert.Equal(said, EnterOnEntry(new OutlineItem { Title = "Entry", Action = new GoToRemoteAction("b.pdf", null, null) }));
        Assert.Equal(said, EnterOnEntry(new OutlineItem { Title = "Entry", Action = new LaunchAction("b.exe", null) }));
        return Task.CompletedTask;
    });

    [Fact]
    public Task AScriptOrFormIsSaid() => Sta.Run(() =>
    {
        const string said = "This bookmark runs a script or sends a form, which Lazy PDF does not do.";
        Assert.Equal(said, EnterOnEntry(new OutlineItem { Title = "Entry", Action = new JavaScriptAction("app.alert(1)") }));
        Assert.Equal(said, EnterOnEntry(new OutlineItem { Title = "Entry", Action = new SubmitFormAction("http://x", 0, []) }));
        Assert.Equal(said, EnterOnEntry(new OutlineItem { Title = "Entry", Action = new ResetFormAction(0, []) }));
        return Task.CompletedTask;
    });

    [Fact]
    public Task ExpandAllAndCollapseAllOnlyChangeTheView() => Sta.Run(() =>
    {
        using var tab = new DocumentTab(PdfEditSession.Open(Pdfs.Text(2)), new FakeRenderer(), null, "a.pdf", null);
        var outline = Outline.Read(tab.Document);
        var parent = outline.Add(new OutlineItem { Title = "Parent", Destination = new PdfDestination(1) });
        outline.Add(new OutlineItem { Title = "Child", Destination = new PdfDestination(1) }, parent);
        outline.Write(tab.Document);
        tab.Commit("Bookmark");
        bool dirty = tab.IsDirty;
        var before = tab.Session.Current.ToArray();
        var panel = new BookmarksSidePanel();
        panel.Attach(tab, FakeViewer.Create().Viewer, new RecordingHost());
        var tree = (TreeView)panel.FindName("Tree");
        Assert.False(((BookmarkNode)tree.Items[0]!).IsExpanded);

        ((Button)panel.FindName("ExpandAllButton")).RaiseEvent(new System.Windows.RoutedEventArgs(Button.ClickEvent));
        Assert.True(((BookmarkNode)tree.Items[0]!).IsExpanded);
        ((Button)panel.FindName("CollapseAllButton")).RaiseEvent(new System.Windows.RoutedEventArgs(Button.ClickEvent));
        Assert.False(((BookmarkNode)tree.Items[0]!).IsExpanded);

        Assert.Equal(before, tab.Session.Current.ToArray());
        Assert.Equal(dirty, tab.IsDirty);
        return Task.CompletedTask;
    });
}
