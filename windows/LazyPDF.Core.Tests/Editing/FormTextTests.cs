using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

// Text inside a form XObject: edited in place when nothing else uses the form, in a copy when something does.
public class FormTextTests
{
    private const string FormContent = "BT /F1 12 Tf 10 50 Td (Form text here) Tj ET";
    private const string FormDictionary = "/Type /XObject /Subtype /Form /BBox [0 0 300 100] /Resources <</Font <</F1 5 0 R>>>>";

    private static byte[] Pages(int pageCount, string pageContent, string? sharedResources = null)
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        var kids = string.Join(" ", Enumerable.Range(0, pageCount).Select(i => $"{10 + i} 0 R"));
        pdf.Obj(2, $"<</Type /Pages /Kids [{kids}] /Count {pageCount} /MediaBox [0 0 600 800]>>");
        pdf.Obj(5, EditKit.Helvetica);
        pdf.Stream(7, FormDictionary, FormContent);
        for (int i = 0; i < pageCount; i++)
        {
            string resources = sharedResources is null ? "/Resources <</XObject <</Fm1 7 0 R>>>>" : "/Resources 9 0 R";
            pdf.Obj(10 + i, $"<</Type /Page /Parent 2 0 R /Contents {20 + i} 0 R {resources}>>");
            pdf.Stream(20 + i, "", pageContent);
        }
        if (sharedResources is not null) pdf.Obj(9, sharedResources);
        pdf.Obj(3, "null");
        pdf.Obj(4, "null");
        pdf.Obj(6, "null");
        pdf.Obj(8, "null");
        return pdf.Finish();
    }

    private static string FormText(PdfEditSession session, int page, int index = 0)
    {
        var text = TextPage.Create(session.Document, session.Document.Pages[page]);
        return text.Lines[index].Text;
    }

    [Fact]
    public void AFormOnlyOneUserPaintsIsEditedInPlace()
    {
        var session = PdfEditSession.Open(Pages(1, "q 1 0 0 1 50 600 cm /Fm1 Do Q"));
        string page = EditKit.Latin(session);
        var result = new PageEditor(session, 0).ReplaceText(EditKit.Find(session, "text"), "word");
        Assert.True(result.Done, result.Problem);
        Assert.Equal("Form word here", FormText(session, 0));
        Assert.Equal(page, EditKit.Latin(session));
        var xobjects = session.Document.Dict(session.Document.Pages[0].Resources, "XObject")!;
        Assert.Equal(7, ((PdfReference)xobjects["Fm1"]!).Number);
    }

    [Fact]
    public void AFormPaintedTwiceIsCopiedForTheOneThatWasEdited()
    {
        var session = PdfEditSession.Open(Pages(1, "q 1 0 0 1 50 600 cm /Fm1 Do Q q 1 0 0 1 50 400 cm /Fm1 Do Q"));
        var editor = new PageEditor(session, 0);
        var top = editor.Text.Lines.OrderByDescending(l => l.Bounds.Top).First();
        var result = editor.ReplaceText(new TextRange(top.Range.Start + 5, top.Range.Start + 9), "word");
        Assert.True(result.Done, result.Problem);
        var lines = TextPage.Create(session.Document, session.Document.Pages[0]).Lines.OrderByDescending(l => l.Bounds.Top).Select(l => l.Text).ToList();
        Assert.Equal(["Form word here", "Form text here"], lines);
        var xobjects = session.Document.Dict(session.Document.Pages[0].Resources, "XObject")!;
        Assert.Equal(7, ((PdfReference)xobjects["Fm1"]!).Number);
        Assert.Equal(2, xobjects.Count);
        Assert.Contains("Form word here", EditKit.Pig(session));
        Assert.Contains("Form text here", EditKit.Pig(session));
    }

    [Fact]
    public void AFormTwoPagesShareIsCopiedAndTheOtherPageKeepsItsText()
    {
        var session = PdfEditSession.Open(Pages(2, "q 1 0 0 1 50 600 cm /Fm1 Do Q"));
        var result = new PageEditor(session, 0).ReplaceText(EditKit.Find(session, "text"), "word");
        Assert.True(result.Done, result.Problem);
        Assert.Equal("Form word here", FormText(session, 0));
        Assert.Equal("Form text here", FormText(session, 1));
    }

    [Fact]
    public void ResourcesTwoPagesShareAreNotChangedUnderThem()
    {
        var session = PdfEditSession.Open(Pages(2, "q 1 0 0 1 50 600 cm /Fm1 Do Q", "<</XObject <</Fm1 7 0 R>>>>"));
        var result = new PageEditor(session, 0).ReplaceText(EditKit.Find(session, "text"), "word");
        Assert.True(result.Done, result.Problem);
        Assert.Equal("Form word here", FormText(session, 0));
        Assert.Equal("Form text here", FormText(session, 1));
    }

    [Fact]
    public void ObjectsInAFormMoveWithAMatrixInTheForm()
    {
        var session = PdfEditSession.Open(Pages(1, "q 2 0 0 2 50 600 cm /Fm1 Do Q"));
        var editor = new PageEditor(session, 0);
        var block = Assert.IsType<TextObject>(Assert.Single(editor.Objects));
        Assert.Single(block.Forms);
        var before = EditKit.Glyphs(session);
        var result = editor.Move([block], 30, -10);
        Assert.True(result.Done);
        var after = EditKit.Glyphs(session);
        Assert.All(before.Zip(after), p =>
        {
            Assert.Equal(p.First.X + 30, p.Second.X, 2);
            Assert.Equal(p.First.Y - 10, p.Second.Y, 2);
        });
        Assert.Equal("Form text here", FormText(session, 0));
    }
}
