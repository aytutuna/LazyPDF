using System.Reflection;
using System.Windows;
using System.Windows.Input;
using LazyPDF.App.Documents;
using LazyPDF.App.Tools.EditContent;
using LazyPDF.App.Viewer;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests.Tools.Edit;

[Collection("Application")]
public sealed class EditSurfaceHandleTests
{
    private static PagePointer At(Point point) => new(0, point, point, Pressed: true, 1, ModifierKeys.None);

    [Fact]
    public Task AHandleOfTheSelectionIsHeldInSelectModeButNotInLinkMode() => Sta.Run(() =>
    {
        using var tab = new DocumentTab(PdfEditSession.Open(EditPdf.Make("20 20 100 50 re f")), new FakeRenderer(), null, "a.pdf");
        var surface = new EditSurface(FakeViewer.Create().Viewer, new PageEdits(tab, new FakeFonts(), new FakeCodec()));
        surface.Select(0, [0]);
        var bounds = (Rect)typeof(EditSurface).GetMethod("SelectionBounds", BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(surface, null)!;
        var corner = At(new Point(bounds.Left - 3, bounds.Top - 3));

        Assert.True(surface.HandleUnder(corner));

        surface.Mode = EditMode.Link;
        Assert.False(surface.HandleUnder(corner));
        return Task.CompletedTask;
    });
}
