using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class RedactBudgetTests
{
    [Fact]
    public void A_page_too_big_to_scan_to_the_end_is_refused_not_passed_through()
    {
        using var document = RedactionKit.Page("/F6 Do BT /F1 12 Tf 100 700 Td (secret) Tj ET", "/XObject <</F6 6 0 R>>", pdf =>
        {
            for (int i = 6; i < 13; i++)
            {
                pdf.Stream(i, $"/Type /XObject /Subtype /Form /BBox [0 0 10 10] /Resources <</XObject <</F{i + 1} {i + 1} 0 R>>>>", string.Concat(Enumerable.Repeat($"/F{i + 1} Do ", 12)));
            }
            pdf.Stream(13, "/Type /XObject /Subtype /Form /BBox [0 0 10 10]", "0 0 m");
        });

        var mark = RedactionMark.FromRect(0, new PdfRect(90, 690, 300, 720), null, "X");

        Assert.Throws<InvalidOperationException>(() => new PdfRedactor(document).Apply([mark]));
    }
}
