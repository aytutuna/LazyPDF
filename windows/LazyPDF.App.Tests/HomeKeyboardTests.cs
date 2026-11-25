using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Xunit;

namespace LazyPDF.App.Tests;

// A tile that cannot start stays in the tab order, so a screen reader reads why; it starts nothing.
[Collection("Application")]
public sealed class HomeKeyboardTests
{
    private static List<Button> TileButtons(HomeView home)
    {
        var grid = (ItemsControl)home.FindName("TileGrid");
        home.UpdateLayout();
        return [.. Enumerable.Range(0, grid.Items.Count)
            .Select(i => (ContentPresenter)grid.ItemContainerGenerator.ContainerFromIndex(i))
            .Select(p => (Button)VisualTreeHelper.GetChild(p, 0))];
    }

    private static HomeView Show(ViewModelFixture f)
    {
        var home = new HomeView();
        home.Measure(new Size(900, 600));
        home.Arrange(new Rect(0, 0, 900, 600));
        home.Show(f.Vm.Tiles, f.Vm.Recent);
        return home;
    }

    [Fact]
    public Task ATileThatCannotStartCanStillBeFocused() => Sta.Run(() =>
    {
        using var f = new ViewModelFixture();
        var home = Show(f);

        var buttons = TileButtons(home);
        var compress = buttons[f.Vm.Tiles.ToList().FindIndex(t => t.Id == "compress")];

        Assert.True(compress.IsEnabled);
        Assert.True(compress.Focusable);
        Assert.Contains("Not available: Open a file first", System.Windows.Automation.AutomationProperties.GetHelpText(compress));
        return Task.CompletedTask;
    });

    [Fact]
    public Task ClickingATileThatCannotStartIsStillReported() => Sta.Run(() =>
    {
        using var f = new ViewModelFixture();
        var home = Show(f);
        var chosen = new List<string>();
        home.TileChosen += (_, id) => chosen.Add(id);
        var buttons = TileButtons(home);
        int combine = f.Vm.Tiles.ToList().FindIndex(t => t.Id == "combine");
        int batch = f.Vm.Tiles.ToList().FindIndex(t => t.Id == "batch");

        buttons[combine].RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        buttons[batch].RaiseEvent(new RoutedEventArgs(Button.ClickEvent));

        // The view model then says why in the status line; the window does not start anything.
        Assert.Equal(["combine", "batch"], chosen);
        return Task.CompletedTask;
    });
}
