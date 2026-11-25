using System.Reflection;
using System.Windows;
using System.Windows.Input;
using LazyPDF.App.Tools.Forms;
using LazyPDF.App.Viewer;
using Xunit;

namespace LazyPDF.App.Tests;

[Collection("Application")]
public sealed class FieldToolHandleTests
{
    private static (FormsPanel Panel, IPagePointerTool Tool) Attached(LazyPDF.App.Documents.DocumentTab tab)
    {
        var panel = new FormsPanel();
        panel.Attach(tab, FakeViewer.Create().Viewer, new RecordingHost());
        return (panel, (IPagePointerTool)typeof(FormsPanel).GetField("_tool", BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(panel)!);
    }

    [Fact]
    public Task APickedFieldHoldsItsHandlesJustPastItsEdgeAndTwoPickedHoldNone() => Sta.Run(() =>
    {
        using var tab = FormPdfs.Tab();
        var (panel, tool) = Attached(tab);
        panel.Select("name", 0);
        var (page, box) = panel.SelectedBox()!.Value;
        var corner = new Point(box.Left - 3, box.Top - 3);
        var press = new PagePointer(page, corner, corner, Pressed: true, 1, ModifierKeys.None);

        Assert.True(tool.HandleUnder(press));
        tool.Press(press);
        Assert.True(((FieldTool)tool).Dragging);
        tool.Cancel();

        panel.Pick([("name", 0, 0), ("code", 0, 0)]);
        var (_, primary) = panel.SelectedBox()!.Value;
        corner = new Point(primary.Left - 3, primary.Top - 3);
        Assert.False(tool.HandleUnder(new PagePointer(page, corner, corner, Pressed: true, 1, ModifierKeys.None)));
        return Task.CompletedTask;
    });
}
