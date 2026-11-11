using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using LazyPDF.App.Documents;
using LazyPDF.App.Tools.Pages;
using LazyPDF.App.Viewer;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// The crop box belongs to the page it was drawn on, whatever the thumbnail grid had selected before.
[Collection("Application")]
public sealed class PagesPanelCropTests
{
    private static PagesPanel Crop(DocumentTab tab)
    {
        var panel = new PagesPanel();
        panel.Attach(tab, FakeViewer.Create().Viewer, new RecordingHost());
        ((Expander)panel.FindName("CropSection")).IsExpanded = true;
        return panel;
    }

    private static List<int> Selected(PagesPanel panel) =>
        [.. ((ListBox)panel.FindName("Thumbs")).SelectedItems.Cast<PageCell>().Select(c => c.Index).Order()];

    private static void Select(PagesPanel panel, params int[] pages)
    {
        var grid = (ListBox)panel.FindName("Thumbs");
        grid.SelectedItems.Clear();
        foreach (int page in pages) grid.SelectedItems.Add(((List<PageCell>)grid.ItemsSource)[page]);
    }

    private static void Draw(PagesPanel panel, int page)
    {
        var tool = (CropTool)typeof(PagesPanel).GetField("_crop", BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(panel)!;
        tool.Press(new PagePointer(page, new Point(10, 10), new Point(10, 10), true, 1, ModifierKeys.None));
        tool.Release(new PagePointer(page, new Point(100, 100), new Point(100, 100), false, 1, ModifierKeys.None));
    }

    private static void RunCrop(PagesPanel panel) =>
        typeof(PagesPanel).GetMethod("Crop", BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(panel, null);

    [Fact]
    public Task TheBoxSelectsItsPageWhenNothingIsSelected() => Sta.Run(() =>
    {
        using var tab = new DocumentTab(PdfEditSession.Open(Pdfs.Text(3)), new FakeRenderer(), null, "a.pdf");
        var panel = Crop(tab);

        Draw(panel, 2);

        Assert.Equal([2], Selected(panel));
        panel.Detach();
        return Task.CompletedTask;
    });

    [Fact]
    public Task AChosenSelectionStaysWhenTheBoxIsOnAnotherPage() => Sta.Run(() =>
    {
        using var tab = new DocumentTab(PdfEditSession.Open(Pdfs.Text(10)), new FakeRenderer(), null, "a.pdf");
        var panel = Crop(tab);
        Select(panel, 4, 5, 6, 7, 8, 9);

        Draw(panel, 2);

        Assert.Equal([4, 5, 6, 7, 8, 9], Selected(panel));
        panel.Detach();
        return Task.CompletedTask;
    });

    [Fact]
    public Task TheAutomaticSelectionGoesAfterCropping() => Sta.Run(() =>
    {
        using var tab = new DocumentTab(PdfEditSession.Open(Pdfs.Text(3)), new FakeRenderer(), null, "a.pdf");
        var panel = Crop(tab);
        Draw(panel, 1);

        RunCrop(panel);

        Assert.Empty(Selected(panel));
        panel.Detach();
        return Task.CompletedTask;
    });

    [Fact]
    public Task TheAutomaticSelectionGoesWhenTheSectionCloses() => Sta.Run(() =>
    {
        using var tab = new DocumentTab(PdfEditSession.Open(Pdfs.Text(3)), new FakeRenderer(), null, "a.pdf");
        var panel = Crop(tab);
        Draw(panel, 1);

        ((Expander)panel.FindName("CropSection")).IsExpanded = false;

        Assert.Empty(Selected(panel));
        panel.Detach();
        return Task.CompletedTask;
    });

    [Fact]
    public Task ASelectionMadeByHandSurvivesTheBoxBeingCleared() => Sta.Run(() =>
    {
        using var tab = new DocumentTab(PdfEditSession.Open(Pdfs.Text(3)), new FakeRenderer(), null, "a.pdf");
        var panel = Crop(tab);
        Draw(panel, 1);
        Select(panel, 0, 2);
        var tool = (CropTool)typeof(PagesPanel).GetField("_crop", BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(panel)!;

        tool.Clear();

        Assert.Equal([0, 2], Selected(panel));
        panel.Detach();
        return Task.CompletedTask;
    });

    [Fact]
    public Task CropCoversTheChosenPagesNotTheBoxPage() => Sta.Run(() =>
    {
        using var tab = new DocumentTab(PdfEditSession.Open(Pdfs.Text(10)), new FakeRenderer(), null, "a.pdf");
        var panel = Crop(tab);
        Select(panel, 4, 5, 6, 7, 8, 9);
        Draw(panel, 2);

        RunCrop(panel);

        var pages = tab.Document.Pages;
        Assert.Equal(pages[2].MediaBox, pages[2].CropBox);
        Assert.NotEqual(pages[4].MediaBox, pages[4].CropBox);
        Assert.NotEqual(pages[9].MediaBox, pages[9].CropBox);
        panel.Detach();
        return Task.CompletedTask;
    });

    [Fact]
    public Task PagesTickedOnPurposeStayWhenTheBoxIsOnOneOfThem() => Sta.Run(() =>
    {
        using var tab = new DocumentTab(PdfEditSession.Open(Pdfs.Text(3)), new FakeRenderer(), null, "a.pdf");
        var panel = Crop(tab);
        Select(panel, 0, 2);

        Draw(panel, 2);

        Assert.Equal([0, 2], Selected(panel));
        panel.Detach();
        return Task.CompletedTask;
    });

    [Fact]
    public Task MarginsAcceptADecimalCommaAndRefuseNegativeNumbers() => Sta.Run(() =>
    {
        var before = System.Globalization.CultureInfo.CurrentCulture;
        System.Globalization.CultureInfo.CurrentCulture = new System.Globalization.CultureInfo("tr-TR");
        try
        {
            using var tab = new DocumentTab(PdfEditSession.Open(Pdfs.Text(1)), new FakeRenderer(), null, "a.pdf");
            var panel = Crop(tab);
            var apply = (Button)panel.FindName("CropMargins");

            ((TextBox)panel.FindName("CropLeft")).Text = "1,5";
            Assert.True(apply.IsEnabled);

            ((TextBox)panel.FindName("CropTop")).Text = "-1";
            Assert.False(apply.IsEnabled);

            ((TextBox)panel.FindName("CropTop")).Text = "abc";
            Assert.False(apply.IsEnabled);
            panel.Detach();
        }
        finally
        {
            System.Globalization.CultureInfo.CurrentCulture = before;
        }
        return Task.CompletedTask;
    });
}
