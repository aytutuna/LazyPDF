using System.Text;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Automation.Text;
using LazyPDF.App.Documents;
using LazyPDF.App.Viewer;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// The Text pattern only reads and moves the selection: nothing a client does is an edit of the file.
[Collection("Application")]
public sealed class PageTextEditStateTests
{
    [Fact]
    public Task AClientRunLeavesTheEditStateOfTheTabAlone() => Sta.Run(async () =>
    {
        using var tab = new DocumentTab(PdfEditSession.Open(Pdfs.Text(3)), new FakeRenderer(), null, "a.pdf");
        PdfAttachments.Add(tab.Document, "notes.txt", Encoding.UTF8.GetBytes("hello"));
        tab.Commit("Attach");
        var viewer = new PageViewer(null);
        viewer.Show(tab);
        viewer.Measure(new Size(800, 600));
        viewer.Arrange(new Rect(0, 0, 800, 600));
        viewer.UpdateLayout();
        ITextHost host = viewer;
        await Sta.Until(() => Enumerable.Range(0, tab.PageCount).All(p => host.Peek(p) is not null));
        var peer = (PageSurfacePeer)UIElementAutomationPeer.CreatePeerForElement(viewer.Surface);
        var provider = (PageTextProvider)peer.GetPattern(PatternInterface.Text)!;
        int revision = tab.Revision;
        bool dirty = tab.IsDirty;

        var range = provider.DocumentRange;
        range.Move(TextUnit.Word, 3);
        range.ExpandToEnclosingUnit(TextUnit.Line);
        range.Select();
        var place = provider.DocumentRange;
        place.MoveEndpointByRange(TextPatternRangeEndpoint.End, place, TextPatternRangeEndpoint.Start);
        place.Move(TextUnit.Character, 4);
        place.Select();
        provider.DocumentRange.FindText("Page 2", false, true)!.Select();
        provider.DocumentRange.ScrollIntoView(false);
        provider.GetSelection();
        provider.GetVisibleRanges();

        Assert.Equal(revision, tab.Revision);
        Assert.Equal(dirty, tab.IsDirty);
        Assert.Equal("Attach", tab.Session.UndoLabel);
        Assert.Null(tab.Session.RedoLabel);
    });
}
