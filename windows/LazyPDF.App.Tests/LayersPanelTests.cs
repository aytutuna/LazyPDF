using System.Reflection;
using System.Windows.Controls;
using System.Windows.Input;
using LazyPDF.App.Documents;
using LazyPDF.App.Panels.Layers;
using LazyPDF.App.Viewer;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

[Collection("Application")]
public sealed class LayersPanelTests
{
    private class LayerViewer : DispatchProxy
    {
        public LayerSet Set { get; set; } = new([], []);

        public List<(PdfReference Layer, bool On)> Switched { get; } = [];

        protected override object? Invoke(MethodInfo? method, object?[]? args)
        {
            if (method!.Name == "get_Layers") return Set;
            if (method.Name == "SetLayerVisible") Switched.Add(((PdfReference)args![0]!, (bool)args[1]!));
            return method.ReturnType == typeof(void) || !method.ReturnType.IsValueType ? null : Activator.CreateInstance(method.ReturnType);
        }
    }

    private static List<(PdfReference Layer, bool On)> SpaceOnFirstRow(bool locked, out bool checkedAfter, out bool checkedBefore, bool heldDown = false, List<string?>? raised = null)
    {
        using var tab = new DocumentTab(PdfEditSession.Open(LayeredPdf.Make()), new FakeRenderer(), null, "a.pdf", null);
        var layer = new PdfLayer(LayeredPdf.BlackBox, "Black box", true, locked, null);
        var viewer = DispatchProxy.Create<IDocumentViewer, LayerViewer>();
        var recorder = (LayerViewer)(object)viewer;
        recorder.Set = new LayerSet([layer], [new LayerNode(null, layer, [])]);
        var panel = new LayersSidePanel();
        panel.Attach(tab, viewer, new RecordingHost());
        var window = new System.Windows.Window { Content = panel, Width = 300, Height = 300 };
        window.Show();
        var tree = (TreeView)panel.FindName("Tree");
        tree.UpdateLayout();
        ((TreeViewItem)tree.ItemContainerGenerator.ContainerFromIndex(0)).IsSelected = true;
        var row = (LayerRow)tree.SelectedItem;
        checkedBefore = row.IsChecked;

        if (raised != null) row.PropertyChanged += (_, e) => raised.Add(e.PropertyName);

        var source = System.Windows.PresentationSource.FromVisual(panel)!;
        tree.RaiseEvent(new KeyEventArgs(Keyboard.PrimaryDevice, source, 0, Key.Space) { RoutedEvent = Keyboard.PreviewKeyDownEvent });
        if (heldDown)
        {
            var repeat = new KeyEventArgs(Keyboard.PrimaryDevice, source, 0, Key.Space) { RoutedEvent = Keyboard.PreviewKeyDownEvent };
            typeof(KeyEventArgs).GetField("_isRepeat", System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance)!.SetValue(repeat, true);
            tree.RaiseEvent(repeat);
        }

        checkedAfter = row.IsChecked;
        window.Close();
        return recorder.Switched;
    }

    [Fact]
    public Task SpaceSwitchesTheSelectedLayer() => Sta.Run(() =>
    {
        var switched = SpaceOnFirstRow(false, out bool after, out bool before);

        Assert.True(before);
        Assert.False(after);
        Assert.Equal([(LayeredPdf.BlackBox, false)], switched);
        return Task.CompletedTask;
    });

    [Fact]
    public Task HeldSpaceSwitchesTheLayerOnce() => Sta.Run(() =>
    {
        var raised = new List<string?>();
        var switched = SpaceOnFirstRow(false, out bool after, out _, heldDown: true, raised: raised);

        Assert.False(after);
        Assert.Single(switched);
        Assert.Single(raised, "IsChecked");
        return Task.CompletedTask;
    });

    [Fact]
    public Task SpaceLeavesALockedLayer() => Sta.Run(() =>
    {
        var switched = SpaceOnFirstRow(true, out bool after, out bool before);

        Assert.Equal(before, after);
        Assert.Empty(switched);
        return Task.CompletedTask;
    });

    [Fact]
    public Task LockedLayerHasATipAndAnUnlockedOneHasNone() => Sta.Run(() =>
    {
        var locked = new LayerRow("a", new PdfLayer(LayeredPdf.BlackBox, "a", true, true, null), []);
        var open = new LayerRow("b", new PdfLayer(LayeredPdf.BlackBox, "b", true, false, null), []);

        Assert.Equal(Loc.T("The file does not allow this layer to be shown or hidden."), locked.LockedTip);
        Assert.Null(open.LockedTip);
        return Task.CompletedTask;
    });

    [Fact]
    public Task UnlabelledGroupIsNamedGroup() => Sta.Run(() =>
    {
        using var tab = new DocumentTab(PdfEditSession.Open(LayeredPdf.Make()), new FakeRenderer(), null, "a.pdf", null);
        var layer = new PdfLayer(LayeredPdf.BlackBox, "Black box", true, false, null);
        var viewer = DispatchProxy.Create<IDocumentViewer, LayerViewer>();
        ((LayerViewer)(object)viewer).Set = new LayerSet([layer], [new LayerNode(" ", null, [new LayerNode(null, layer, [])])]);
        var panel = new LayersSidePanel();
        panel.Attach(tab, viewer, new RecordingHost());

        var rows = (List<LayerRow>)((TreeView)panel.FindName("Tree")).ItemsSource;

        Assert.Equal(Loc.T("Group"), rows[0].Name);
        return Task.CompletedTask;
    });
}
