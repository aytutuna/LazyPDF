using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using LazyPDF.App.Documents;
using LazyPDF.App.Panels.Search;
using LazyPDF.App.Viewer;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

[Collection("Application")]
public sealed class SearchPanelTests
{
    private static (SearchSidePanel Panel, ViewerSearch Search, DocumentTab Tab) Open(byte[] bytes)
    {
        var ui = Dispatcher.CurrentDispatcher;
        var search = new ViewerSearch(() => TextSource.OpenAsync(bytes, null), () => 0, action => ui.InvokeAsync(action));
        var tab = new DocumentTab(PdfEditSession.Open(bytes), new FakeRenderer(), null, "a.pdf", null);
        var panel = new SearchSidePanel();
        panel.Attach(tab, FakeViewer.Create(search), new RecordingHost());
        return (panel, search, tab);
    }

    [Fact]
    public Task ALateBatchDoesNotOverwriteWhatIsBeingTyped() => Sta.Run(async () =>
    {
        var (panel, search, tab) = Open(Pdfs.Text(2, "The quick brown fox jumps over the lazy dog."));
        using var _ = tab;
        var box = (TextBox)panel.FindName("Query");
        box.Text = "b";

        await search.Start("fo", new TextSearchOptions());
        await Sta.Until(() => !search.Running);

        Assert.Equal("b", box.Text);
    });

    [Fact]
    public Task AFileWithoutTextSaysToMakeItSearchable() => Sta.Run(async () =>
    {
        var (panel, search, tab) = Open(PdfFromText.Create("", new FakeFonts()).Bytes);
        using var _ = tab;

        await search.Start("fox", new TextSearchOptions());
        await Sta.Until(() => !search.Running);

        Assert.Equal(Loc.T("This file has no text to search. Try Make searchable."), ((System.Windows.Controls.TextBlock)panel.FindName("Summary")).Text);
    });
}
