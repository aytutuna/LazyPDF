using LazyPDF.Core;
using Xunit;
using static LazyPDF.Core.Tests.AnnotationFixtures;

namespace LazyPDF.Core.Tests;

public class FormFlattenTests
{
    private static PdfForm Filled(string acroEntries = "")
    {
        var form = PdfForm.Read(FormFixtures.Open(acroEntries));
        form.SetValues([new("name", "Ada Lovelace"), new("agree", "Yes"), new("choice", "b"), new("city", "Izmir"), new("code", "123")]);
        return form;
    }

    private static string PageText(PdfDocument document)
    {
        using var pig = UglyToad.PdfPig.PdfDocument.Open(document.SaveRewrite());
        return pig.GetPage(1).Text;
    }

    [Fact]
    public void FlatteningEverythingLeavesTextOnThePageAndNoForm()
    {
        var form = Filled();

        int burned = form.Flatten();

        Assert.Equal(9, burned);
        Assert.Empty(form.Fields);
        Assert.Null(form.AcroForm);
        Assert.Empty(form.Document.Array(form.Document.Pages[0].Dictionary, "Annots")!.Items);
        string text = PageText(form.Document);
        Assert.Contains("Ada Lovelace", text);
        Assert.Contains("Izmir", text);
        var reopened = Reopen(form.Document);
        Assert.Empty(PdfForm.Read(reopened).Fields);
        Assert.Empty(PdfAnnotations.ReadAll(reopened));
    }

    [Fact]
    public void FlatteningSomeFieldsKeepsTheRest()
    {
        var form = Filled();

        int burned = form.Flatten([form.Find("name")!, form.Find("choice")!]);

        Assert.Equal(3, burned);
        Assert.Null(form.Find("name"));
        Assert.Null(form.Find("choice"));
        Assert.NotNull(form.Find("city"));
        Assert.NotNull(form.AcroForm);
        Assert.DoesNotContain(form.Document.Array(form.AcroForm, "Fields")!.Items, i => form.Document.Resolve(i) is PdfDictionary d && PdfText.Read(form.Document, d, "T") is "name" or "choice");
        Assert.Contains("Ada Lovelace", PageText(form.Document));
        var reopened = PdfForm.Read(Reopen(form.Document));
        Assert.Equal(new[] { "agree", "bio", "city", "code", "langs", "secret", "sig" }, reopened.Fields.Select(f => f.Name).Order());
    }

    [Fact]
    public void HiddenWidgetsAreDroppedWithoutALeftoverAnnotation()
    {
        var form = Filled();
        form.Find("name")!.Widgets[0].Dictionary["F"] = new PdfNumber((long)AnnotationFlags.Hidden);

        form.Flatten();

        Assert.DoesNotContain("Ada Lovelace", PageText(form.Document));
        Assert.Empty(form.Document.Array(form.Document.Pages[0].Dictionary, "Annots")!.Items);
    }

    [Fact]
    public void StaleAppearancesAreDrawnAgainWhenTheFormSaysSo()
    {
        var form = PdfForm.Read(FormFixtures.Open("/NeedAppearances true"));
        form.Find("name")!.Dictionary["V"] = PdfText.ToObject("typed by another program");
        form.Refresh();

        form.Flatten([form.Find("name")!]);

        Assert.Contains("typed by another program", PageText(form.Document));
    }

    [Fact]
    public void FieldsWithoutAnAppearanceAreDrawnBeforeTheyAreBurned()
    {
        var form = PdfForm.Read(FormFixtures.Open());
        form.Find("bio")!.Dictionary["V"] = PdfText.ToObject("set without drawing");
        form.Refresh();

        form.Flatten();

        Assert.Contains("set without drawing", PageText(form.Document));
    }

    [Fact]
    public void FlatteningAStaticXfaFormRemovesTheXfa()
    {
        var form = Filled("/XFA [(template) 12 0 R]");

        form.Flatten();

        Assert.False(form.Document.HasXfa);
        Assert.True(form.XfaRemoved);
    }

    [Fact]
    public void FlattenedFormsKeepAnOtherPageUntouched()
    {
        var form = PdfForm.Read(AnnotationFixtures.Blank());
        form.AddField(new FieldSpec(FieldKind.Text, "p1", 0, new PdfRect(50, 700, 250, 720)) { Value = "one" });
        form.AddField(new FieldSpec(FieldKind.Text, "p2", 1, new PdfRect(50, 700, 250, 720)) { Value = "two" });

        Assert.Equal(2, form.Flatten());

        using var pig = UglyToad.PdfPig.PdfDocument.Open(form.Document.SaveRewrite());
        Assert.Contains("one", pig.GetPage(1).Text);
        Assert.Contains("two", pig.GetPage(2).Text);
    }
}
