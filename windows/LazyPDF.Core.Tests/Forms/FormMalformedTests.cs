using LazyPDF.Core;
using Xunit;
using static LazyPDF.Core.Tests.AnnotationFixtures;

namespace LazyPDF.Core.Tests;

public class FormMalformedTests
{
    private static PdfForm Build(string acro, params string[] objects)
    {
        var pdf = new TestPdf();
        pdf.Obj(1, $"<</Type /Catalog /Pages 2 0 R /AcroForm {acro}>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 600 800]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Annots [10 0 R 11 0 R]>>");
        for (int i = 0; i < objects.Length; i++) pdf.Obj(10 + i, objects[i]);
        return PdfForm.Read(PdfDocument.Open(pdf.Finish()));
    }

    [Fact]
    public void JunkInTheFieldListIsSkipped()
    {
        var form = Build("<</Fields [null 5 (text) 10 0 R 99 0 R <</T (direct) /FT /Tx>>]>>",
            "<</Type /Annot /Subtype /Widget /FT /Tx /T (ok) /Rect [0 0 100 20] /P 3 0 R>>");

        Assert.Equal(["ok", "direct"], form.Fields.Select(f => f.Name));
        Assert.Empty(form.Fields[1].Widgets);
    }

    [Fact]
    public void FieldsThatIsNotAnArrayGivesAnEmptyFormButOrphansAreStillFound()
    {
        var form = Build("<</Fields 5>>", "<</Type /Annot /Subtype /Widget /FT /Tx /T (lost) /Rect [0 0 100 20]>>");

        var orphan = Assert.Single(form.Fields);
        Assert.True(orphan.IsOrphan);
        Assert.Equal(0, orphan.Widgets[0].PageIndex);
    }

    [Fact]
    public void BadValuesAndOptionsReadAsDefaults()
    {
        var form = Build("<</Fields [10 0 R 11 0 R]>>",
            "<</Type /Annot /Subtype /Widget /FT /Ch /Ff 131072 /T (c) /V 12 /Opt [(a) 5 [(x)] [1 2] null] /MaxLen -4 /Q 9 /Rect [0 0 100 20] /P 3 0 R>>",
            "<</Type /Annot /Subtype /Widget /FT /Btn /T (b) /V 3 /AP <</N 7>> /Rect [0 30 14 44] /P 3 0 R>>");

        var combo = form.Find("c")!;
        Assert.Null(combo.Value);
        Assert.Equal([new FieldOption("a")], combo.Options.Take(1));
        Assert.Equal(0, combo.MaxLength);
        Assert.Equal("Off", form.Find("b")!.Value);
        Assert.Null(form.Find("b")!.Widgets[0].OnState);
    }

    [Fact]
    public void FillingWorksWithoutDefaultsFontsOrSaneGeometry()
    {
        var form = Build("<</Fields [10 0 R 11 0 R]>>",
            "<</Type /Annot /Subtype /Widget /FT /Tx /T (t) /DA (garbage) /MK <</R 45 /BC 3 /BG [1 2]>> /Rect [0 0 100 20] /P 3 0 R>>",
            "<</Type /Annot /Subtype /Widget /FT /Tx /T (flat) /Rect [5 5 5 5] /P 3 0 R>>");

        var result = form.SetValues([new("t", "hello"), new("flat", "zero area")]);

        Assert.Equal(2, result.Filled);
        Assert.Equal("hello", FormFixtures.Drawn(form.Document, form.Find("t")!.Widgets[0]));
        Assert.Null(form.Document.Dict(form.Find("flat")!.Widgets[0].Dictionary, "AP"));
        Assert.True(form.Document.Dict(form.Document.Dict(form.AcroForm, "DR"), "Font")!.ContainsKey("Helv"));
        Reopen(form.Document);
    }

    [Fact]
    public void ADefaultFontThatIsNotInTheResourcesIsAddedUnderItsName()
    {
        var form = Build("<</Fields [10 0 R] /DA (/TiRo 10 Tf 0 g)>>",
            "<</Type /Annot /Subtype /Widget /FT /Tx /T (t) /Rect [0 0 100 20] /P 3 0 R>>");

        form.SetValue("t", "serif");

        var fonts = form.Document.Dict(form.Document.Dict(form.AcroForm, "DR"), "Font")!;
        var added = (PdfDictionary)form.Document.Resolve(fonts["TiRo"])!;
        Assert.Contains("Times", form.Document.Name(added, "BaseFont"));
    }

    [Fact]
    public void ValuesStoredAsStreamsAreRead()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R /AcroForm <</Fields [10 0 R]>>>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 600 800]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R>>");
        pdf.Obj(10, "<</FT /Tx /T (long) /V 11 0 R>>");
        pdf.Stream(11, "", "from a stream");

        Assert.Equal("from a stream", Assert.Single(PdfForm.Read(PdfDocument.Open(pdf.Finish())).Fields).Value);
    }

    [Fact]
    public void RemovingAndRenamingFieldsOutsideTheTreeIsHarmless()
    {
        var form = Build("<</Fields []>>", "<</Type /Annot /Subtype /Widget /FT /Tx /T (lost) /Rect [0 0 100 20] /P 3 0 R>>");
        var orphan = form.Fields.Single();

        form.Rename(orphan, "found");
        form.Remove(form.Find("found")!);

        Assert.Empty(form.Fields);
    }

    [Fact]
    public void SignedSignatureFieldsAreReportedAndNeverFilled()
    {
        var form = Build("<</Fields [10 0 R]>>", "<</Type /Annot /Subtype /Widget /FT /Sig /T (s) /V <</Type /Sig /Filter /Adobe.PPKLite>> /Rect [0 0 100 20] /P 3 0 R>>");

        var field = form.Fields.Single();

        Assert.True(field.IsSigned);
        Assert.Equal(["s"], form.SetValue("s", "x").Rejected);
        Assert.True(form.CanFill);
    }
}
