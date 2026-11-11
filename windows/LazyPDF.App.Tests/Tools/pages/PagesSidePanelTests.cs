using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using LazyPDF.App.Documents;
using LazyPDF.App.Panels.Pages;
using LazyPDF.App.Tools.Pages;
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

    // Four pages of 100, 200, 300 and 400 points wide.
    private static DocumentTab Sized()
    {
        var text = new System.Text.StringBuilder("%PDF-1.7\n1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n2 0 obj\n<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R 6 0 R] /Count 4 >>\nendobj\n");
        for (int i = 0; i < 4; i++) text.Append($"{i + 3} 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {(i + 1) * 100} 100] >>\nendobj\n");
        text.Append("trailer\n<< /Root 1 0 R /Size 7 >>\n%%EOF\n");
        return new(PdfEditSession.Open(System.Text.Encoding.ASCII.GetBytes(text.ToString())), new FakeRenderer(), null, "a.pdf");
    }

    private static double[] Widths(DocumentTab tab) => [.. tab.Document.Pages.Select(p => p.MediaBox.Width)];

    [Fact]
    public Task DroppingPagesElsewhereMovesThemInOneStep() => Sta.Run(() =>
    {
        using var tab = Sized();
        var panel = Show(tab, new RecordingHost());

        panel.MovePages([0], 3);

        Assert.Equal([200, 300, 100, 400], Widths(tab));
        var picked = Thumbs(panel).SelectedItems.Cast<PageThumb>().Select(t => t.Index);
        Assert.Equal([2], picked);
        tab.Undo();
        Assert.Equal([100, 200, 300, 400], Widths(tab));
        panel.Detach();
        return Task.CompletedTask;
    });

    [Fact]
    public Task DroppingPagesWhereTheyAreMakesNoStep() => Sta.Run(() =>
    {
        using var tab = Sized();
        var panel = Show(tab, new RecordingHost());

        panel.MovePages([1, 2], 1);
        panel.MovePages([1, 2], 3);
        panel.MovePages([0], 1);

        Assert.Equal([100, 200, 300, 400], Widths(tab));
        Assert.False(tab.IsDirty);
        panel.Detach();
        return Task.CompletedTask;
    });

    [Fact]
    public Task ABlankPageGoesAfterTheSelectionAndIsPicked() => Sta.Run(() =>
    {
        using var tab = Open(3);
        var panel = Show(tab, new RecordingHost());
        Select(panel, 0);

        panel.InsertBlank();

        Assert.Equal(4, tab.PageCount);
        var picked = Thumbs(panel).SelectedItems.Cast<PageThumb>().Select(t => t.Index);
        Assert.Equal([1], picked);
        tab.Undo();
        Assert.Equal(3, tab.PageCount);
        panel.Detach();
        return Task.CompletedTask;
    });

    [Fact]
    public Task PagesFromAFileGoInAfterTheSelectionAsOneStep() => Sta.Run(async () =>
    {
        using var dir = new TempDir();
        string file = dir.File("extra.pdf", Pdfs.Text(2, "Extra"));
        using var tab = Open(3);
        var panel = Show(tab, new RecordingHost());
        Select(panel, 0);

        await panel.InsertFilesAsync([file]);

        Assert.Equal(5, tab.PageCount);
        var picked = Thumbs(panel).SelectedItems.Cast<PageThumb>().Select(t => t.Index);
        Assert.Equal([1, 2], picked);
        tab.Undo();
        Assert.Equal(3, tab.PageCount);
        panel.Detach();
    });

    [Fact]
    public Task InsertFilesAsyncReturnsThePagesAdded() => Sta.Run(async () =>
    {
        using var dir = new TempDir();
        string one = dir.File("one.pdf", Pdfs.Text(2, "One"));
        string two = dir.File("two.pdf", Pdfs.Text(1, "Two"));
        using var tab = Open(3);
        var host = new RecordingHost();

        Assert.Equal(3, await PageJobs.InsertFilesAsync(tab, host, [one, two], 3));
        Assert.Equal(6, tab.PageCount);
        Assert.Equal(0, await PageJobs.InsertFilesAsync(tab, host, ["notes.txt"], 0));
        Assert.Equal("Not a PDF", Assert.Single(host.Problems).Title);
    });
}
