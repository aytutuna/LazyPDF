using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using LazyPDF.App.Tools.Comment;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests.Tools.Comment;

[Collection("Application")]
public sealed class CommentPanelTests
{
    private const BindingFlags Private = BindingFlags.Instance | BindingFlags.NonPublic;

    private static T Get<T>(object panel, string field) => (T)panel.GetType().GetField(field, Private)!.GetValue(panel)!;

    private static MarkStyle StyleOf(CommentPanel panel) => (MarkStyle)typeof(CommentPanel).GetMethod("CurrentStyle", Private)!.Invoke(panel, null)!;

    private static CommentPanel Attached(CommentFixture f)
    {
        var panel = new CommentPanel();
        panel.Attach(f.Tab, FakeViewer.Create().Viewer, new RecordingHost());
        return panel;
    }

    [Fact]
    public Task SelectingAMarkDoesNotChangeTheLookOfTheNextOne() => Sta.Run(() =>
    {
        using var f = new CommentFixture();
        var red = MarkStyle.Default with { Color = [0.9, 0.1, 0.1], Width = 5 };
        var mark = f.Marker.Add(MarkTool.Rectangle, 0, [new Point(60, 80), new Point(260, 140)], red);
        var panel = Attached(f);
        var before = StyleOf(panel);
        var edit = Get<EditTool>(panel, "_edit");

        edit.Select(f.Marks().Single(m => m.Reference?.Number == mark.Reference?.Number));
        Assert.Equal(5, StyleOf(panel).Width);
        edit.Select(null);

        var after = StyleOf(panel);
        Assert.Equal(before.Width, after.Width);
        Assert.Equal(before.Opacity, after.Opacity);
        Assert.Equal(before.Color, after.Color);
        Assert.Equal(before.Family, after.Family);
        return Task.CompletedTask;
    });

    [Fact]
    public Task ChoosingDashedChangesTheSelectedMarkInOneUndoStep() => Sta.Run(() =>
    {
        using var f = new CommentFixture();
        var mark = f.Marker.Add(MarkTool.Rectangle, 0, [new Point(60, 80), new Point(260, 140)], MarkStyle.Default with { Color = [0.9, 0.1, 0.1] });
        Assert.True(f.Tab.Commit("Rectangle"));
        var panel = Attached(f);
        Get<EditTool>(panel, "_edit").Select(f.Marks().Single(m => m.Reference?.Number == mark.Reference?.Number));

        Get<ComboBox>(panel, "LineStyleBox").SelectedIndex = (int)LineStyle.Dashed;
        typeof(CommentPanel).GetMethod("Settle_Tick", Private)!.Invoke(panel, [null, EventArgs.Empty]);

        Assert.Equal(LineStyle.Dashed, Marker.LineOf(f.Marks().Single()));
        Assert.True(f.Tab.Undo());
        Assert.Equal(LineStyle.Solid, Marker.LineOf(f.Marks().Single()));
        return Task.CompletedTask;
    });

    [Fact]
    public Task TheTwoLookListsFollowTheToolThatIsPicked() => Sta.Run(() =>
    {
        using var f = new CommentFixture();
        var panel = Attached(f);

        Assert.False(Get<ComboBox>(panel, "FillBox").IsEnabled);
        Assert.True(Marker.TakesLine(MarkTool.Pencil));
        Assert.False(Marker.TakesFill(MarkTool.Pencil));
        Assert.True(Marker.TakesFill(MarkTool.Rectangle));
        Assert.False(Marker.TakesLine(MarkTool.TextBox));
        return Task.CompletedTask;
    });

    [Fact]
    public Task TheFontListStartsWithHelveticaAndHasTheInstalledFamilies() => Sta.Run(() =>
    {
        using var f = new CommentFixture();
        var box = Get<ComboBox>(Attached(f), "FontFamilyBox");
        var families = box.ItemsSource.Cast<string>().ToList();

        Assert.Equal("Helvetica", families[0]);
        if (System.Windows.Media.Fonts.SystemFontFamilies.Any(x => x.Source == "Arial")) Assert.Contains("Arial", families);
        return Task.CompletedTask;
    });

    [Fact]
    public Task AnInstalledFamilyIsTheOneAFreshTextBoxIsDrawnIn() => Sta.Run(() =>
    {
        if (!System.Windows.Media.Fonts.SystemFontFamilies.Any(x => x.Source == "Arial")) return Task.CompletedTask;
        using var f = new CommentFixture();
        var panel = Attached(f);
        Get<ComboBox>(panel, "FontFamilyBox").SelectedItem = "Arial";

        var made = f.Marker.Add(MarkTool.TextBox, 0, [new Point(60, 80), new Point(260, 140)], StyleOf(panel), "Hello");

        Assert.Equal("Arial", Marker.TextOf(made).Family);
        return Task.CompletedTask;
    });
}
