using System.Text;
using LazyPDF.Core;
using Xunit;
using static LazyPDF.Core.Tests.AnnotationFixtures;

namespace LazyPDF.Core.Tests;

public class FdfReviewTests
{
    [Fact]
    public void XfdfUsesItsOwnWordsForJustificationSymbolAndReplyType()
    {
        var read = PdfXfdf.Read("<xfdf xmlns=\"http://ns.adobe.com/xfdf/\"><annots><freetext page=\"0\" rect=\"1,1,50,50\" justification=\"centered\"/>"
            + "<caret page=\"0\" rect=\"1,1,5,5\" symbol=\"paragraph\"/><text page=\"0\" rect=\"1,1,5,5\" replyType=\"group\"/></annots></xfdf>");
        var d = read.Annotations.Select(a => a.Dictionary).ToList();
        Assert.Equal(1, ((PdfNumber)d[0]["Q"]!).Integer);
        Assert.Equal("P", ((PdfName)d[1]["Sy"]!).Value);
        Assert.Equal("Group", ((PdfName)d[2]["RT"]!).Value);

        string xml = Encoding.UTF8.GetString(PdfXfdf.Write(read));
        Assert.Contains("justification=\"centered\"", xml);
        Assert.Contains("symbol=\"paragraph\"", xml);
        Assert.Contains("replyType=\"group\"", xml);
    }

    [Fact]
    public void AReplyKeepsItsParentWhenTheParentIsAlreadyInTheDocument()
    {
        var document = Blank(1);
        var writer = new PdfAnnotationWriter(document);
        var note = writer.AddNote(document.Pages[0], new PdfRect(50, 100, 70, 120), new AnnotationInfo("A", "parent", null, DateTimeOffset.UnixEpoch));
        var target = Blank(1);
        PdfFdf.Import(target, PdfFdf.Read(PdfFdf.Write(PdfFdf.Export(document))));

        PdfComments.Reply(document, note, "later", "B", DateTimeOffset.UnixEpoch.AddHours(1));
        PdfFdf.Import(target, PdfFdf.Read(PdfFdf.Write(PdfFdf.Export(document))));

        var thread = Assert.Single(PdfComments.List(target));
        Assert.Single(thread.Replies);
    }
}
