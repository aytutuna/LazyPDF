using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class SanitizeActionLoopTests
{
    private static byte[] WithOutline(string actions)
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R /Outlines 6 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R>>");
        pdf.Obj(6, "<</Type /Outlines /First 7 0 R /Last 7 0 R /Count 1>>");
        pdf.Obj(7, "<</Title (x) /Parent 6 0 R /A 5 0 R>>");
        pdf.Obj(5, actions);
        pdf.Obj(8, "<</S /JavaScript /JS (app.alert) >>");
        return pdf.Finish();
    }

    [Fact]
    public async Task An_action_that_chains_to_itself_is_scanned_and_sanitised()
    {
        using var document = PdfDocument.Open(WithOutline("<</S /GoTo /D [3 0 R /Fit] /Next 5 0 R>>"));
        var sanitizer = new PdfSanitizer(document);

        await Task.Run(() => sanitizer.Scan()).WaitAsync(TimeSpan.FromSeconds(10));
        Assert.NotNull(sanitizer.Run(new SanitizeOptions()));
    }

    [Fact]
    public void An_action_of_an_unknown_type_does_not_hide_the_script_chained_after_it()
    {
        using var document = PdfDocument.Open(WithOutline("<</S /GoToDp /Next 8 0 R>>"));

        var result = new PdfSanitizer(document).Run(new SanitizeOptions());

        Assert.DoesNotContain("app.alert", TestPdf.Text(result.Bytes));
    }
}
