using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using LazyPDF.App.Tools.Forms;
using LazyPDF.App.Viewer;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// Push buttons whose action this tool cannot carry out still draw a control, and clicking it says why nothing happens.
[Collection("Application")]
public sealed class FillLayerButtonTests
{
    private static ToggleButton? Clicked(PdfAction action, List<string> said)
    {
        using var tab = FormPdfs.Tab(Pdfs.Text(1));
        var form = FormPdfs.Read(tab);
        var field = form.AddField(new FieldSpec(FieldKind.PushButton, "send", 0, new PdfRect(300, 640, 400, 664)) { Caption = "Send" });
        field.Widgets[0].Dictionary["A"] = PdfActions.ToObject(tab.Document, action);
        form = FormPdfs.Read(tab);

        var viewer = Stand.Create(tab, out var overlay);
        var layer = new FillLayer(viewer, (_, _) => true, (_, _) => true, _ => { }, _ => { }, said.Add);
        layer.Show(form, true);

        var button = Buttons(overlay).SingleOrDefault();
        // A person's click toggles the button before it raises Click.
        typeof(ButtonBase).GetMethod("OnClick", BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(button, null);
        return button;
    }

    private static IEnumerable<ToggleButton> Buttons(DependencyObject parent)
    {
        foreach (var child in LogicalTreeHelper.GetChildren(parent).OfType<DependencyObject>())
        {
            if (child is ToggleButton button) yield return button;
            foreach (var inner in Buttons(child)) yield return inner;
        }
    }

    [Fact]
    public Task SubmitButtonSaysItDoesNotSend() => Sta.Run(() =>
    {
        var said = new List<string>();
        var button = Clicked(new SubmitFormAction("https://x", 0, []), said);

        Assert.NotNull(button);
        Assert.False(button.IsChecked);
        Assert.Equal(["It sends the form to a web address, which Lazy PDF does not do. Save the file and send it yourself."], said);
        return Task.CompletedTask;
    });

    [Fact]
    public Task ScriptButtonSaysItDoesNotRun() => Sta.Run(() =>
    {
        var said = new List<string>();
        var button = Clicked(new JavaScriptAction("app.alert(1)"), said);

        Assert.NotNull(button);
        Assert.Equal(["It runs a script, which Lazy PDF does not do."], said);
        return Task.CompletedTask;
    });

    [Fact]
    public Task LaunchButtonSaysItDoesNotOpen() => Sta.Run(() =>
    {
        var said = new List<string>();
        Clicked(new LaunchAction("a.exe", null), said);

        Assert.Equal(["It opens another file or program, which Lazy PDF does not do."], said);
        return Task.CompletedTask;
    });

    [Fact]
    public Task ChangedActionRebuildsTheButton() => Sta.Run(() =>
    {
        var said = new List<string>();
        var followed = new List<PdfAction>();
        using var tab = FormPdfs.Tab(Pdfs.Text(1));
        var form = FormPdfs.Read(tab);
        var field = form.AddField(new FieldSpec(FieldKind.PushButton, "send", 0, new PdfRect(300, 640, 400, 664)) { Caption = "Send" });
        field.Widgets[0].Dictionary["A"] = PdfActions.ToObject(tab.Document, new SubmitFormAction("https://x", 0, []));
        form = FormPdfs.Read(tab);

        var viewer = Stand.Create(tab, out var overlay, followed.Add);
        var layer = new FillLayer(viewer, (_, _) => true, (_, _) => true, _ => { }, _ => { }, said.Add);
        layer.Show(form, true);
        var before = Buttons(overlay).Single();

        form.Find("send")!.Widgets[0].Dictionary["A"] = PdfActions.ToObject(tab.Document, new UriAction("https://y"));
        layer.Show(form, true);
        var after = Buttons(overlay).Single();
        after.RaiseEvent(new RoutedEventArgs(ButtonBase.ClickEvent));

        Assert.NotSame(before, after);
        Assert.Empty(said);
        Assert.Equal("https://y", Assert.IsType<UriAction>(Assert.Single(followed)).Uri);
        return Task.CompletedTask;
    });

    // A viewer with page 0 in view and an overlay for it, which is all the layer asks for.
    private class Stand : DispatchProxy
    {
        private PageGeometry _geometry = null!;
        private PageOverlay _overlay = null!;

        private Action<PdfAction>? _follow;

        public static IDocumentViewer Create(Documents.DocumentTab tab, out PageOverlay overlay, Action<PdfAction>? follow = null)
        {
            var viewer = Create<IDocumentViewer, Stand>();
            var stand = (Stand)(object)viewer;
            stand._follow = follow;
            stand._geometry = new PageGeometry(tab.Document.Pages[0]);
            overlay = stand._overlay = new PageOverlay(0, new Size(595, 842));
            return viewer;
        }

        private object? Follow(object? action)
        {
            _follow?.Invoke((PdfAction)action!);
            return null;
        }

        protected override object? Invoke(MethodInfo? method, object?[]? args) => method!.Name switch
        {
            "FollowAction" => Follow(args![0]),
            "get_VisiblePages" => new[] { 0 },
            "Overlay" => _overlay,
            "Geometry" => _geometry,
            _ when method.ReturnType == typeof(void) || !method.ReturnType.IsValueType => null,
            _ => Activator.CreateInstance(method.ReturnType),
        };
    }
}
