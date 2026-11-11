using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using LazyPDF.App.Documents;
using LazyPDF.App.Panels.Pages;
using LazyPDF.App.Viewer;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// The thumbnail list as the window drives it: pages picked in the list, then changed through the key and the menu handlers.
[Collection("Application")]
public sealed class PagesSidePanelTests
{
    public class PagedViewer : DispatchProxy
    {
        public DocumentTab? Tab { get; set; }

        protected override object? Invoke(MethodInfo? method, object?[]? args) => method!.Name switch
        {
            "get_PageCount" => Tab!.PageCount,
            "PageLabel" => ((int)args![0]! + 1).ToString(),
            "PageSize" => new Size(200, 300),
            _ when method.ReturnType == typeof(void) || !method.ReturnType.IsValueType => null,
            _ => Activator.CreateInstance(method.ReturnType),
        };
    }

    private static PagesSidePanel Show(DocumentTab tab, RecordingHost host)
    {
        var viewer = DispatchProxy.Create<IDocumentViewer, PagedViewer>();
        ((PagedViewer)(object)viewer).Tab = tab;
        var panel = new PagesSidePanel();
        panel.Attach(tab, viewer, host);
        return panel;
    }

    private static ListBox Thumbs(PagesSidePanel panel) => (ListBox)panel.FindName("Thumbs");

    private static void Select(PagesSidePanel panel, params int[] pages)
    {
        var list = Thumbs(panel);
        var items = (List<PageThumb>)list.ItemsSource;
        list.SelectedItems.Clear();
        foreach (int page in pages) list.SelectedItems.Add(items[page]);
    }

    private static DocumentTab Open(int pages) => new(PdfEditSession.Open(Pdfs.Text(pages)), new FakeRenderer(), null, "a.pdf");

    [Fact]
    public Task DeleteKeyRemovesTheSelectedPagesInOneStep() => Sta.Run(() =>
    {
        using var tab = Open(3);
        var panel = Show(tab, new RecordingHost());
        Select(panel, 0, 2);

        Assert.True(panel.Press(Key.Delete, ModifierKeys.None));

        Assert.Equal(1, tab.PageCount);
        Assert.Single(Thumbs(panel).Items);
        tab.Undo();
        Assert.Equal(3, tab.PageCount);
        panel.Detach();
        return Task.CompletedTask;
    });

    [Fact]
    public Task EveryPageCannotBeDeleted() => Sta.Run(() =>
    {
        using var tab = Open(3);
        var host = new RecordingHost();
        var panel = Show(tab, host);
        Select(panel, 0, 1, 2);

        panel.Press(Key.Delete, ModifierKeys.None);

        Assert.Equal(3, tab.PageCount);
        Assert.Equal("Cannot delete every page", Assert.Single(host.Problems).Title);
        panel.Detach();
        return Task.CompletedTask;
    });

    [Fact]
    public Task TurningKeepsTheSelection() => Sta.Run(() =>
    {
        using var tab = Open(3);
        var panel = Show(tab, new RecordingHost());
        Select(panel, 0, 2);

        panel.Turn(90);

        Assert.Equal(90, tab.Document.Pages[0].Rotate);
        Assert.Equal(0, tab.Document.Pages[1].Rotate);
        Assert.Equal(90, tab.Document.Pages[2].Rotate);
        var picked = Thumbs(panel).SelectedItems.Cast<PageThumb>().Select(t => t.Index).Order();
        Assert.Equal([0, 2], picked);
        panel.Detach();
        return Task.CompletedTask;
    });
}
