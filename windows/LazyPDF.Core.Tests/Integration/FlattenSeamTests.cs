using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class FlattenSeamTests
{
    private static PdfDocument Marked(int pages = 2)
    {
        var document = PdfDocument.Open(IntegrationFiles.Form(pages));
        var writer = new PdfAnnotationWriter(document);
        var info = new AnnotationInfo("tester", Date: new DateTimeOffset(2026, 3, 1, 9, 0, 0, TimeSpan.Zero));
        writer.AddTextMarkup(document.Pages[0], AnnotationType.Highlight, [MarkupQuad.FromRect(new PdfRect(40, 495, 200, 515))], info);
        writer.AddFreeText(document.Pages[0], new PdfRect(40, 300, 300, 340), "free text note", info: info);
        writer.AddStamp(document.Pages[0], new PdfRect(40, 200, 200, 260), "Approved", info);
        var form = PdfForm.Read(document);
        form.SetValues(new Dictionary<string, string?> { ["f1"] = "typed value", ["agree"] = "Yes" });
        return document;
    }

    private static void AssertFlat(PdfDocument document)
    {
        var bytes = document.SaveRewrite();
        var texts = IntegrationFiles.ReadBack(bytes);
        var again = PdfDocument.Open(bytes);
        Assert.Contains("typed value", texts[0]);
        Assert.Contains("free text note", texts[0]);
        Assert.Contains("Page 1 body text", texts[0]);
        Assert.Empty(PdfAnnotations.ReadAll(again));
        Assert.Null(again.Catalog["AcroForm"]);
        Assert.Empty(PdfForm.Read(again).Fields);
    }

    [Fact]
    public void FormThenAnnotationsLeavesNothingInteractive()
    {
        var document = Marked();
        Assert.True(PdfForm.Read(document).Flatten() >= 3);
        Assert.True(PdfAnnotationFlattener.FlattenAll(document) >= 3);
        AssertFlat(document);
    }

    [Fact]
    public void AnnotationsThenFormLeavesNothingInteractive()
    {
        var document = Marked();
        PdfAnnotationFlattener.FlattenAll(document);
        Assert.NotEmpty(PdfForm.Read(document).Fields);
        PdfForm.Read(document).Flatten();
        AssertFlat(document);
    }

    [Fact]
    public void FlatteningOneFieldKeepsTheOthersFillable()
    {
        var document = Marked();
        var form = PdfForm.Read(document);
        form.SetValue("f2", "second");
        Assert.Equal(1, form.Flatten([form.Find("f1")!]));

        var again = PdfForm.Read(PdfDocument.Open(document.SaveRewrite()));
        Assert.Null(again.Find("f1"));
        Assert.Equal("second", again.Find("f2")!.Value);
        Assert.NotNull(again.Find("agree"));
    }

    [Fact]
    public void FlattenedFileSurvivesSessionUndo()
    {
        var session = PdfEditSession.Open(IntegrationFiles.Form(2));
        PdfForm.Read(session.Document).SetValue("f1", "before flatten");
        Assert.True(session.Commit("fill"));
        PdfForm.Read(session.Document).Flatten();
        Assert.True(session.Commit("flatten"));
        Assert.Empty(PdfForm.Read(IntegrationFiles.Reopen(session)).Fields);

        Assert.True(session.Undo());
        var back = PdfForm.Read(IntegrationFiles.Reopen(session));
        Assert.Equal("before flatten", back.Find("f1")!.Value);
    }
}
