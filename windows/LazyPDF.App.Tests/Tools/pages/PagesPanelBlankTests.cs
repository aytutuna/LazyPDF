using System.Reflection;
using System.Windows.Controls;
using LazyPDF.App.Documents;
using LazyPDF.App.Services;
using LazyPDF.App.Tools.Pages;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

[Collection("Application")]
public sealed class PagesPanelBlankTests
{
    private static byte[] File(params bool[] empty) =>
        PdfFromText.Create(string.Join("\f", empty.Select((e, i) => e ? "" : $"Hello from the tests. Page {i + 1}.")), new FakeFonts()).Bytes;

    private static async Task<(PagesPanel Panel, DocumentTab Tab, ListBox List)> Scan(byte[] bytes)
    {
        var tab = new DocumentTab(PdfEditSession.Open(bytes), new WindowsPageRenderer(), null, "a.pdf");
        var panel = new PagesPanel();
        panel.Attach(tab, FakeViewer.Create().Viewer, new RecordingHost());
        ((Expander)panel.FindName("BlankSection")).IsExpanded = true;
        await (Task)typeof(PagesPanel).GetMethod("FindBlanks", BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(panel, null)!;
        return (panel, tab, (ListBox)panel.FindName("BlankList"));
    }

    private static List<string> Names(ListBox list) => [.. list.Items.Cast<CheckBox>().Select(c => (string)c.Content)];

    private static void Delete(PagesPanel panel) => panel.Action!.Run().GetAwaiter().GetResult();

    [Fact]
    public Task TheEmptyPagesAreListedAndDeletingThemIsOneStep() => Sta.Run(async () =>
    {
        var (panel, tab, list) = await Scan(File(false, true, false, true, false));

        Assert.Equal(["Page 2", "Page 4"], Names(list));
        Delete(panel);
        Assert.Equal(3, tab.PageCount);
        Assert.Empty(list.Items);
        tab.Undo();
        Assert.Equal(5, tab.PageCount);
        panel.Detach();
        tab.Dispose();
    });

    [Fact]
    public Task WhenEveryPageIsBlankTheFirstIsKept() => Sta.Run(async () =>
    {
        var document = PdfDocument.Open(Pdfs.Text());
        for (int i = 0; i < 3; i++) PageOperations.InsertBlank(document, 1, 612, 792);
        PageOperations.Delete(document, [0]);
        var (panel, tab, list) = await Scan(document.SaveRewrite());

        Assert.Equal(3, list.Items.Count);
        Assert.False(((CheckBox)list.Items[0]!).IsChecked);
        Delete(panel);
        Assert.Equal(1, tab.PageCount);
        panel.Detach();
        tab.Dispose();
    });
}
