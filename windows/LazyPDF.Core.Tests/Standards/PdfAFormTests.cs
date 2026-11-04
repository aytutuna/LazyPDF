using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class PdfAFormTests
{
    private static byte[] WithForm(string acroForm = "", string field = "/FT /Tx /T (a) /F 4 /AP <</N 10 0 R>>", PdfALevel level = PdfALevel.A2b) =>
        StandardsKit.Compliant(level, catalog: $"/AcroForm << /Fields [9 0 R] {acroForm} >>", page: "/Annots [9 0 R]", extra: pdf =>
        {
            pdf.Obj(9, $"<</Type /Annot /Subtype /Widget /Rect [10 10 90 30] {field}>>");
            pdf.Stream(10, "/Type /XObject /Subtype /Form /BBox [0 0 80 20]", "0 g 0 0 80 20 re S");
        });

    [Fact]
    public void AFieldWithAnAppearanceAndNoScriptsPasses()
    {
        StandardsKit.AssertClean(WithForm());
        StandardsKit.AssertClean(WithForm(level: PdfALevel.A1b), PdfALevel.A1b);
    }

    [Fact]
    public void NeedAppearancesIsReported()
    {
        Assert.Contains("6.4.1", StandardsKit.Clauses(WithForm("/NeedAppearances true")));
        Assert.Contains("6.9", StandardsKit.Clauses(WithForm("/NeedAppearances true", level: PdfALevel.A1b), PdfALevel.A1b));
        Assert.DoesNotContain("6.4.1", StandardsKit.Clauses(WithForm("/NeedAppearances false")));
    }

    [Fact]
    public void XfaDataIsReported()
    {
        Assert.Contains("6.4.2", StandardsKit.Clauses(WithForm("/XFA [(template) 10 0 R]")));
    }

    [Theory]
    [InlineData(PdfALevel.A1b, "6.6.2")]
    [InlineData(PdfALevel.A2b, "6.4.1")]
    [InlineData(PdfALevel.A3b, "6.4.1")]
    public void AdditionalActionsOfAFieldAreReported(PdfALevel level, string clause)
    {
        const string field = "/FT /Tx /T (a) /F 4 /AP <</N 10 0 R>> /AA << /K << /S /URI /URI (x) >> >>";
        Assert.Contains(clause, StandardsKit.Clauses(WithForm(field: field, level: level), level));
        Assert.DoesNotContain("6.5.2", StandardsKit.Clauses(WithForm(field: field, level: level), level));
    }

    [Fact]
    public void PartFourLetsAFieldHaveAdditionalActions()
    {
        byte[] file = WithForm(field: "/FT /Tx /T (a) /F 4 /AP <</N 10 0 R>> /AA << /K << /S /URI /URI (x) >> >>", level: PdfALevel.A4);
        Assert.DoesNotContain(StandardsKit.Check(file, PdfALevel.A4).Issues, i => i.Clause is "6.4.1" or "6.5.2" or "6.6.3");
    }

    [Theory]
    [InlineData(PdfALevel.A1b, "6.6.1")]
    [InlineData(PdfALevel.A2b, "6.4.1")]
    [InlineData(PdfALevel.A3b, "6.4.1")]
    [InlineData(PdfALevel.A4, "6.4.1")]
    public void AWidgetMayNotHaveAnActionEvenAPermittedOne(PdfALevel level, string clause)
    {
        byte[] file = WithForm(field: "/FT /Tx /T (a) /F 4 /AP <</N 10 0 R>> /A << /S /URI /URI (x) >>", level: level);
        Assert.Contains(StandardsKit.Check(file, level).Issues, i => i.Clause == clause && i.Message == PdfAText.WidgetAction);
    }

    [Fact]
    public void FieldsAreFoundThroughTheirKids()
    {
        byte[] file = StandardsKit.Compliant(catalog: "/AcroForm << /Fields [9 0 R] >>", extra: pdf =>
        {
            pdf.Obj(9, "<</T (g) /Kids [11 0 R]>>");
            pdf.Obj(11, "<</T (a) /FT /Tx /Parent 9 0 R /AA << /K << /S /URI /URI (x) >> >>>>");
        });
        Assert.Contains("6.4.1", StandardsKit.Clauses(file));
    }
}
