using LazyPDF.App.Documents;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

public sealed class TabCloseButtonTests
{
    [Fact]
    public void TheCloseButtonIsNamedAfterTheFile()
    {
        using var tab = new DocumentTab(PdfEditSession.Open(Pdfs.Text(1)), new FakeRenderer(), null, "a.pdf", null);

        Assert.Equal("Close a.pdf", tab.CloseAutomationName);
    }

    [Fact]
    public void TheTabTemplateKeepsTheCloseButtonFocusable()
    {
        var xaml = File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "LazyPDF.App", "MainWindow.xaml"));
        var button = xaml[xaml.IndexOf("x:Name=\"CloseButton\"", StringComparison.Ordinal)..];
        button = button[..button.IndexOf("/>", StringComparison.Ordinal)];

        Assert.DoesNotContain("IsTabStop=\"False\"", button);
        Assert.Contains("CloseAutomationName", button);
    }

    [Fact]
    public void TheTabStripLetsTabReachEachCloseButton()
    {
        var xaml = File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "LazyPDF.App", "MainWindow.xaml"));
        var list = xaml[xaml.IndexOf("x:Name=\"TabList\"", StringComparison.Ordinal)..];
        list = list[..list.IndexOf("ItemContainerStyle", StringComparison.Ordinal)];

        Assert.Contains("KeyboardNavigation.TabNavigation=\"Continue\"", list);
    }
}
