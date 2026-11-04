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
}
