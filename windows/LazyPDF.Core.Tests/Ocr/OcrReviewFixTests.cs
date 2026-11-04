using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class OcrReviewFixTests
{
    private const string StampedScan = "q 400 0 0 600 0 0 cm /Im1 Do Q BT /F1 60 Tf 20 300 Td (STAMPED) Tj ET";

    private static Task<OcrResult> Run(PdfEditSession session, IReadOnlyList<OcrWord> words, OcrOptions options) =>
        PdfSearchable.RunAsync(session, new FakeRecognizer(words), new FakeRenderer(session.Document), options);

    [Theory]
    [InlineData(90)]
    [InlineData(180)]
    [InlineData(270)]
    public void CorrectingAWordAfterThePageWasRotatedLeavesTheOtherWordsWhereTheyAre(int degrees)
    {
        var document = OcrKit.Scan();
        var geometry = new PageGeometry(document.Pages[0]);
        PdfOcrLayer.Add(document, [new OcrPageWords(0, OcrKit.Words(), (int)geometry.Width, (int)geometry.Height)], "en-US");
        PageOperations.Rotate(document, [0], degrees);
        var before = PdfOcrLayer.Words(document, document.Pages[0]);

        PdfOcrLayer.Correct(document, document.Pages[0], 0, "Howdy");

        var after = PdfOcrLayer.Words(document, document.Pages[0]);
        Assert.Equal(["Howdy", "world", "Second", "line"], after.Select(w => w.Text));
        for (int i = 0; i < before.Count; i++)
        {
            var (a, b) = (before[i].Box, after[i].Box);
            Assert.True(Math.Abs(a.X - b.X) < 0.5 && Math.Abs(a.Y - b.Y) < 0.5 && Math.Abs(a.Width - b.Width) < 0.5 && Math.Abs(a.Height - b.Height) < 0.5, $"word {i}: {a} became {b}");
        }
    }

    [Fact]
    public async Task AnOwnLayerIsReplacedOnAPageWithAVisibleStampWhenAskedAndKeptWhenNot()
    {
        var session = PdfEditSession.Open(OcrKit.ScanBytes(1, "", StampedScan));
        var first = await Run(session, OcrKit.Words(), new OcrOptions(Dpi: 72, Force: true));
        Assert.Equal(1, first.Added);
        Assert.Equal(OcrPageKind.OwnLayer, OcrTriage.Classify(session.Document, session.Document.Pages[0]));

        byte[] kept = session.Current.ToArray();
        var skipped = await Run(session, [OcrKit.Word("Other", 40, 100, 80, 24)], new OcrOptions(Dpi: 72, Force: true));
        Assert.Equal(1, skipped.Skipped);
        Assert.Equal(kept, session.Current.ToArray());

        var replaced = await Run(session, [OcrKit.Word("Fresh", 40, 100, 80, 24)], new OcrOptions(Dpi: 72, Existing: OcrExisting.Replace));
        Assert.Equal(1, replaced.Added);
        Assert.Equal(["Fresh"], PdfOcrLayer.Words(session.Document, session.Document.Pages[0]).Select(w => w.Text));
    }

    [Fact]
    public async Task BlankWordsAreNotCountedAsAddedAndLeavePageWithoutLayer()
    {
        var session = PdfEditSession.Open(OcrKit.ScanBytes());
        var result = await Run(session, [OcrKit.Word("  ", 40, 100, 80, 24)], new OcrOptions(Dpi: 72));

        Assert.Equal(new OcrResult(0, 1, 0, 0, 0, false), result);
        Assert.False(PdfOcrLayer.Has(session.Document, session.Document.Pages[0]));
    }
}
