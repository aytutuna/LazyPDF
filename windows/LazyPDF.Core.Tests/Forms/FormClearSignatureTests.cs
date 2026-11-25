using LazyPDF.Core;
using Xunit;
using static LazyPDF.Core.Tests.AnnotationFixtures;

namespace LazyPDF.Core.Tests;

public class FormClearSignatureTests
{
    private static PdfDocument Signed(bool certified = false)
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R /AcroForm <</Fields [10 0 R 11 0 R] /SigFlags 3>>" + (certified ? " /Perms <</DocMDP 12 0 R>>" : "") + ">>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 600 800]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Annots [10 0 R 11 0 R]>>");
        pdf.Obj(10, "<</Type /Annot /Subtype /Widget /FT /Sig /T (s) /V 12 0 R /AP <</N 13 0 R>> /Rect [0 0 100 20] /P 3 0 R>>");
        pdf.Obj(11, "<</Type /Annot /Subtype /Widget /FT /Sig /T (empty) /Rect [0 100 100 120] /P 3 0 R>>");
        pdf.Obj(12, "<</Type /Sig /Filter /Adobe.PPKLite>>");
        pdf.Stream(13, "/Type /XObject /Subtype /Form /BBox [0 0 100 20]", "0 g");
        return PdfDocument.Open(pdf.Finish());
    }

    [Fact]
    public void ClearingLeavesAnEmptyFieldWithoutItsAppearance()
    {
        var form = PdfForm.Read(Signed());

        form.ClearSignature(form.Find("s")!);

        var field = form.Find("s")!;
        Assert.False(field.IsSigned);
        Assert.False(field.Dictionary.ContainsKey("AP"));
        Assert.Equal(FieldKind.Signature, field.Kind);
    }

    [Fact]
    public void TheClearedFieldIsSavedAsAnIncrementalUpdate()
    {
        var doc = Signed();
        byte[] original = doc.SaveIncremental();
        PdfForm.Read(doc).ClearSignature(PdfForm.Read(doc).Find("s")!);

        byte[] saved = doc.SaveIncremental();

        Assert.True(saved.Length > original.Length);
        Assert.Equal(original, saved[..original.Length]);
        Assert.False(PdfForm.Read(PdfDocument.Open(saved)).Find("s")!.IsSigned);
    }

    [Fact]
    public void ACertificationThatRestedOnTheSignatureGoes()
    {
        var doc = Signed(certified: true);
        var form = PdfForm.Read(doc);

        form.ClearSignature(form.Find("s")!);

        Assert.False(doc.Catalog.ContainsKey("Perms"));
    }

    [Fact]
    public void AFieldThatIsNotSignedIsRefused()
    {
        var form = PdfForm.Read(Signed());

        Assert.Throws<InvalidOperationException>(() => form.ClearSignature(form.Find("empty")!));
    }
}
