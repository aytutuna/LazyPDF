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

    private static PdfAnnotation BigItalicText(CommentFixture f, CommentPanel panel)
    {
        var style = StyleOf(panel) with { Family = "Arial", Size = 20, Font = LazyPDF.Core.FontStyles.Bold | LazyPDF.Core.FontStyles.Italic };
        var made = f.Marker.Add(MarkTool.TextBox, 0, [new Point(60, 80), new Point(260, 140)], style, "Hello");
        return f.Marks().Single(m => m.Reference?.Number == made.Reference?.Number);
    }

    [Fact]
    public Task ASelectedFreeTextShowsItsFontSizeBoldAndItalic() => Sta.Run(() =>
    {
        if (!System.Windows.Media.Fonts.SystemFontFamilies.Any(x => x.Source == "Arial")) return Task.CompletedTask;
        using var f = new CommentFixture();
        var panel = Attached(f);
        var mark = BigItalicText(f, panel);

        Get<EditTool>(panel, "_edit").Select(mark);

        Assert.Equal("Arial", Get<ComboBox>(panel, "FontFamilyBox").SelectedItem);
        Assert.Equal("20", Get<ComboBox>(panel, "FontSizeBox").Text);
        Assert.True(Get<System.Windows.Controls.Primitives.ToggleButton>(panel, "BoldToggle").IsChecked);
        Assert.True(Get<System.Windows.Controls.Primitives.ToggleButton>(panel, "ItalicToggle").IsChecked);
        return Task.CompletedTask;
    });

    [Fact]
    public Task SwitchingToolsDropsTheSelectionAndBringsBackTheFontOfTheNextMark() => Sta.Run(() =>
    {
        if (!System.Windows.Media.Fonts.SystemFontFamilies.Any(x => x.Source == "Arial")) return Task.CompletedTask;
        using var f = new CommentFixture();
        var panel = Attached(f);
        var before = StyleOf(panel);
        var mark = BigItalicText(f, panel);
        var edit = Get<EditTool>(panel, "_edit");
        edit.Select(mark);
        Assert.Equal("20", Get<ComboBox>(panel, "FontSizeBox").Text);

        Get<Dictionary<MarkTool, RadioButton>>(panel, "_buttons")[MarkTool.Rectangle].IsChecked = true;

        Assert.Null(edit.Current);
        var after = StyleOf(panel);
        Assert.Equal(before.Family, after.Family);
        Assert.Equal(before.Size, after.Size);
        Assert.Equal(before.Font, after.Font);
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
    public Task ATickedStampDateAddsTodayToTheName() => Sta.Run(() =>
    {
        using var f = new CommentFixture();
        var panel = Attached(f);
        Get<CheckBox>(panel, "StampDate").IsChecked = true;
        Get<Dictionary<MarkTool, RadioButton>>(panel, "_buttons")[MarkTool.Stamp].IsChecked = true;

        var tool = Get<IPagePointerTool>(panel, "_active");
        tool.Press(At(new Point(200, 300)));
        tool.Release(At(new Point(200, 300)));

        var stamp = f.Marks().Single();
        Assert.Equal("APPROVED " + DateTime.Today.ToString("yyyy-MM-dd", System.Globalization.CultureInfo.InvariantCulture), stamp.IconName);
        Assert.Equal(Marker.DatedStampWidth, f.Marker.BoxOf(stamp).Width, 0.5);
        return Task.CompletedTask;
    });

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

    [Fact]
    public async Task ASelectionShowsTheBarAndAButtonMarksItAndHidesIt() => await Sta.Run(async () =>
    {
        using var f = new CommentFixture();
        var (viewer, stand) = Selecting();
        var panel = new CommentPanel();
        panel.Attach(f.Tab, viewer, new RecordingHost());
        var bar = Get<SelectionBar>(panel, "_bar");

        stand.Select(new SelectedRun(0, default, "Hello", [new TextQuad(100, 700, 180, 700, 180, 712, 100, 712)]));
        Assert.False(bar.IsOpen);
        await Sta.Until(() => bar.IsOpen);

        var row = (Panel)((Border)Get<System.Windows.Controls.Primitives.Popup>(bar, "_popup").Child).Child;
        var highlight = (Button)row.Children[0];
        Assert.Equal("Highlight", System.Windows.Automation.AutomationProperties.GetName(highlight));
        highlight.RaiseEvent(new RoutedEventArgs(System.Windows.Controls.Primitives.ButtonBase.ClickEvent));
        await Sta.Until(() => f.Marks().Count == 1);

        Assert.Equal(AnnotationType.Highlight, f.Marks().Single().Type);
        await Sta.Until(() => !bar.IsOpen);
    });

    [Fact]
    public async Task ClearingTheSelectionHidesTheBar() => await Sta.Run(async () =>
    {
        using var f = new CommentFixture();
        var (viewer, stand) = Selecting();
        var panel = new CommentPanel();
        panel.Attach(f.Tab, viewer, new RecordingHost());
        var bar = Get<SelectionBar>(panel, "_bar");
        stand.Select(new SelectedRun(0, default, "Hello", [new TextQuad(100, 700, 180, 700, 180, 712, 100, 712)]));
        await Sta.Until(() => bar.IsOpen);

        stand.Select();

        Assert.False(bar.IsOpen);
    });

    private static (IDocumentViewer Viewer, FakeViewer Stand) Selecting()
    {
        var viewer = FakeViewer.Create().Viewer;
        return (viewer, (FakeViewer)(object)viewer);
    }
}
