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
    public Task ADragToolSaysTheKeyboardNeedsAnEnterAtEachEnd() => Sta.Run(() =>
    {
        using var f = new CommentFixture();
        var panel = Attached(f);
        Get<Dictionary<MarkTool, RadioButton>>(panel, "_buttons")[MarkTool.Line].IsChecked = true;

        Assert.Contains("press Enter at each end", Get<System.Windows.Controls.TextBlock>(panel, "Hint").Text);
        return Task.CompletedTask;
    });

    [Fact]
    public Task EveryFamilyOfTheListIsOneTheEngineCanEmbed() => Sta.Run(() =>
    {
        using var f = new CommentFixture();
        var source = new LazyPDF.App.Services.SystemFontSource();
        var refused = Get<ComboBox>(Attached(f), "FontFamilyBox").ItemsSource.Cast<string>().Skip(3)
            .Where(name => source.Find(name, LazyPDF.Core.FontStyles.Regular) is null).ToList();

        Assert.Empty(refused);
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

        Drag(tool, new Point(60, 50), new Point(80, 70));

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
    public Task AColourPickedOnAMarkJustDrawnKeepsTheRestOfTheDrawingLook() => Sta.Run(() =>
    {
        using var f = new CommentFixture();
        var panel = Attached(f);
        var fill = Get<ComboBox>(panel, "FillBox");
        fill.SelectedIndex = 1;
        Drag(Rectangles(panel), new Point(40, 50), new Point(120, 100));
        var loading = panel.GetType().GetField("_loading", Private)!;
        loading.SetValue(panel, true);
        fill.SelectedIndex = 0;
        loading.SetValue(panel, false);

        var blue = Get<Panel>(panel, "Swatches").Children.OfType<RadioButton>().Last();
        blue.IsChecked = true;
        Get<EditTool>(panel, "_edit").Select(null);

        Assert.Equal(1, fill.SelectedIndex);
        Assert.Equal(blue.Tag, StyleOf(panel).Color);
        return Task.CompletedTask;
    });

    [Fact]
    public Task APressThatDrawsNothingStillDropsTheSelection() => Sta.Run(() =>
    {
        using var f = new CommentFixture();
        var panel = Attached(f);
        var tool = Rectangles(panel);
        var edit = Get<EditTool>(panel, "_edit");
        Drag(tool, new Point(40, 50), new Point(120, 100));
        Assert.NotNull(edit.Current);

        Drag(tool, new Point(10, 200), new Point(11, 200));

        Assert.Null(edit.Current);
        Assert.Single(f.Marks());
        return Task.CompletedTask;
    });

    [Theory]
    [InlineData(MarkTool.Pencil, false)]
    [InlineData(MarkTool.Line, false)]
    [InlineData(MarkTool.Arrow, false)]
    [InlineData(MarkTool.Rectangle, true)]
    [InlineData(MarkTool.Oval, true)]
    public void OnlyToolsThatDoNotChainStrokesTakeHoldOfTheSelectedMark(MarkTool tool, bool grabs) =>
        Assert.Equal(grabs, CommentPanel.CanGrab(tool));

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

        stand.Select(new SelectedRun(0, default, "Hello", [new TextQuad(100, 200, 180, 200, 180, 212, 100, 212)]));
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
        stand.Select(new SelectedRun(0, default, "Hello", [new TextQuad(100, 200, 180, 200, 180, 212, 100, 212)]));
        await Sta.Until(() => bar.IsOpen);

        stand.Select();

        Assert.False(bar.IsOpen);
    });

    private static void Pick(CommentPanel panel, MarkTool tool) => Get<Dictionary<MarkTool, RadioButton>>(panel, "_buttons")[tool].IsChecked = true;

    private static void Settle(CommentPanel panel) => typeof(CommentPanel).GetMethod("Settle_Tick", Private)!.Invoke(panel, [null, EventArgs.Empty]);

    private static int HeadIndex(LineEnding head) => Array.FindIndex(Get<(string Name, LineEnding Value)[]>(typeof(CommentPanel), "Heads"), h => h.Value == head);

    private static T Get<T>(Type type, string field) => (T)type.GetField(field, BindingFlags.Static | Private)!.GetValue(null)!;

    private static PdfAnnotation Line(CommentFixture f, double y, LineEnding start = LineEnding.None, LineEnding end = LineEnding.None)
    {
        var made = f.Marker.Add(MarkTool.Line, 0, [new Point(60, y), new Point(260, y + 40)], MarkStyle.Default with { StartHead = start, Head = end });
        Assert.True(f.Tab.Commit("Line"));
        return f.Marks().Single(m => m.Reference?.Number == made.Reference?.Number);
    }

    [Fact]
    public Task TheLineToolDrawsAPlainLineAndTheArrowToolAnOpenArrow() => Sta.Run(() =>
    {
        using var f = new CommentFixture();
        var panel = Attached(f);

        Pick(panel, MarkTool.Line);
        Drag(Get<IPagePointerTool>(panel, "_active"), new Point(40, 50), new Point(120, 100));
        Pick(panel, MarkTool.Arrow);
        Drag(Get<IPagePointerTool>(panel, "_active"), new Point(40, 150), new Point(120, 200));

        var marks = f.Marks();
        Assert.Equal((LineEnding.None, LineEnding.None), (marks[0].StartEnding, marks[0].EndEnding));
        Assert.Equal((LineEnding.None, LineEnding.OpenArrow), (marks[1].StartEnding, marks[1].EndEnding));
        return Task.CompletedTask;
    });

    [Fact]
    public Task AHeadPickedForTheArrowToolDoesNotShowOnTheLineTool() => Sta.Run(() =>
    {
        using var f = new CommentFixture();
        var panel = Attached(f);
        var end = Get<ComboBox>(panel, "HeadBox");
        var start = Get<ComboBox>(panel, "StartHeadBox");

        Pick(panel, MarkTool.Arrow);
        end.SelectedIndex = HeadIndex(LineEnding.ClosedArrow);
        start.SelectedIndex = HeadIndex(LineEnding.Circle);
        Pick(panel, MarkTool.Line);

        Assert.Equal(HeadIndex(LineEnding.None), end.SelectedIndex);
        Assert.Equal(HeadIndex(LineEnding.None), start.SelectedIndex);
        Pick(panel, MarkTool.Arrow);
        Assert.Equal(HeadIndex(LineEnding.ClosedArrow), end.SelectedIndex);
        Assert.Equal(HeadIndex(LineEnding.Circle), start.SelectedIndex);
        Assert.Equal(LineEnding.ClosedArrow, StyleOf(panel).Head);
        Assert.Equal(LineEnding.Circle, StyleOf(panel).StartHead);
        return Task.CompletedTask;
    });

    [Theory]
    [InlineData(LineEnding.Butt)]
    [InlineData(LineEnding.ROpenArrow)]
    [InlineData(LineEnding.RClosedArrow)]
    public Task ChangingOnlyTheStartHeadLeavesTheEndAsItWas(LineEnding end) => Sta.Run(() =>
    {
        using var f = new CommentFixture();
        var line = Line(f, 80, LineEnding.None, end);
        var panel = Attached(f);
        Get<EditTool>(panel, "_edit").Select(line);

        Get<ComboBox>(panel, "StartHeadBox").SelectedIndex = HeadIndex(LineEnding.Circle);
        Settle(panel);

        var read = f.Marks().Single();
        Assert.Equal(LineEnding.Circle, read.StartEnding);
        Assert.Equal(end, read.EndEnding);
        Assert.True(f.Tab.Undo());
        Assert.Equal((LineEnding.None, end), (f.Marks().Single().StartEnding, f.Marks().Single().EndEnding));
        return Task.CompletedTask;
    });

    [Fact]
    public Task AStartHeadChosenOnAMarkJustDrawnIsKeptForTheNextOneAndNothingElse() => Sta.Run(() =>
    {
        using var f = new CommentFixture();
        var panel = Attached(f);
        var before = StyleOf(panel);
        Pick(panel, MarkTool.Line);
        Drag(Get<IPagePointerTool>(panel, "_active"), new Point(40, 50), new Point(120, 100));

        Get<ComboBox>(panel, "StartHeadBox").SelectedIndex = HeadIndex(LineEnding.Circle);
        Settle(panel);

        var kept = Get<MarkStyle?>(panel, "_drawing")!;
        Assert.Equal(LineEnding.Circle, kept.StartHead);
        Assert.Equal((before.Family, before.Size, before.Font), (kept.Family, kept.Size, kept.Font));
        Assert.Equal(LineEnding.None, f.Marks().Single().StartEnding);
        return Task.CompletedTask;
    });

    [Fact]
    public Task AHeadChangeThenSelectingAnotherMarkLandsOnTheFirstOnlyInOneStep() => Sta.Run(() =>
    {
        using var f = new CommentFixture();
        var first = Line(f, 80);
        var second = Line(f, 200);
        var panel = Attached(f);
        var edit = Get<EditTool>(panel, "_edit");
        edit.Select(first);

        Get<ComboBox>(panel, "StartHeadBox").SelectedIndex = HeadIndex(LineEnding.Diamond);
        edit.Select(f.Marks().Single(m => m.Reference?.Number == second.Reference?.Number));
        Settle(panel);

        Assert.Equal(LineEnding.Diamond, Marked(f, first).StartEnding);
        Assert.Equal(LineEnding.None, Marked(f, second).StartEnding);
        Assert.True(f.Tab.Undo());
        Assert.Equal(LineEnding.None, Marked(f, first).StartEnding);
        return Task.CompletedTask;
    });

    private static PdfAnnotation Marked(CommentFixture f, PdfAnnotation mark) => f.Marks().Single(m => m.Reference?.Number == mark.Reference?.Number);

    [Fact]
    public Task AHeadChangeIsWrittenWhenTheDocumentIsHandedInAndNotAgainAfterAnUndo() => Sta.Run(() =>
    {
        using var f = new CommentFixture();
        var line = Line(f, 80);
        var panel = Attached(f);
        Get<EditTool>(panel, "_edit").Select(line);

        Get<ComboBox>(panel, "HeadBox").SelectedIndex = HeadIndex(LineEnding.ClosedArrow);
        Assert.True(panel.HandIn());

        Assert.Equal(LineEnding.ClosedArrow, Marked(f, line).EndEnding);
        Assert.True(f.Tab.Undo());
        Settle(panel);
        Assert.Equal(LineEnding.None, Marked(f, line).EndEnding);
        return Task.CompletedTask;
    });

    [Fact]
    public Task AHeadChangeIsWrittenWhenThePanelIsLeft() => Sta.Run(() =>
    {
        using var f = new CommentFixture();
        var line = Line(f, 80);
        var panel = Attached(f);
        Get<EditTool>(panel, "_edit").Select(line);

        Get<ComboBox>(panel, "HeadBox").SelectedIndex = HeadIndex(LineEnding.Square);
        panel.Detach();

        Assert.Equal(LineEnding.Square, Marked(f, line).EndEnding);
        return Task.CompletedTask;
    });

    [Fact]
    public Task AStartHeadIsOfferedOnALineThatAlreadyHasOne() => Sta.Run(() =>
    {
        using var f = new CommentFixture();
        var line = Line(f, 80, LineEnding.Circle, LineEnding.OpenArrow);
        var panel = Attached(f);

        Get<EditTool>(panel, "_edit").Select(line);

        Assert.Equal(Visibility.Visible, Get<StackPanel>(panel, "HeadRow").Visibility);
        Assert.Equal(HeadIndex(LineEnding.Circle), Get<ComboBox>(panel, "StartHeadBox").SelectedIndex);
        Assert.Equal(HeadIndex(LineEnding.OpenArrow), Get<ComboBox>(panel, "HeadBox").SelectedIndex);
        return Task.CompletedTask;
    });

    [Fact]
    public Task AMarkWithPartsWeCannotRedrawDisablesTheLookAndOffersNoHead() => Sta.Run(() =>
    {
        using var f = new CommentFixture();
        var plain = f.Marker.Add(MarkTool.Line, 0, [new Point(60, 80), new Point(260, 140)], MarkStyle.Default);
        var other = f.Marker.Add(MarkTool.Line, 0, [new Point(60, 200), new Point(260, 260)], MarkStyle.Default);
        other.Dictionary["LL"] = new PdfNumber(10);
        var panel = Attached(f);
        var edit = Get<EditTool>(panel, "_edit");

        edit.Select(f.Marks().Single(m => m.Reference?.Number == plain.Reference?.Number));
        Assert.True(Get<WrapPanel>(panel, "Swatches").IsEnabled);
        Assert.True(Get<ComboBox>(panel, "LineStyleBox").IsEnabled);
        Assert.Equal(Visibility.Visible, Get<StackPanel>(panel, "HeadRow").Visibility);

        edit.Select(f.Marks().Single(m => m.Reference?.Number == other.Reference?.Number));
        Assert.False(Get<WrapPanel>(panel, "Swatches").IsEnabled);
        Assert.False(Get<Slider>(panel, "WidthSlider").IsEnabled);
        Assert.False(Get<Slider>(panel, "OpacitySlider").IsEnabled);
        Assert.False(Get<ComboBox>(panel, "FillBox").IsEnabled);
        Assert.False(Get<ComboBox>(panel, "LineStyleBox").IsEnabled);
        Assert.Equal(Visibility.Collapsed, Get<StackPanel>(panel, "HeadRow").Visibility);
        return Task.CompletedTask;
    });

    private static (IDocumentViewer Viewer, FakeViewer Stand) Selecting()
    {
        var viewer = FakeViewer.Create().Viewer;
        return (viewer, (FakeViewer)(object)viewer);
    }
}
