using System.Windows.Controls;
using LazyPDF.App.Tests.Tools.Comment;
using LazyPDF.App.Tools.EditContent;
using Xunit;

namespace LazyPDF.App.Tests.Tools.Edit;

[Collection("Application")]
public sealed class InPlaceEditorTests
{
    private static TextBox Opened(bool lineBreaks)
    {
        var viewer = ViewerStandIn.Create(out var stand);
        var look = new EditorLook(new System.Windows.Media.FontFamily("Arial"), 12, System.Windows.Media.Colors.Black, false, false, LazyPDF.Core.TextAlignment.Left);
        new InPlaceEditor(viewer).Open(0, new System.Windows.Rect(10, 10, 100, 20), "", look, wrap: true, lineBreaks: lineBreaks);
        return Assert.IsType<TextBox>(Assert.Single(stand.Overlays[0].Children));
    }

    [Fact]
    public Task ANewBoxAcceptsReturn() => Sta.Run(() => { Assert.True(Opened(true).AcceptsReturn); return Task.CompletedTask; });

    [Fact]
    public Task ALineEditDoesNot() => Sta.Run(() => { Assert.False(Opened(false).AcceptsReturn); return Task.CompletedTask; });
}
