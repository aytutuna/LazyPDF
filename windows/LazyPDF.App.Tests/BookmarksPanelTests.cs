using System.Windows;
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
        var window = new Window { Content = panel, Width = 300, Height = 300 };
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

        ((Button)panel.FindName("ExpandAllButton")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        Assert.True(((BookmarkNode)tree.Items[0]!).IsExpanded);
        ((Button)panel.FindName("CollapseAllButton")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        Assert.False(((BookmarkNode)tree.Items[0]!).IsExpanded);

        Assert.Equal(before, tab.Session.Current.ToArray());
        Assert.Equal(dirty, tab.IsDirty);
        return Task.CompletedTask;
    });

    private static (DocumentTab Tab, BookmarksSidePanel Panel, TreeView Tree, Window Window) Edited(params string[] titles) => Edited(Pdfs.Text(2), null, titles);

    private static (DocumentTab Tab, BookmarksSidePanel Panel, TreeView Tree, Window Window) Edited(byte[] pdf, RecordingHost? host, params string[] titles)
    {
        var tab = new DocumentTab(PdfEditSession.Open(pdf), new FakeRenderer(), null, "a.pdf", null);
        var outline = Outline.Read(tab.Document);
        foreach (string title in titles) outline.Add(new OutlineItem { Title = title, Destination = new PdfDestination(1) });
        outline.Write(tab.Document);
        tab.Commit("Bookmark");
        var panel = new BookmarksSidePanel();
        var window = new Window { Content = panel, Width = 300, Height = 300 };
        panel.Attach(tab, FakeViewer.Create().Viewer, host ?? new RecordingHost());
        window.Show();
        var tree = (TreeView)panel.FindName("Tree");
        tree.UpdateLayout();
        return (tab, panel, tree, window);
    }

    private static void Click(BookmarksSidePanel panel, string name)
    {
        var target = (UIElement)panel.FindName(name);
        target.RaiseEvent(new RoutedEventArgs(target is MenuItem ? MenuItem.ClickEvent : Button.ClickEvent));
    }

    private static IEnumerable<TextBox> Boxes(DependencyObject at)
    {
        for (int i = 0; i < System.Windows.Media.VisualTreeHelper.GetChildrenCount(at); i++)
        {
            var child = System.Windows.Media.VisualTreeHelper.GetChild(at, i);
            if (child is TextBox box) yield return box;
            foreach (var inner in Boxes(child)) yield return inner;
        }
    }

    private static string[] Titles(DocumentTab tab) => [.. Outline.Read(tab.Document).Items.Select(i => i.Title)];

    [Fact]
    public Task AddingWithNothingSelectedAppendsAndIsUndone() => Sta.Run(() =>
    {
        var (tab, panel, tree, window) = Edited("One", "Two");
        using var _ = tab;

        Click(panel, "AddButton");

        Assert.Equal(["One", "Two", "Page "], Titles(tab));
        Assert.Equal(DestinationFit.Xyz, Outline.Read(tab.Document).Items[2].Destination!.Fit);
        var added = (BookmarkNode)tree.Items[2]!;
        Assert.True(added.IsSelected);
        Assert.True(added.IsEditing);
        tab.Undo();
        Assert.Equal(["One", "Two"], Titles(tab));
        window.Close();
        return Task.CompletedTask;
    });

    [Fact]
    public Task AddingWithASelectionInsertsAfterIt() => Sta.Run(() =>
    {
        var (tab, panel, tree, window) = Edited("One", "Two");
        using var _ = tab;
        ((BookmarkNode)tree.Items[0]!).IsSelected = true;

        Click(panel, "AddButton");

        Assert.Equal(["One", "Page ", "Two"], Titles(tab));
        window.Close();
        return Task.CompletedTask;
    });

    [Fact]
    public Task AddingWorksWithNoBookmarks() => Sta.Run(() =>
    {
        var (tab, panel, tree, window) = Edited();
        using var _ = tab;

        Click(panel, "AddButton");

        Assert.Equal(["Page "], Titles(tab));
        Assert.Single(tree.Items);
        window.Close();
        return Task.CompletedTask;
    });

    [Fact]
    public Task RenamingIsOneUndoStep() => Sta.Run(() =>
    {
        var (tab, panel, tree, window) = Edited("One", "Two");
        using var _ = tab;
        var node = (BookmarkNode)tree.Items[1]!;
        node.IsSelected = true;

        Click(panel, "RenameButton");
        Assert.True(node.IsEditing);
        node.EditText = "Second";
        tree.UpdateLayout();
        var box = Boxes(tree).Single(b => b.IsVisible);
        box.RaiseEvent(new RoutedEventArgs(UIElement.LostFocusEvent));

        Assert.Equal(["One", "Second"], Titles(tab));
        tab.Undo();
        Assert.Equal(["One", "Two"], Titles(tab));
        window.Close();
        return Task.CompletedTask;
    });

    [Fact]
    public Task DeletingTakesTheEntryOutAndSelectsTheNext() => Sta.Run(() =>
    {
        var (tab, panel, tree, window) = Edited("One", "Two", "Three");
        using var _ = tab;
        ((BookmarkNode)tree.Items[1]!).IsSelected = true;
        Assert.True(((Button)panel.FindName("DeleteButton")).IsEnabled);

        Click(panel, "DeleteButton");

        Assert.Equal(["One", "Three"], Titles(tab));
        Assert.True(((BookmarkNode)tree.Items[1]!).IsSelected);
        tab.Undo();
        Assert.Equal(["One", "Two", "Three"], Titles(tab));
        window.Close();
        return Task.CompletedTask;
    });

    [Fact]
    public Task AnOpenEntryStaysOpenWhileAnotherIsAdded() => Sta.Run(() =>
    {
        var (tab, panel, tree, window) = Edited("Parent");
        using var _ = tab;
        var outline = Outline.Read(tab.Document);
        outline.Add(new OutlineItem { Title = "Child", Destination = new PdfDestination(1) }, outline.Items[0]);
        outline.Write(tab.Document);
        tab.Commit("Bookmark");
        ((BookmarkNode)tree.Items[0]!).IsExpanded = true;

        Click(panel, "AddButton");

        Assert.True(((BookmarkNode)tree.Items[0]!).IsExpanded);
        Assert.Equal(["Parent", "Page "], Titles(tab));
        window.Close();
        return Task.CompletedTask;
    });

    private static bool Enabled(BookmarksSidePanel panel, string name) => ((UIElement)panel.FindName(name)).IsEnabled;

    [Fact]
    public Task MovingUpSwapsWithThePreviousAndIsOneUndoStep() => Sta.Run(() =>
    {
        var (tab, panel, tree, window) = Edited("One", "Two", "Three");
        using var _ = tab;
        ((BookmarkNode)tree.Items[2]!).IsSelected = true;

        Click(panel, "MoveUpItem");

        Assert.Equal(["One", "Three", "Two"], Titles(tab));
        Assert.True(((BookmarkNode)tree.Items[1]!).IsSelected);
        tab.Undo();
        Assert.Equal(["One", "Two", "Three"], Titles(tab));
        window.Close();
        return Task.CompletedTask;
    });

    [Fact]
    public Task MovingDownSwapsWithTheNext() => Sta.Run(() =>
    {
        var (tab, panel, tree, window) = Edited("One", "Two", "Three");
        using var _ = tab;
        ((BookmarkNode)tree.Items[0]!).IsSelected = true;

        Click(panel, "MoveDownItem");

        Assert.Equal(["Two", "One", "Three"], Titles(tab));
        Assert.True(((BookmarkNode)tree.Items[1]!).IsSelected);
        window.Close();
        return Task.CompletedTask;
    });

    [Fact]
    public Task IndentingMakesAChildAndOutdentingReversesIt() => Sta.Run(() =>
    {
        var (tab, panel, tree, window) = Edited("One", "Two", "Three");
        using var _ = tab;
        ((BookmarkNode)tree.Items[1]!).IsSelected = true;

        Click(panel, "IndentItem");

        Assert.Equal(["One", "Three"], Titles(tab));
        var parent = Outline.Read(tab.Document).Items[0];
        Assert.Equal(["Two"], parent.Children.Select(c => c.Title));
        Assert.True(parent.IsOpen);
        tree.UpdateLayout();
        var moved = (BookmarkNode)((BookmarkNode)tree.Items[0]!).Children[0];
        Assert.True(moved.IsSelected);
        Assert.False(Enabled(panel, "IndentItem"));
        Assert.True(Enabled(panel, "OutdentItem"));

        Click(panel, "OutdentItem");

        Assert.Equal(["One", "Two", "Three"], Titles(tab));
        Assert.True(((BookmarkNode)tree.Items[1]!).IsSelected);
        tab.Undo();
        Assert.Equal(["One", "Three"], Titles(tab));
        tab.Undo();
        Assert.Equal(["One", "Two", "Three"], Titles(tab));
        window.Close();
        return Task.CompletedTask;
    });

    [Fact]
    public Task MovesAreOffWhereTheyCannotGo() => Sta.Run(() =>
    {
        var (tab, panel, tree, window) = Edited("One", "Two", "Three");
        using var _ = tab;
        Assert.False(Enabled(panel, "MoveUpItem"));

        ((BookmarkNode)tree.Items[0]!).IsSelected = true;
        Assert.False(Enabled(panel, "MoveUpItem"));
        Assert.False(Enabled(panel, "IndentItem"));
        Assert.False(Enabled(panel, "OutdentItem"));
        Assert.True(Enabled(panel, "MoveDownItem"));

        ((BookmarkNode)tree.Items[2]!).IsSelected = true;
        Assert.False(Enabled(panel, "MoveDownItem"));
        Assert.True(Enabled(panel, "MoveUpItem"));
        Assert.True(Enabled(panel, "IndentItem"));
        window.Close();
        return Task.CompletedTask;
    });

    [Fact]
    public Task GoingOnAnywayAddsABookmarkToASignedFile() => Sta.Run(() =>
    {
        var host = new RecordingHost();
        var (tab, panel, _, window) = Edited(StampsPanelTests.Signed(certified: false), host);
        using var _ = tab;

        Click(panel, "AddButton");
        Assert.Equal(["Check before going on"], host.Notices);
        Assert.Empty(Titles(tab));
        host.Actions.Single()!.Run();

        Assert.Equal(["Page "], Titles(tab));
        window.Close();
        return Task.CompletedTask;
    });

    [Fact]
    public Task GoingOnAnywayRenamesAndDeletesOnASignedFile() => Sta.Run(() =>
    {
        var host = new RecordingHost();
        var (tab, panel, tree, window) = Edited(StampsPanelTests.Signed(certified: true), host, "One", "Two");
        using var _ = tab;
        var node = (BookmarkNode)tree.Items[0]!;
        node.IsSelected = true;
        Click(panel, "RenameButton");
        node.EditText = "First";
        panel.HandIn();
        host.Actions.Single()!.Run();
        Assert.Equal(["First", "Two"], Titles(tab));

        tree.UpdateLayout();
        ((BookmarkNode)tree.Items[1]!).IsSelected = true;
        host.Actions.Clear();
        Click(panel, "DeleteButton");
        host.Actions.Single()!.Run();

        Assert.Equal(["First"], Titles(tab));
        window.Close();
        return Task.CompletedTask;
    });

    [Fact]
    public Task RightClickSelectsTheEntryUnderThePointer() => Sta.Run(() =>
    {
        var (tab, panel, tree, window) = Edited("One", "Two");
        using var _ = tab;
        ((BookmarkNode)tree.Items[0]!).IsSelected = true;
        var second = (TreeViewItem)tree.ItemContainerGenerator.ContainerFromIndex(1);

        tree.RaiseEvent(new MouseButtonEventArgs(Mouse.PrimaryDevice, 0, MouseButton.Right) { RoutedEvent = UIElement.PreviewMouseRightButtonDownEvent, Source = second });
        Assert.Same(tree.Items[1], tree.SelectedItem);
        Click(panel, "DeleteButton");

        Assert.Equal(["One"], Titles(tab));
        window.Close();
        return Task.CompletedTask;
    });

    [Fact]
    public Task AddingBringsTheNewEntryIntoView() => Sta.Run(() =>
    {
        var (tab, panel, tree, window) = Edited([.. Enumerable.Range(0, 200).Select(i => "Entry " + i)]);
        using var _ = tab;

        Click(panel, "AddButton");
        tree.UpdateLayout();

        var added = Assert.IsType<BookmarkNode>(tree.SelectedItem);
        Assert.Equal("Page ", added.Title);
        Assert.Contains(Boxes(tree), b => b.IsVisible && b.DataContext == added);
        window.Close();
        return Task.CompletedTask;
    });

    [Fact]
    public Task AnUnfinishedRenameIsHandedIn() => Sta.Run(() =>
    {
        var (tab, panel, tree, window) = Edited("One", "Two");
        using var _ = tab;
        var node = (BookmarkNode)tree.Items[1]!;
        node.IsSelected = true;
        Click(panel, "RenameButton");
        node.EditText = "Second";

        Assert.True(panel.HandIn());

        Assert.Equal(["One", "Second"], Titles(tab));
        Assert.False(node.IsEditing);
        window.Close();
        return Task.CompletedTask;
    });
}
