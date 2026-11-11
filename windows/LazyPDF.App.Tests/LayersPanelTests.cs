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

    private static List<(PdfReference Layer, bool On)> SpaceOnFirstRow(bool locked, out bool checkedAfter, out bool checkedBefore)
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

        tree.RaiseEvent(new KeyEventArgs(Keyboard.PrimaryDevice, System.Windows.PresentationSource.FromVisual(panel)!, 0, Key.Space) { RoutedEvent = Keyboard.PreviewKeyDownEvent });

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
    public Task SpaceLeavesALockedLayer() => Sta.Run(() =>
    {
        var switched = SpaceOnFirstRow(true, out bool after, out bool before);

        Assert.Equal(before, after);
        Assert.Empty(switched);
        return Task.CompletedTask;
    });
}
