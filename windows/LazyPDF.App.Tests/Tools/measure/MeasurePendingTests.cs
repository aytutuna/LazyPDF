using LazyPDF.App.Tools.Measure;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// Measurements waiting in the panel against the file changing under them.
public sealed class MeasurePendingTests
{
    private static Pending On(PdfDocument document, int page) =>
        new(new MeasureItem(MeasureKind.Distance, page, [new(0, 0), new(10, 0)]), PageKey.Of(document.Pages[page]));

    [Fact]
    public void ATurnedPageDropsItsMeasurementsAndTheOthersStay()
    {
        var document = PdfDocument.Open(Pdfs.Text(3));
        var waiting = new[] { On(document, 0), On(document, 2) };

        document.Pages[2].Dictionary["Rotate"] = new PdfNumber(90L);

        var kept = Pending.Keep(waiting, document);
        Assert.Equal([0], kept.Select(p => p.Item.Page));
    }

    [Fact]
    public void ADeletedPageMovesTheMeasurementsAfterItUp()
    {
        var document = PdfDocument.Open(Pdfs.Text(3));
        var waiting = new[] { On(document, 0), On(document, 1), On(document, 2) };

        PageOperations.Delete(document, [0]);

        var kept = Pending.Keep(waiting, document);
        Assert.Equal([0, 1], kept.Select(p => p.Item.Page));
    }

    [Fact]
    public void AFileOpenedAgainFromTheSameBytesKeepsEverything()
    {
        var bytes = Pdfs.Text(2);
        var waiting = new[] { On(PdfDocument.Open(bytes), 1) };

        Assert.Single(Pending.Keep(waiting, PdfDocument.Open(bytes)));
    }
}
