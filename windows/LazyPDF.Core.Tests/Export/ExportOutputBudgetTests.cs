using System.Text;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class ExportOutputBudgetTests
{
    private static ExportDocument OnePage(IReadOnlyList<ExportBlock> blocks) =>
        new(null, [new ExportPage(0, 612, 792, blocks, [], [])], 11);

    private static IReadOnlyList<ExportBlock> Pictures(int count, int bytes)
    {
        var picture = new ExportPicture(new DisplayRect(10, 10, 8, 6), new ExportImage(new byte[bytes], true, 8, 6));
        return [.. Enumerable.Repeat<ExportBlock>(picture, count)];
    }

    [Fact]
    public void DocxMarkupOfManyPicturesIsRefusedBeforeTheStringIsBuilt()
    {
        var document = OnePage(Pictures(750_000, 30));
        Assert.Throws<PdfReadException>(() => DocxWriter.Make(document));
    }

    [Fact]
    public void HtmlMarkupAroundSmallPicturesCountsAgainstTheLimit()
    {
        var document = OnePage(Pictures(5_000_000, 30));
        Assert.Throws<PdfReadException>(() => HtmlWriter.Reflowed(document));
    }

    [Fact]
    public void RtfEscapesOfTextCountAgainstTheLimit()
    {
        var paragraph = new ExportParagraph(new DisplayRect(10, 10, 500, 20), [new ExportRun(new string('\uAC00', 60 << 20), false, false, 11)]);
        Assert.Throws<PdfReadException>(() => RtfWriter.Make(OnePage([paragraph])));
    }

    [Fact]
    public void ManySmallRunsPassTheAnalysisBudget()
    {
        var content = new StringBuilder("BT /F1 4 Tf ");
        for (int i = 0; i < 20000; i++) content.Append($"1 0 0 1 {10 + i % 50 * 11} {780 - i / 50 * 1.5} Tm (x) Tj ");
        content.Append("ET");
        var document = ExportKit.Open(content.ToString());
        Assert.Equal(60, ExportLayout.Analyze(document, Enumerable.Repeat(0, 60).ToList()).Pages.Count);
    }
}
