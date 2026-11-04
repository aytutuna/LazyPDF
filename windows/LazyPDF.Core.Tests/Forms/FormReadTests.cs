using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class FormReadTests
{
    [Fact]
    public void FieldsAreFoundWithKindsAndNames()
    {
        var form = PdfForm.Read(FormFixtures.Open());

        Assert.Equal(["name", "bio", "agree", "choice", "city", "langs", "code", "secret", "sig"], form.Fields.Select(f => f.Name));
        Assert.Equal(FieldKind.Text, form.Find("name")!.Kind);
        Assert.Equal(FieldKind.CheckBox, form.Find("agree")!.Kind);
        Assert.Equal(FieldKind.Radio, form.Find("choice")!.Kind);
        Assert.Equal(FieldKind.ComboBox, form.Find("city")!.Kind);
        Assert.Equal(FieldKind.ListBox, form.Find("langs")!.Kind);
        Assert.Equal(FieldKind.Signature, form.Find("sig")!.Kind);
        Assert.True(form.Find("bio")!.Has(FieldFlags.Multiline));
        Assert.True(form.Find("secret")!.Has(FieldFlags.Password));
        Assert.True(form.Find("code")!.Has(FieldFlags.Comb));
        Assert.Equal(6, form.Find("code")!.MaxLength);
        Assert.False(form.Find("sig")!.IsSigned);
    }

    [Fact]
    public void RadioButtonsAreWidgetsOfOneField()
    {
        var choice = PdfForm.Read(FormFixtures.Open()).Find("choice")!;

        Assert.Equal(["a", "b"], choice.Widgets.Select(w => w.OnState));
        Assert.All(choice.Widgets, w => Assert.Same(choice, w.Field));
        Assert.All(choice.Widgets, w => Assert.Equal(0, w.PageIndex));
        Assert.Equal("Off", choice.Value);
    }

    [Fact]
    public void OptionsKeepExportAndDisplayApart()
    {
        var city = PdfForm.Read(FormFixtures.Open()).Find("city")!;

        Assert.Equal([new FieldOption("Ankara"), new FieldOption("IZ", "Izmir"), new FieldOption("Bursa")], city.Options);
    }

    [Fact]
    public void ValuesAndAttributesAreInheritedThroughTheTree()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R /AcroForm <</Fields [10 0 R] /DA (/Helv 9 Tf 0 g) /Q 1>>>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 600 800]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Annots [12 0 R 13 0 R]>>");
        pdf.Obj(10, "<</T (person) /FT /Tx /Ff 2 /V (Ada) /Kids [11 0 R]>>");
        pdf.Obj(11, "<</T (address) /Parent 10 0 R /MaxLen 20 /Kids [12 0 R 13 0 R]>>");
        pdf.Obj(12, "<</Type /Annot /Subtype /Widget /Parent 11 0 R /Rect [0 0 100 20] /P 3 0 R>>");
        pdf.Obj(13, "<</Type /Annot /Subtype /Widget /Parent 11 0 R /Rect [0 30 100 50] /P 3 0 R>>");
        var form = PdfForm.Read(PdfDocument.Open(pdf.Finish()));

        var field = Assert.Single(form.Fields);
        Assert.Equal("person.address", field.Name);
        Assert.Equal("address", field.PartialName);
        Assert.Equal("Ada", field.Value);
        Assert.Equal(20, field.MaxLength);
        Assert.Equal(1, field.Alignment);
        Assert.Equal("/Helv 9 Tf 0 g", field.DefaultAppearance);
        Assert.True(field.Has(FieldFlags.Required));
        Assert.Equal(2, field.Widgets.Count);
    }

    [Fact]
    public void WidgetsNotInTheFieldListAreOrphans()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R /AcroForm <</Fields [] /DA (/Helv 0 Tf 0 g)>>>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 600 800]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Annots [10 0 R 11 0 R]>>");
        pdf.Obj(10, "<</Type /Annot /Subtype /Widget /FT /Tx /T (lost) /V (still here) /Rect [0 0 100 20] /P 3 0 R>>");
        pdf.Obj(11, "<</Type /Annot /Subtype /Widget /Rect [0 30 100 50] /P 3 0 R>>");
        var form = PdfForm.Read(PdfDocument.Open(pdf.Finish()));

        var orphan = Assert.Single(form.Orphans);
        Assert.Equal("lost", orphan.Name);
        Assert.Equal("still here", orphan.Value);
        Assert.True(orphan.IsOrphan);
    }

    [Fact]
    public void DocumentWithoutAcroFormHasNoFields()
    {
        var form = PdfForm.Read(AnnotationFixtures.Blank());

        Assert.Empty(form.Fields);
        Assert.Equal(XfaKind.None, form.Xfa);
    }

    [Fact]
    public void LoopsAndDeepTreesDoNotHang()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R /AcroForm <</Fields [10 0 R 10 0 R]>>>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 600 800]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R>>");
        pdf.Obj(10, "<</T (a) /FT /Tx /Kids [11 0 R]>>");
        pdf.Obj(11, "<</T (b) /Parent 10 0 R /Kids [10 0 R 11 0 R]>>");
        var form = PdfForm.Read(PdfDocument.Open(pdf.Finish()));

        Assert.Empty(form.Fields);
    }

    [Fact]
    public void ChoiceValuesAreRead()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R /AcroForm <</Fields [10 0 R]>>>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 600 800]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R>>");
        pdf.Obj(10, "<</T (l) /FT /Ch /Ff 2097152 /Opt [(a) (b) (c)] /V [(a) (c)]>>");
        var field = Assert.Single(PdfForm.Read(PdfDocument.Open(pdf.Finish())).Fields);

        Assert.Equal(["a", "c"], field.Selected);
        Assert.Empty(field.Widgets);
    }
}
