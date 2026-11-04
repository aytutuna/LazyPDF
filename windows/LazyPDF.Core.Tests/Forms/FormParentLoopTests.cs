using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class FormParentLoopTests
{
    [Fact]
    public async Task Clearing_a_field_whose_parents_form_a_loop_ends()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R /AcroForm <</Fields [5 0 R]>>>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Annots [5 0 R]>>");
        pdf.Obj(5, "<</Type /Annot /Subtype /Widget /FT /Tx /T (a) /Rect [0 0 50 20] /V (x) /Parent 6 0 R>>");
        pdf.Obj(6, "<</T (p) /Parent 7 0 R>>");
        pdf.Obj(7, "<</T (q) /Parent 6 0 R>>");
        using var document = PdfDocument.Open(pdf.Finish());
        var form = PdfForm.Read(document);

        await Task.Run(() => form.Reset()).WaitAsync(TimeSpan.FromSeconds(10));
    }
}
