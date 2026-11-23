using System.Windows;
using System.Windows.Controls;
using LazyPDF.App.Tools.Forms;
using Xunit;

namespace LazyPDF.App.Tests;

// Combo boxes and lists are opaque over the page at view 0 and draw nothing while idle on a turned view.
[Collection("Application")]
public sealed class FillLayerRestyleTests
{
    private static IEnumerable<T> All<T>(DependencyObject parent) where T : DependencyObject
    {
        foreach (var child in LogicalTreeHelper.GetChildren(parent).OfType<DependencyObject>())
        {
            if (child is T found) yield return found;
            foreach (var inner in All<T>(child)) yield return inner;
        }
    }

    [Theory]
    [InlineData(0, 1.0)]
    [InlineData(90, 0.0)]
    [InlineData(180, 0.0)]
    [InlineData(270, 0.0)]
    public Task IdleChoicesAreTransparentOnATurnedView(int rotation, double opacity) => Sta.Run(() =>
    {
        using var tab = FormPdfs.Tab();
        var viewer = FormStand.Create(tab, out var stand);
        stand.Rotation = rotation;
        var layer = new FillLayer(viewer, (_, _) => true, (_, _) => true, _ => { }, _ => { }, _ => { });

        layer.Show(FormPdfs.Read(tab), true);

        var overlay = stand.Window.Content as Canvas;
        Assert.Equal(opacity, Assert.Single(All<ComboBox>(overlay!)).Opacity);
        Assert.Equal(opacity, Assert.Single(All<ListBox>(overlay!)).Opacity);
        stand.Dispose();
        return Task.CompletedTask;
    });

    [Fact]
    public Task TurningTheViewRestylesTheBuiltControlsBothWays() => Sta.Run(() =>
    {
        using var tab = FormPdfs.Tab();
        var viewer = FormStand.Create(tab, out var stand);
        var layer = new FillLayer(viewer, (_, _) => true, (_, _) => true, _ => { }, _ => { }, _ => { });
        layer.Show(FormPdfs.Read(tab), true);
        var combo = All<ComboBox>((Canvas)stand.Window.Content).Single();
        var list = All<ListBox>((Canvas)stand.Window.Content).Single();
        Assert.Equal(1.0, combo.Opacity);

        stand.Rotation = 90;
        layer.Restyle();
        Assert.Equal(0.0, combo.Opacity);
        Assert.Equal(0.0, list.Opacity);

        stand.Rotation = 0;
        layer.Restyle();
        Assert.Equal(1.0, combo.Opacity);
        Assert.Equal(1.0, list.Opacity);
        stand.Dispose();
        return Task.CompletedTask;
    });
}
