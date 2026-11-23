using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using LazyPDF.App.Documents;
using LazyPDF.App.Tools.Forms;
using LazyPDF.App.Viewer;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// A text, combo or list control stands upright and inside the page while it has the keyboard on a turned view.
[Collection("Application")]
public sealed class FillLayerTurnTests
{
    private sealed class Rig : IDisposable
    {
        public Rig(int rotation, byte[]? pdf = null, bool surface = false)
        {
            Tab = FormPdfs.Tab(pdf);
            Viewer = FormStand.Create(Tab, out var stand, surface);
            Stand = stand;
            Stand.Rotation = rotation;
            Layer = new FillLayer(Viewer, (name, value) =>
            {
                Entered.Add((name, value));
                return true;
            }, (name, values) =>
            {
                Chosen.Add((name, values.Count));
                return true;
            }, _ => { }, _ => { }, _ => { });
            Layer.Show(FormPdfs.Read(Tab), true);
            Stand.Window.Activate();
        }

        public DocumentTab Tab { get; }
        public IDocumentViewer Viewer { get; }
        public FormStand Stand { get; }
        public FillLayer Layer { get; }
        public List<(string Name, string? Value)> Entered { get; } = [];
        public List<(string Name, int Count)> Chosen { get; } = [];

        // A left press on the control as the pointer would raise it; true when something handled it.
        public static bool Press(FrameworkElement control)
        {
            var press = new MouseButtonEventArgs(Mouse.PrimaryDevice, Environment.TickCount, MouseButton.Left)
            {
                RoutedEvent = UIElement.PreviewMouseLeftButtonDownEvent,
                Source = control,
            };
            control.RaiseEvent(press);
            return press.Handled;
        }

        public FrameworkElement Control(string name) =>
            All(Stand.Window).First(e => AutomationProperties.GetName(e) == name);

        public static Border Frame(FrameworkElement control) => (Border)control.Parent;

        public static Canvas Host(FrameworkElement control) => (Canvas)Frame(control).Parent;

        public static PageOverlay Overlay(FrameworkElement control) => (PageOverlay)Host(control).Parent;

        private static IEnumerable<FrameworkElement> All(DependencyObject parent)
        {
            foreach (var child in LogicalTreeHelper.GetChildren(parent).OfType<DependencyObject>())
            {
                if (child is FrameworkElement element) yield return element;
                foreach (var inner in All(child)) yield return inner;
            }
        }

        public Rect Box(PdfRect field, int page = 0)
        {
            var d = new PageGeometry(Tab.Document.Pages[page]).ToDisplay(field);
            return new Rect(d.X, d.Y, d.Width, d.Height);
        }

        public Rect Placed(PdfRect field, int page = 0)
        {
            var g = new PageGeometry(Tab.Document.Pages[page]);
            return PageOverlay.Place(Box(field, page), new Size(g.Width, g.Height), Stand.Rotation);
        }

        public void Dispose()
        {
            Stand.Dispose();
            Tab.Dispose();
        }
    }

    private static readonly PdfRect Name = new(60, 640, 300, 660);
    private static readonly PdfRect Code = new(60, 610, 160, 630);

    // The control as the page draws it: no turn, at its own box, in the default order.
    private static void AssertIdle(FrameworkElement control, Rect box)
    {
        var frame = Rig.Frame(control);
        Assert.True(frame.RenderTransform is null || frame.RenderTransform.Value.IsIdentity);
        Assert.Equal(box.X, Canvas.GetLeft(frame), 6);
        Assert.Equal(box.Y, Canvas.GetTop(frame), 6);
        Assert.Equal(0, Panel.GetZIndex(frame));
    }

    private static void AssertDropped(FrameworkElement control, Rect box)
    {
        AssertIdle(control, box);
        Assert.Equal(0, Panel.GetZIndex(Rig.Host(control)));
        Assert.Equal(0, Panel.GetZIndex(Rig.Overlay(control)));
        Assert.NotNull(Rig.Host(control).Clip);
    }

    [Theory]
    [InlineData(90)]
    [InlineData(180)]
    [InlineData(270)]
    public Task AFocusedTextFieldStandsUprightInThePage(int rotation) => Sta.Run(() =>
    {
        using var rig = new Rig(rotation);
        var text = rig.Control("name");
        var box = rig.Box(Name);
        var placed = rig.Placed(Name);

        Assert.True(text.Focus());

        var frame = Rig.Frame(text);
        var turn = Assert.IsType<RotateTransform>(frame.RenderTransform);
        Assert.Equal(-rotation, turn.Angle);
        Assert.Equal(box.Width / 2, turn.CenterX, 6);
        Assert.Equal(box.Height / 2, turn.CenterY, 6);
        Assert.Equal(placed.X, Canvas.GetLeft(frame), 6);
        Assert.Equal(placed.Y, Canvas.GetTop(frame), 6);
        Assert.Null(Rig.Host(text).Clip);
        Assert.True(Panel.GetZIndex(frame) > 0);
        Assert.True(Panel.GetZIndex(Rig.Host(text)) > 0);
        Assert.True(Panel.GetZIndex(Rig.Overlay(text)) > 0);
        Assert.Equal((0, PageOverlay.UprightBounds(placed, rotation)), rig.Stand.Reveals.Last());

        Keyboard.ClearFocus();

        AssertDropped(text, box);
        return Task.CompletedTask;
    });

    [Fact]
    public Task AtViewZeroNothingIsTurnedOrMoved() => Sta.Run(() =>
    {
        using var rig = new Rig(0);
        var text = rig.Control("name");

        Assert.True(text.Focus());

        AssertDropped(text, rig.Box(Name));
        Assert.Equal((0, rig.Box(Name)), rig.Stand.Reveals.Last());
        return Task.CompletedTask;
    });

    [Fact]
    public Task TextTypedWhileTurnedIsEnteredOnBlurAndByFlush() => Sta.Run(() =>
    {
        using var rig = new Rig(90);
        var text = (TextBox)rig.Control("name");
        text.Focus();

        text.Text = "Ana";
        rig.Layer.Flush();
        Assert.Equal([("name", (string?)"Ana")], rig.Entered);

        text.Text = "Ana Maria";
        Keyboard.ClearFocus();
        Assert.Equal(("name", (string?)"Ana Maria"), rig.Entered.Last());
        return Task.CompletedTask;
    });

    [Fact]
    public Task FocusMovingToAnotherFieldOfThePageLeavesItRaisedAndTheOldOneReset() => Sta.Run(() =>
    {
        using var rig = new Rig(90);
        var first = rig.Control("name");
        var second = rig.Control("code");
        first.Focus();

        second.Focus();

        AssertIdle(first, rig.Box(Name));
        Assert.IsType<RotateTransform>(Rig.Frame(second).RenderTransform);
        Assert.Null(Rig.Host(second).Clip);
        Assert.True(Panel.GetZIndex(Rig.Host(second)) > 0);
        Assert.True(Panel.GetZIndex(Rig.Overlay(second)) > 0);

        Keyboard.ClearFocus();

        AssertDropped(second, rig.Box(Code));
        return Task.CompletedTask;
    });

    [Fact]
    public Task CheckBoxesAreNeverTurnedOrMoved() => Sta.Run(() =>
    {
        using var rig = new Rig(90);
        var box = rig.Control("agree");

        box.Focus();

        AssertDropped(box, rig.Box(new PdfRect(60, 580, 74, 594)));
        return Task.CompletedTask;
    });

    [Fact]
    public Task ChoicesStandUprightWhileFocusedAndKeepTheTurnOnInnerFocus() => Sta.Run(() =>
    {
        using var rig = new Rig(270);
        var list = rig.Control("langs");
        var combo = (ComboBox)rig.Control("city");

        combo.Focus();
        Assert.IsType<RotateTransform>(Rig.Frame(combo).RenderTransform);
        Assert.Equal(1.0, combo.Opacity);
        int reveals = rig.Stand.Reveals.Count;
        combo.IsDropDownOpen = true;
        combo.IsDropDownOpen = false;
        Assert.IsType<RotateTransform>(Rig.Frame(combo).RenderTransform);
        Assert.Equal(reveals, rig.Stand.Reveals.Count);

        list.Focus();
        Assert.IsType<RotateTransform>(Rig.Frame(list).RenderTransform);
        Assert.Equal(1.0, list.Opacity);

        Keyboard.ClearFocus();
        Assert.Equal(0.0, list.Opacity);
        Assert.Equal(0.0, combo.Opacity);
        return Task.CompletedTask;
    });

    [Fact]
    public Task TheRaisedLayerOutranksTheNextPagesLayerInThePageSurface() => Sta.Run(() =>
    {
        var document = PdfDocument.Open(FormPdfs.Standard());
        var form = PdfForm.Read(document, new FakeFonts());
        form.AddField(new FieldSpec(FieldKind.Text, "second", 1, new PdfRect(60, 640, 300, 660)));
        using var rig = new Rig(90, document.SaveRewrite(), surface: true);
        var text = rig.Control("name");
        var next = rig.Viewer.Overlay(1);

        text.Focus();

        Assert.True(Panel.GetZIndex(Rig.Overlay(text)) > Panel.GetZIndex(next));
        Keyboard.ClearFocus();
        Assert.Equal(Panel.GetZIndex(next), Panel.GetZIndex(Rig.Overlay(text)));
        return Task.CompletedTask;
    });

    [Theory]
    [InlineData(90)]
    [InlineData(270)]
    public Task TheFirstPressOnAnIdleTurnedFieldOnlyFocusesIt(int rotation) => Sta.Run(() =>
    {
        using var rig = new Rig(rotation);
        var text = rig.Control("name");

        Assert.True(Rig.Press(text));

        Assert.True(text.IsKeyboardFocusWithin);
        Assert.IsType<RotateTransform>(Rig.Frame(text).RenderTransform);
        Assert.False(Rig.Press(text));
        return Task.CompletedTask;
    });

    [Fact]
    public Task AtViewZeroAPressIsLeftToTheControl() => Sta.Run(() =>
    {
        using var rig = new Rig(0);
        var text = rig.Control("name");

        Assert.False(Rig.Press(text));
        Assert.False(text.IsKeyboardFocusWithin);
        return Task.CompletedTask;
    });

    [Fact]
    public Task TheFirstPressOnAnIdleListSelectsNothing() => Sta.Run(() =>
    {
        using var rig = new Rig(90);
        var list = (ListBox)rig.Control("langs");

        Assert.True(Rig.Press(list));

        Assert.Empty(rig.Chosen);
        Assert.True(list.IsKeyboardFocusWithin);
        Assert.Equal(1.0, list.Opacity);
        list.SelectedIndex = 1;
        Assert.Equal([("langs", 1)], rig.Chosen);
        return Task.CompletedTask;
    });

    [Fact]
    public Task KeyboardFocusIsNotSwallowedAndTurnsAtOnce() => Sta.Run(() =>
    {
        using var rig = new Rig(180);
        var combo = rig.Control("city");

        Assert.True(combo.Focus());

        Assert.IsType<RotateTransform>(Rig.Frame(combo).RenderTransform);
        return Task.CompletedTask;
    });

    private static void RaiseMenuOpening(FrameworkElement control)
    {
        var args = (ContextMenuEventArgs)Activator.CreateInstance(typeof(ContextMenuEventArgs), System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance, null, [control, true], null)!;
        args.RoutedEvent = FrameworkElement.ContextMenuOpeningEvent;
        control.RaiseEvent(args);
    }

    private static IEnumerable<ContextMenu> OpenMenus(DependencyObject parent)
    {
        if (parent is ContextMenu menu) yield return menu;
        if (parent is not Visual) yield break;
        for (int i = 0; i < VisualTreeHelper.GetChildrenCount(parent); i++)
        {
            foreach (var inner in OpenMenus(VisualTreeHelper.GetChild(parent, i))) yield return inner;
        }
    }

    [Fact]
    public Task ATextFieldStaysTurnedUnderItsOwnMenuAndTurnsBackWhenTheMenuIsGone() => Sta.Run(async () =>
    {
        using var rig = new Rig(90);
        var text = rig.Control("name");
        var frame = Rig.Frame(text);
        text.Focus();

        RaiseMenuOpening(text);
        await Task.Delay(100);
        Assert.True(text.IsKeyboardFocusWithin);
        Assert.IsType<RotateTransform>(frame.RenderTransform);

        foreach (PresentationSource source in PresentationSource.CurrentSources)
        {
            if (source.RootVisual is Window || source.RootVisual is null) continue;
            foreach (var menu in OpenMenus(source.RootVisual).ToList()) menu.IsOpen = false;
        }
        Keyboard.ClearFocus();
        await Task.Delay(100);

        AssertDropped(text, rig.Box(Name));
    });

    [Fact]
    public Task AListThatSawAMenuOpenStillTurnsBackWhenItLosesTheKeyboard() => Sta.Run(() =>
    {
        using var rig = new Rig(90);
        var list = rig.Control("langs");
        list.Focus();

        RaiseMenuOpening(list);
        Keyboard.ClearFocus();

        AssertDropped(list, rig.Box(new PdfRect(60, 420, 200, 490)));
        return Task.CompletedTask;
    });

    // Tab as the keyboard would raise it, on the control that has the keyboard.
    private static void PressTab(FrameworkElement control)
    {
        var key = new KeyEventArgs(Keyboard.PrimaryDevice, PresentationSource.FromVisual(control), 0, Key.Tab)
        {
            RoutedEvent = Keyboard.PreviewKeyDownEvent,
            Source = control,
        };
        control.RaiseEvent(key);
    }

    // The step Shift+Tab takes, called directly since a test cannot hold Shift down.
    private static bool Step(FillLayer layer, FrameworkElement control, int step)
    {
        var pages = (System.Collections.IDictionary)typeof(FillLayer).GetField("_pages", System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance)!.GetValue(layer)!;
        foreach (System.Collections.DictionaryEntry entry in pages)
        {
            var slots = (System.Collections.IEnumerable)entry.Value!.GetType().GetField("Item2")!.GetValue(entry.Value)!;
            foreach (var slot in slots)
            {
                if (!ReferenceEquals(slot.GetType().GetProperty("Control")!.GetValue(slot), control)) continue;
                return (bool)typeof(FillLayer).GetMethod("Cross", System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance)!.Invoke(layer, [entry.Key, slot, step])!;
            }
        }
        throw new InvalidOperationException("no such slot");
    }

    [Fact]
    public Task TabWalksThePagesListInsteadOfTheVisualOrderOnATurnedView() => Sta.Run(() =>
    {
        using var rig = new Rig(90);
        var name = rig.Control("name");
        var code = rig.Control("code");
        var agree = rig.Control("agree");
        name.Focus();

        PressTab(name);
        Assert.True(code.IsKeyboardFocusWithin);
        PressTab(code);
        Assert.True(agree.IsKeyboardFocusWithin);

        Assert.True(Step(rig.Layer, agree, -1));
        Assert.True(code.IsKeyboardFocusWithin);
        Assert.True(Step(rig.Layer, code, -1));
        Assert.True(name.IsKeyboardFocusWithin);
        Assert.False(Step(rig.Layer, name, -1));
        return Task.CompletedTask;
    });

    [Fact]
    public Task TabCrossesToTheNextPageFromItsLastField() => Sta.Run(() =>
    {
        var document = PdfDocument.Open(FormPdfs.Standard());
        var form = PdfForm.Read(document, new FakeFonts());
        form.AddField(new FieldSpec(FieldKind.Text, "second", 1, new PdfRect(60, 640, 300, 660)));
        using var rig = new Rig(90, document.SaveRewrite());
        var last = rig.Control("langs");
        last.Focus();

        PressTab(last);

        Assert.True(rig.Control("second").IsKeyboardFocusWithin);
        Assert.True(Step(rig.Layer, rig.Control("second"), -1));
        Assert.True(last.IsKeyboardFocusWithin);
        return Task.CompletedTask;
    });

    [Fact]
    public Task ARebuiltFormKeepsTheFocusedFieldRaisedWhateverOrderTheEventsRunIn() => Sta.Run(async () =>
    {
        using var rig = new Rig(90);
        rig.Control("name").Focus();

        var form = FormPdfs.Read(rig.Tab);
        form.AddField(new FieldSpec(FieldKind.Text, "extra", 0, new PdfRect(60, 300, 200, 320)));
        rig.Layer.Show(form, true);
        await Task.Delay(100);

        var text = rig.Control("name");
        Assert.True(text.IsKeyboardFocusWithin);
        Assert.IsType<RotateTransform>(Rig.Frame(text).RenderTransform);
        Assert.Null(Rig.Host(text).Clip);
        Assert.True(Panel.GetZIndex(Rig.Host(text)) > 0);
        Assert.True(Panel.GetZIndex(Rig.Overlay(text)) > 0);

        Keyboard.ClearFocus();
        AssertDropped(text, rig.Box(Name));
    });
}
