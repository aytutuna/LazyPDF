using LazyPDF.App.Services;
using Xunit;

namespace LazyPDF.App.Tests;

[Collection("Application")]
public sealed class PrintLayoutWindowTests
{
    // Closed afterwards, since NoWindowTests expects the application to hold no window.
    private static Task With(Action<PrintLayoutWindow> test, PrintLayout? remembered = null, bool rightToLeft = false) => Sta.Run(() =>
    {
        var window = new PrintLayoutWindow(null, 8, remembered ?? new PrintLayout(), 612, 792, rightToLeft);
        try { test(window); }
        finally { window.Close(); }
        return Task.CompletedTask;
    });

    [Fact]
    public Task TheWindowOpensWithTheRememberedChoicesAndTheCountOfPages() => With(window =>
    {
        var layout = window.Current()!.Value.Layout;
        Assert.Equal((2, true), (layout.PerSheet, layout.Border));
        Assert.Equal(7.2, layout.Gap, 0.2);
        Assert.Equal("8 pages: 4 sides on 2 pieces of paper.", window.Summary.Text);
        Assert.True(window.PrintButton.IsEnabled);
    }, new PrintLayout(PerSheet: 2, Gap: 7.2, Border: true));

    [Fact]
    public Task TheDocumentsReadingDirectionSetsTheBinding() => With(window =>
        Assert.True(window.Current()!.Value.Layout.RightToLeft), rightToLeft: true);

    [Fact]
    public Task AnotherDocumentStartsWithTheLeftBinding() => With(window =>
        Assert.False(window.Current()!.Value.Layout.RightToLeft));

    [Fact]
    public Task TheOddAndEvenItemsSayPagesUntilTheLayoutImposes() => With(window =>
    {
        Assert.Equal("Odd pages only", window.OddItem.Content);
        Assert.Equal("Even pages only", window.EvenItem.Content);
        window.BookletBox.IsChecked = true;
        Assert.Equal("Odd sides only", window.OddItem.Content);
        Assert.Equal("Even sides only", window.EvenItem.Content);
        window.BookletBox.IsChecked = false;
        Assert.Equal("Odd pages only", window.OddItem.Content);
    });

    [Fact]
    public Task AChangeUpdatesTheSummaryAndTheHint() => With(window =>
    {
        Assert.Equal("Two-sided printing must flip on the short edge.", window.SidesHint.Text);
        window.ParityBox.SelectedIndex = 2;

        Assert.Equal("8 pages: 4 sides on 2 pieces of paper. Even sides (backs): 2 of 4.", window.Summary.Text);
        Assert.StartsWith("To print both sides by hand", window.SidesHint.Text);
    }, new PrintLayout(Booklet: true));

    [Fact]
    public Task ABadGapShowsItsMessageAndStopsPrint() => With(window =>
    {
        window.GapBox.Text = "abc";

        Assert.False(window.PrintButton.IsEnabled);
        Assert.Equal("Type a gap from 0 to 25 mm.", window.GapProblem.Text);
        Assert.Equal(System.Windows.Automation.AutomationLiveSetting.Assertive, System.Windows.Automation.AutomationProperties.GetLiveSetting(window.GapProblem));
        window.GapBox.Text = "3";
        Assert.True(window.PrintButton.IsEnabled);
        Assert.Equal(System.Windows.Visibility.Collapsed, window.GapProblem.Visibility);
    }, new PrintLayout(PerSheet: 2));

    [Fact]
    public Task GapBindingAndBorderWaitForALayout() => With(window =>
    {
        Assert.False(window.GapBox.IsEnabled);
        Assert.False(window.BindingBox.IsEnabled);
        window.BookletBox.IsChecked = true;
        Assert.True(window.GapBox.IsEnabled);
        Assert.False(window.PerSheetBox.IsEnabled);
    });
}
