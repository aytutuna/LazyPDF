using System.Reflection;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using LazyPDF.App.Documents;
using LazyPDF.Core;
using LazyPDF.App.Panels.Pages;
using LazyPDF.App.Tools.Pages;
using LazyPDF.App.Viewer;
using Xunit;
using static LazyPDF.App.Tests.PagesKit;

namespace LazyPDF.App.Tests;

// The "Copy to tab" entries on the surfaces that can select pages.
[Collection("Application")]
public sealed class PageTransferMenuTests
{
    private static MenuItem Entry(object owner, string field) =>
        (MenuItem)owner.GetType().GetField(field, BindingFlags.Instance | BindingFlags.NonPublic | BindingFlags.Public)!.GetValue(owner)!;

    private static void Opening(object owner, string handler) =>
        owner.GetType().GetMethod(handler, BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(owner, [owner, null]);

    [Fact]
    public Task EveryOtherOpenFileGetsAnEntryThatCopiesTheSelection() => Sta.Run(async () =>
    {
        using var from = Open(4, "a.pdf");
        using var to = Open(2, "b_c.pdf");
        var host = new StageHost();
        host.Documents.AddRange([from, to]);
        var items = new MenuItem().Items;

        Assert.True(PageTransferMenu.Fill(items, host, from, () => [1, 2]));

        var entry = Assert.IsType<MenuItem>(Assert.Single(items));
        Assert.Equal("b__c.pdf", entry.Header);
        Assert.Equal("Copy 2 pages to b_c.pdf", AutomationProperties.GetName(entry));
        int revision = to.Revision;
        entry.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));
        await Sta.Until(() => to.Revision > revision);
        Assert.Equal(4, to.PageCount);
        Assert.Equal(TextOf(from, 1), TextOf(to, 2));
    });

    [Fact]
    public Task WithOneFileOpenThereIsNothingToCopyTo() => Sta.Run(() =>
    {
        using var tab = Open(2, "a.pdf");
        var host = new StageHost();
        host.Documents.Add(tab);

        Assert.False(PageTransferMenu.Fill(new MenuItem().Items, host, tab, () => [0]));
        return Task.CompletedTask;
    });

    [Fact]
    public Task TheOrganizeButtonAndMenuFollowTheOpenFilesAndTheSelection() => Sta.Run(() =>
    {
        using var from = Open(4, "a.pdf");
        using var to = Open(2, "b.pdf");
        var host = new StageHost();
        host.Documents.Add(from);
        using var shown = new Shown(from, host);
        shown.Select(0);

        Assert.False(shown.Button("CopyTo").IsEnabled);
        Opening(shown.View, "Thumbs_ContextMenuOpening");
        Assert.False(Entry(shown.View, "CopyToTab").IsEnabled);

        host.Documents.Add(to);
        shown.Select(0, 1);
        Assert.True(shown.Button("CopyTo").IsEnabled);
        Opening(shown.View, "Thumbs_ContextMenuOpening");
        var menu = Entry(shown.View, "CopyToTab");
        Assert.True(menu.IsEnabled);
        Assert.Equal("b.pdf", Assert.IsType<MenuItem>(Assert.Single(menu.Items)).Header);

        shown.Select();
        Assert.False(shown.Button("CopyTo").IsEnabled);
        return Task.CompletedTask;
    });

    [Fact]
    public Task TheSidePanelMenuListsTheOtherFiles() => Sta.Run(() =>
    {
        using var from = Open(3, "a.pdf");
        using var to = Open(2, "b.pdf");
        var host = new StageHost();
        host.Documents.AddRange([from, to]);
        var viewer = DispatchProxy.Create<IDocumentViewer, PagesSidePanelTests.PagedViewer>();
        ((PagesSidePanelTests.PagedViewer)(object)viewer).Tab = from;
        var panel = new PagesSidePanel();
        panel.Attach(from, viewer, host);
        var list = (ListBox)panel.FindName("Thumbs");
        list.SelectedItems.Add(((List<PageThumb>)list.ItemsSource)[0]);

        Opening(panel, "Thumbs_ContextMenuOpening");

        var menu = Entry(panel, "CopyToTab");
        Assert.True(menu.IsEnabled);
        Assert.Equal("b.pdf", Assert.IsType<MenuItem>(Assert.Single(menu.Items)).Header);
        panel.Detach();
        return Task.CompletedTask;
    });

    [Fact]
    public Task TheInspectorMenuIsOffWithNothingSelected() => Sta.Run(() =>
    {
        using var from = Open(3, "a.pdf");
        using var to = Open(2, "b.pdf");
        var host = new StageHost();
        host.Documents.AddRange([from, to]);
        var panel = new PagesPanel();
        panel.Attach(from, FakeViewer.Create().Viewer, host);
        var list = (ListBox)panel.FindName("Thumbs");

        Opening(panel, "Thumbs_ContextMenuOpening");
        Assert.False(Entry(panel, "CopyToTab").IsEnabled);

        list.SelectedItems.Add(((List<PageCell>)list.ItemsSource)[0]);
        Opening(panel, "Thumbs_ContextMenuOpening");
        Assert.True(Entry(panel, "CopyToTab").IsEnabled);
        panel.Detach();
        return Task.CompletedTask;
    });

    [Fact]
    public Task TheOrganizeButtonSaysSoWhenTheOtherFileWasClosed() => Sta.Run(() =>
    {
        using var from = Open(4, "a.pdf");
        using var to = Open(2, "b.pdf");
        var host = new StageHost();
        host.Documents.AddRange([from, to]);
        using var shown = new Shown(from, host);
        shown.Select(0);
        Assert.True(shown.Button("CopyTo").IsEnabled);

        host.Documents.Remove(to);
        shown.Button("CopyTo").RaiseEvent(new RoutedEventArgs(System.Windows.Controls.Primitives.ButtonBase.ClickEvent));

        Assert.False(shown.Button("CopyTo").IsEnabled);
        Assert.Equal("No other file is open.", host.Status);
        return Task.CompletedTask;
    });

    [Fact]
    public Task RightClickingTheOrganizeButtonOpensNothing() => Sta.Run(() =>
    {
        using var from = Open(4, "a.pdf");
        var host = new StageHost();
        host.Documents.Add(from);
        using var shown = new Shown(from, host);
        var args = (ContextMenuEventArgs)Activator.CreateInstance(typeof(ContextMenuEventArgs), BindingFlags.Instance | BindingFlags.NonPublic, null, [shown.Button("CopyTo"), false], null)!;

        shown.View.GetType().GetMethod("CopyTo_ContextMenuOpening", BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(shown.View, [shown.Button("CopyTo"), args]);

        Assert.True(args.Handled);
        return Task.CompletedTask;
    });

    [Fact]
    public Task FilesWithTheSameNameAreToldApartByTheirFolder() => Sta.Run(() =>
    {
        using var dir = new TempDir();
        using var from = Open(2, "a.pdf");
        using var one = new DocumentTab(PdfEditSession.Open(Pdfs.Text(1)), new FakeRenderer(), dir.File("x/scan.pdf", Pdfs.Text(1)), "scan.pdf");
        using var two = new DocumentTab(PdfEditSession.Open(Pdfs.Text(1)), new FakeRenderer(), dir.File("y/scan.pdf", Pdfs.Text(1)), "scan.pdf");
        var host = new StageHost();
        host.Documents.AddRange([from, one, two]);
        var items = new MenuItem().Items;

        PageTransferMenu.Fill(items, host, from, () => [0]);

        Assert.Equal(one.Path, AutomationProperties.GetHelpText((MenuItem)items[0]));
        Assert.Equal(two.Path, AutomationProperties.GetHelpText((MenuItem)items[1]));
        return Task.CompletedTask;
    });

    [Fact]
    public Task TheInspectorMenuHasNothingToDoWithNoPagesPicked() => Sta.Run(() =>
    {
        using var tab = Open(3, "a.pdf");
        var host = new StageHost();
        var panel = new PagesPanel();
        panel.Attach(tab, FakeViewer.Create().Viewer, host);
        var thumbs = (ListBox)panel.FindName("Thumbs");

        Opening(panel, "Thumbs_ContextMenuOpening");

        Assert.All(thumbs.ContextMenu.Items.OfType<MenuItem>(), item => Assert.False(item.IsEnabled));
        panel.Detach();
        return Task.CompletedTask;
    });
}
