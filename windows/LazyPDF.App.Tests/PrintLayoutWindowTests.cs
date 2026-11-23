using LazyPDF.App.Services;
using Xunit;

namespace LazyPDF.App.Tests;

[Collection("Application")]
public sealed class PrintLayoutWindowTests
{
    private static PrintLayoutWindow Make(PrintLayout? remembered = null, bool rightToLeft = false) =>
        new(null, 8, remembered ?? new PrintLayout(), 612, 792, rightToLeft);

    [Fact]
    public Task TheWindowOpensWithTheRememberedChoicesAndTheCountOfPages() => Sta.Run(() =>
    {
        var window = Make(new PrintLayout(PerSheet: 2, Gap: 7.2, Border: true));

        var layout = window.Current()!.Value.Layout;
        Assert.Equal((2, true), (layout.PerSheet, layout.Border));
        Assert.Equal(7.2, layout.Gap, 0.2);
        Assert.Equal("8 pages: 4 sides on 2 pieces of paper.", window.Summary.Text);
        Assert.True(window.PrintButton.IsEnabled);
        return Task.CompletedTask;
    });

    [Fact]
    public Task TheDocumentsReadingDirectionSetsTheBinding() => Sta.Run(() =>
    {
        Assert.True(Make(rightToLeft: true).Current()!.Value.Layout.RightToLeft);
        Assert.False(Make().Current()!.Value.Layout.RightToLeft);
        return Task.CompletedTask;
    });

    [Fact]
    public Task AChangeUpdatesTheSummaryAndTheHint() => Sta.Run(() =>
    {
        var window = Make(new PrintLayout(Booklet: true));

        Assert.Equal("Two-sided printing must flip on the short edge.", window.SidesHint.Text);
        window.ParityBox.SelectedIndex = 2;

        Assert.Equal("8 pages: 4 sides on 2 pieces of paper. Even sides (backs): 2 of 4.", window.Summary.Text);
        Assert.StartsWith("To print both sides by hand", window.SidesHint.Text);
        return Task.CompletedTask;
    });

    [Fact]
    public Task ABadGapShowsItsMessageAndStopsPrint() => Sta.Run(() =>
    {
        var window = Make(new PrintLayout(PerSheet: 2));

        window.GapBox.Text = "abc";

        Assert.False(window.PrintButton.IsEnabled);
        Assert.Equal("Type a gap from 0 to 25 mm.", window.GapProblem.Text);
        window.GapBox.Text = "3";
        Assert.True(window.PrintButton.IsEnabled);
        Assert.Equal(System.Windows.Visibility.Collapsed, window.GapProblem.Visibility);
        return Task.CompletedTask;
    });

    [Fact]
    public Task GapBindingAndBorderWaitForALayout() => Sta.Run(() =>
    {
        var window = Make();

        Assert.False(window.GapBox.IsEnabled);
        Assert.False(window.BindingBox.IsEnabled);
        window.BookletBox.IsChecked = true;
        Assert.True(window.GapBox.IsEnabled);
        Assert.False(window.PerSheetBox.IsEnabled);
        return Task.CompletedTask;
    });
}
