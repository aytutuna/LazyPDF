using System.Reflection;
using System.Windows;
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
}
