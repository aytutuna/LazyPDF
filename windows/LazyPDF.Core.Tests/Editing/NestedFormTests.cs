using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

// A form inside a form: the copy of the inner one is pointed at from the outer one, which is edited in place or copied in turn.
public class NestedFormTests
{
    private static PdfEditSession Open(string outerContent, int pages = 1)
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        var kids = string.Join(" ", Enumerable.Range(0, pages).Select(i => $"{10 + i} 0 R"));
        pdf.Obj(2, $"<</Type /Pages /Kids [{kids}] /Count {pages} /MediaBox [0 0 600 800]>>");
        pdf.Obj(5, EditKit.Helvetica);
        pdf.Stream(7, "/Type /XObject /Subtype /Form /BBox [0 0 300 100] /Resources <</Font <</F1 5 0 R>>>>", "BT /F1 12 Tf 10 50 Td (Inner text) Tj ET");
        pdf.Stream(8, "/Type /XObject /Subtype /Form /BBox [0 0 600 800] /Resources <</XObject <</In 7 0 R>>>>", outerContent);
        for (int i = 0; i < pages; i++)
        {
            pdf.Obj(10 + i, $"<</Type /Page /Parent 2 0 R /Contents {30 + i} 0 R /Resources <</XObject <</Out 8 0 R>>>>>>");
            pdf.Stream(30 + i, "", "q 1 0 0 1 100 500 cm /Out Do Q");
        }
        return PdfEditSession.Open(pdf.Finish());
    }

    private static List<string> Rows(PdfEditSession session, int page = 0) =>
        [.. TextPage.Create(session.Document, session.Document.Pages[page]).Lines.OrderByDescending(l => l.Bounds.Top).Select(l => l.Text)];

    [Fact]
    public void AChainOfSingleUsesIsEditedInPlace()
    {
        var session = Open("q 1 0 0 1 20 20 cm /In Do Q");
        var editor = new PageEditor(session, 0);
        var block = Assert.IsType<TextObject>(Assert.Single(editor.Objects));
        Assert.Equal(2, block.Forms.Count);
        Assert.True(editor.ReplaceText(editor.Text.Lines[0].Range, "Changed").Done);
        Assert.Equal(["Changed"], Rows(session));
        var xobject = session.Document.Dict(session.Document.Pages[0].Resources, "XObject")!;
        Assert.Equal(8, ((PdfReference)xobject["Out"]!).Number);
        Assert.Equal(1, xobject.Count);
    }

    [Fact]
    public void AnInnerFormUsedTwiceIsCopiedForTheOneEdited()
    {
        var session = Open("q 1 0 0 1 20 20 cm /In Do Q q 1 0 0 1 20 220 cm /In Do Q");
        var editor = new PageEditor(session, 0);
        var top = editor.Text.Lines.OrderByDescending(l => l.Bounds.Top).First();
        Assert.True(editor.ReplaceText(top.Range, "Changed").Done);
        Assert.Equal(["Changed", "Inner text"], Rows(session));
        Assert.Contains("Inner text", EditKit.Pig(session));
        Assert.Contains("Changed", EditKit.Pig(session));
    }

    [Fact]
    public void BothLevelsSharedBetweenPagesAreCopied()
    {
        var session = Open("q 1 0 0 1 20 20 cm /In Do Q", pages: 2);
        Assert.True(new PageEditor(session, 0).ReplaceText(new PageEditor(session, 0).Text.Lines[0].Range, "Changed").Done);
        Assert.Equal(["Changed"], Rows(session, 0));
        Assert.Equal(["Inner text"], Rows(session, 1));
        Assert.True(session.Undo());
        Assert.Equal(["Inner text"], Rows(session, 0));
    }
}
