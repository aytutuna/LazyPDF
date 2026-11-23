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
}
