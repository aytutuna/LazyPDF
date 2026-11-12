using LazyPDF.App.Documents;
using LazyPDF.Core;

namespace LazyPDF.App.Tests;

/// <summary>Forms for the tests of the Forms tool, made with Core's own authoring.</summary>
internal static class FormPdfs
{
    /// <summary>A text file page with text "name" (required), "code" (at most 4 characters), check box "agree", radio group "plan", combo "city" and multi-select list "langs".</summary>
    public static byte[] Standard()
    {
        var document = PdfDocument.Open(Pdfs.Text(2));
        var form = PdfForm.Read(document, new FakeFonts());
        form.AddField(new FieldSpec(FieldKind.Text, "name", 0, new PdfRect(60, 640, 300, 660)) { Flags = FieldFlags.Required });
        form.AddField(new FieldSpec(FieldKind.Text, "code", 0, new PdfRect(60, 610, 160, 630)) { MaxLength = 4 });
        form.AddField(new FieldSpec(FieldKind.CheckBox, "agree", 0, new PdfRect(60, 580, 74, 594)));
        var plan = form.AddField(new FieldSpec(FieldKind.Radio, "plan", 0, new PdfRect(60, 550, 74, 564)));
        form.AddWidget(plan, 0, new PdfRect(120, 550, 134, 564));
        form.AddField(new FieldSpec(FieldKind.ComboBox, "city", 0, new PdfRect(60, 510, 200, 528)) { Options = [new("Ankara"), new("IZ", "Izmir")] });
        form.AddField(new FieldSpec(FieldKind.ListBox, "langs", 0, new PdfRect(60, 420, 200, 490)) { Flags = FieldFlags.MultiSelect, Options = [new("Turkish"), new("English"), new("German")] });
        return document.SaveRewrite();
    }

    /// <summary>The standard form on a page turned a quarter.</summary>
    public static byte[] Turned()
    {
        var document = PdfDocument.Open(Standard());
        document.Pages[0].Dictionary["Rotate"] = new PdfNumber(90);
        return document.SaveRewrite();
    }

    public static DocumentTab Tab(byte[]? pdf = null) =>
        new(PdfEditSession.Open(pdf ?? Standard()), new FakeRenderer(), null, "form.pdf");

    public static PdfForm Read(DocumentTab tab) => PdfForm.Read(tab.Document, new FakeFonts());

    /// <summary>A form that has fields and also XFA data.</summary>
    public static byte[] StaticXfa()
    {
        var document = PdfDocument.Open(Standard());
        var form = PdfForm.Read(document, new FakeFonts());
        form.AcroForm!["XFA"] = new PdfArray([PdfText.ToObject("template"), PdfText.ToObject("<xdp/>")]);
        return document.SaveRewrite();
    }

    /// <summary>A form that exists only as XFA.</summary>
    public static byte[] DynamicXfa() => System.Text.Encoding.ASCII.GetBytes(
        "%PDF-1.7\n1 0 obj\n<</Type /Catalog /Pages 2 0 R /AcroForm <</Fields [] /XFA [(template) 4 0 R]>>>>\nendobj\n" +
        "2 0 obj\n<</Type /Pages /Kids [3 0 R] /Count 1>>\nendobj\n" +
        "3 0 obj\n<</Type /Page /Parent 2 0 R /MediaBox [0 0 200 200]>>\nendobj\n" +
        "4 0 obj\n<</Length 6>>\nstream\n<xdp/>\nendstream\nendobj\n" +
        "trailer\n<</Root 1 0 R /Size 5>>\n%%EOF\n");

    /// <summary>A file whose open action runs JavaScript.</summary>
    public static byte[] Scripted() => System.Text.Encoding.ASCII.GetBytes(
        "%PDF-1.7\n1 0 obj\n<</Type /Catalog /Pages 2 0 R /OpenAction <</S /JavaScript /JS (this.dirty = true;)>>>>\nendobj\n" +
        "2 0 obj\n<</Type /Pages /Kids [3 0 R] /Count 1>>\nendobj\n" +
        "3 0 obj\n<</Type /Page /Parent 2 0 R /MediaBox [0 0 200 200]>>\nendobj\n" +
        "trailer\n<</Root 1 0 R /Size 4>>\n%%EOF\n");
}
