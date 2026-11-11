using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using LazyPDF.App.Tools.Comment;
using LazyPDF.App.Viewer;
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

    private static PagePointer At(Point at, bool pressed = true, int clicks = 1) => new(0, at, at, pressed, clicks, ModifierKeys.None);

    private static void Drag(IPagePointerTool tool, Point from, Point to)
    {
        tool.Press(At(from));
        tool.Move(At(to));
        tool.Release(At(to));
    }

    private static IPagePointerTool Rectangles(CommentPanel panel)
    {
        Get<Dictionary<MarkTool, RadioButton>>(panel, "_buttons")[MarkTool.Rectangle].IsChecked = true;
        return Get<IPagePointerTool>(panel, "_active");
    }

    [Fact]
    public Task AMarkJustDrawnStaysSelectedAndMovesWithTheSameTool() => Sta.Run(() =>
    {
        using var f = new CommentFixture();
        var panel = Attached(f);
        var tool = Rectangles(panel);
        var edit = Get<EditTool>(panel, "_edit");

        Drag(tool, new Point(40, 50), new Point(120, 100));
        var drawn = f.Marks().Single();
        Assert.Equal(drawn.Reference?.Number, edit.Current?.Reference?.Number);

        Drag(tool, new Point(80, 75), new Point(100, 95));

        Assert.Same(tool, Get<IPagePointerTool>(panel, "_active"));
        var moved = Assert.Single(f.Marks());
        Assert.Equal(drawn.Reference?.Number, edit.Current?.Reference?.Number);
        var before = f.Geometry.ToDisplay(drawn.Rect);
        var after = f.Geometry.ToDisplay(moved.Rect);
        Assert.Equal(20, after.X - before.X, 0.5);
        Assert.Equal(20, after.Y - before.Y, 0.5);
        Assert.True(f.Tab.Undo());
        Assert.Equal(before.X, f.Geometry.ToDisplay(f.Marks().Single().Rect).X, 0.5);
        Assert.Single(f.Marks());
        return Task.CompletedTask;
    });

    [Fact]
    public Task APressOnEmptyPageDrawsANewMarkAndDropsTheSelection() => Sta.Run(() =>
    {
        using var f = new CommentFixture();
        var panel = Attached(f);
        var tool = Rectangles(panel);
        var edit = Get<EditTool>(panel, "_edit");

        Drag(tool, new Point(40, 50), new Point(120, 100));
        Drag(tool, new Point(10, 200), new Point(60, 260));

        Assert.Equal(2, f.Marks().Count);
        Assert.Equal(f.Marks()[1].Reference?.Number, edit.Current?.Reference?.Number);
        return Task.CompletedTask;
    });
}
