using Xunit;

namespace LazyPDF.Core.Tests;

public class TextAnnotationOptionTests
{
    private static PdfDocument Annotated()
    {
        var document = PdfDocument.Open(IntegrationFiles.Form(1));
        var page = document.Pages[0];
        new PdfAnnotationWriter(document).AddFreeText(page, new PdfRect(40, 300, 240, 340), "comment text");
        PdfForm.Read(document).SetValue("f1", "typed value");
        return PdfDocument.Open(document.SaveRewrite());
    }

    [Fact]
    public void PageTextLeavesAnnotationsAndFieldsOutByDefault()
    {
        var document = Annotated();
        string text = TextPage.Create(document, document.Pages[0]).Text;
        Assert.Contains("Page 1 body text", text);
        Assert.DoesNotContain("comment", text);
        Assert.DoesNotContain("typed", text);
    }

    [Fact]
    public void TheOptionAddsTheirTextAtTheirPlaces()
    {
        var document = Annotated();
        var page = TextPage.Create(document, document.Pages[0], new TextPageOptions(IncludeAnnotations: true));
        Assert.Contains("Page 1 body text", page.Text);
        Assert.Contains("comment text", page.Text);
        Assert.Contains("typed value", page.Text);
        var field = page.Words.First(w => w.Text == "typed");
        Assert.InRange(field.Bounds.Left, 40, 240);
        Assert.InRange(field.Bounds.Bottom, 38, 62);
    }

    [Fact]
    public void AHiddenAnnotationAddsNothing()
    {
        var document = PdfDocument.Open(IntegrationFiles.Form(1));
        var note = new PdfAnnotationWriter(document).AddFreeText(document.Pages[0], new PdfRect(40, 300, 240, 340), "secret remark");
        note.Dictionary["F"] = new PdfNumber(2);
        var page = TextPage.Create(document, document.Pages[0], new TextPageOptions(IncludeAnnotations: true));
        Assert.DoesNotContain("secret", page.Text);
    }

    [Fact]
    public void AnAppearanceThatRunsOutOfOperationsMarksThePageTruncated()
    {
        // 220 x 220 x 220 operations, past the interpreter's 10,000,000.
        string Repeat(string op) => string.Concat(Enumerable.Repeat(op, 220));
        var document = TextTestPdf.Page(TextTestPdf.Line(100, 700, "body"), "/Font <</F1 5 0 R>>", "/Annots [8 0 R]", pdf =>
        {
            TextTestPdf.Font(pdf, 5);
            pdf.Obj(8, "<</Type /Annot /Subtype /Stamp /Rect [0 0 100 100] /AP <</N 9 0 R>>>>");
            pdf.Stream(9, "/Type /XObject /Subtype /Form /BBox [0 0 100 100] /Resources <</XObject <</B 10 0 R>>>>", Repeat("/B Do "));
            pdf.Stream(10, "/Type /XObject /Subtype /Form /BBox [0 0 100 100] /Resources <</XObject <</C 11 0 R>>>>", Repeat("/C Do "));
            pdf.Stream(11, "/Type /XObject /Subtype /Form /BBox [0 0 100 100]", Repeat("n "));
        });
        Assert.False(TextPage.Create(document, document.Pages[0]).IsTruncated);
        Assert.True(TextPage.Create(document, document.Pages[0], new TextPageOptions(IncludeAnnotations: true)).IsTruncated);
    }

    [Fact]
    public void TextWithAnnotationsIsRefusedWhereOperatorIndexesAreUsed()
    {
        var document = Annotated();
        var plain = TextPage.Create(document, document.Pages[0]);
        var shown = TextPage.Create(document, document.Pages[0], new TextPageOptions(IncludeAnnotations: true));

        Assert.False(plain.IncludesAnnotations);
        plain.RequirePageContent();
        Assert.True(shown.IncludesAnnotations);
        var e = Assert.Throws<InvalidOperationException>(shown.RequirePageContent);
        Assert.Equal(TextPageText.AnnotationsIncluded, e.Message);
    }
}
