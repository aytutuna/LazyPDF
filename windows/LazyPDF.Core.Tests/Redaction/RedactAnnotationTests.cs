using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class RedactAnnotationTests
{
    private static readonly PdfRect Hole = new(90, 480, 310, 520);

    private static PdfDocument Blank() => RedactionKit.Page("BT /F1 12 Tf 100 700 Td (page text) Tj ET");

    private static PdfAnnotation Note(PdfDocument document, PdfRect rect, string contents) =>
        new PdfAnnotationWriter(document).AddNote(document.Pages[0], rect, new AnnotationInfo("Reviewer", contents));

    private static RedactionMark Over() => RedactionMark.FromRect(0, Hole);

    [Fact]
    public void NoteUnderTheMarkGoesWithItsPopupAndRepliesAndOtherNotesStay()
    {
        using var document = Blank();
        var inside = Note(document, new PdfRect(100, 490, 120, 510), "secret remark");
        Note(document, new PdfRect(400, 100, 420, 120), "elsewhere");
        var popup = document.Add(new PdfDictionary
        {
            ["Type"] = new PdfName("Annot"), ["Subtype"] = new PdfName("Popup"), ["Rect"] = new PdfRect(500, 600, 600, 700).ToArray(), ["Parent"] = inside.Reference!,
        });
        inside.Dictionary["Popup"] = popup;
        document.Array(document.Pages[0].Dictionary, "Annots")!.Items.Add(popup);

        var result = new PdfRedactor(document).Apply([Over()]);
        using var output = RedactionKit.Open(result);
        var left = PdfAnnotations.Read(output, output.Pages[0]);
        Assert.Equal("elsewhere", Assert.Single(left).Contents);
        Assert.False(RedactionKit.Holds(result.Bytes, "secret remark"));
        Assert.Equal(1, result.Report.Annotations);
    }

    [Fact]
    public void LinkOverTheMarkIsRemoved()
    {
        using var document = Blank();
        new PdfAnnotationWriter(document).AddLink(document.Pages[0], new PdfRect(100, 490, 200, 510), new UriAction("https://example.com/secret"));
        var result = new PdfRedactor(document).Apply([Over()]);
        using var output = RedactionKit.Open(result);
        Assert.Empty(PdfAnnotations.Read(output, output.Pages[0]));
        Assert.False(RedactionKit.Holds(result.Bytes, "example.com/secret"));
    }

    [Fact]
    public void FieldWithItsValueGoesAndAnAcroFormWithNoFieldLeftGoesToo()
    {
        using var document = Blank();
        var form = PdfForm.Read(document);
        form.AddField(new FieldSpec(FieldKind.Text, "name", 0, new PdfRect(100, 490, 300, 510)) { Value = "Jane Doe secret" });
        Assert.NotNull(document.Dict(document.Catalog, "AcroForm"));
        var result = new PdfRedactor(document).Apply([Over()]);
        using var output = RedactionKit.Open(result);
        Assert.Null(output.Dict(output.Catalog, "AcroForm"));
        Assert.Empty(PdfAnnotations.Read(output, output.Pages[0]));
        Assert.False(RedactionKit.Holds(result.Bytes, "Jane Doe secret"));
        Assert.Equal(1, result.Report.Fields);
    }

    [Fact]
    public void OtherFieldsKeepTheFormAlive()
    {
        using var document = Blank();
        var form = PdfForm.Read(document);
        form.AddField(new FieldSpec(FieldKind.Text, "name", 0, new PdfRect(100, 490, 300, 510)) { Value = "gone value" });
        form.AddField(new FieldSpec(FieldKind.Text, "city", 0, new PdfRect(100, 300, 300, 320)) { Value = "kept value" });
        var result = new PdfRedactor(document).Apply([Over()]);
        using var output = RedactionKit.Open(result);
        var fields = PdfForm.Read(output).Fields;
        var left = Assert.Single(fields);
        Assert.Equal("city", left.Name);
        Assert.Equal("kept value", left.Value);
        Assert.False(RedactionKit.Holds(result.Bytes, "gone value"));
    }

    [Fact]
    public void ARadioGroupWithOneButtonUnderTheMarkLeavesNothing()
    {
        using var document = Blank();
        var form = PdfForm.Read(document);
        form.AddField(new FieldSpec(FieldKind.Radio, "choice", 0, new PdfRect(100, 490, 120, 510)) { ExportValue = "A" });
        form.AddWidget(form.Find("choice")!, 0, new PdfRect(400, 100, 420, 120), "B");
        var result = new PdfRedactor(document).Apply([Over()]);
        using var output = RedactionKit.Open(result);
        Assert.Empty(PdfForm.Read(output).Fields);
        Assert.Empty(PdfAnnotations.Read(output, output.Pages[0]));
    }

    [Fact]
    public void MarkAnnotationsDisappearWhenApplied()
    {
        using var document = RedactionKit.Page("BT /F1 12 Tf 100 700 Td (secret words) Tj ET BT /F1 12 Tf 100 600 Td (public) Tj ET");
        var redactor = new PdfRedactor(document);
        var found = RedactionKit.MarksOf(document, 0, "secret words");
        var added = redactor.AddMarks(found, new AnnotationInfo("Reviewer"));
        Assert.Single(added);
        Assert.Equal(AnnotationType.Redact, added[0].Type);
        Assert.Equal("secret words", RedactionKit.Text(document)[..12]);

        var marks = redactor.ReadMarks();
        var mark = Assert.Single(marks);
        Assert.Equal(0, mark.Page);
        var result = redactor.ApplyMarked();
        using var output = RedactionKit.Open(result);
        Assert.Equal("public", RedactionKit.Text(output));
        Assert.Empty(PdfAnnotations.Read(output, output.Pages[0]));
        Assert.Equal(1, result.Report.Annotations);
    }

    [Fact]
    public void MarkingAloneRemovesNothing()
    {
        using var document = RedactionKit.Page("BT /F1 12 Tf 100 700 Td (secret) Tj ET");
        new PdfRedactor(document).AddMarks(RedactionKit.MarksOf(document, 0, "secret"));
        Assert.Equal("secret", RedactionKit.Text(document));
        var bytes = document.SaveRewrite();
        using var reopened = RedactionKit.Reopen(bytes);
        Assert.Equal("secret", RedactionKit.Text(reopened));
        Assert.Single(new PdfRedactor(reopened).ReadMarks());
    }
}
