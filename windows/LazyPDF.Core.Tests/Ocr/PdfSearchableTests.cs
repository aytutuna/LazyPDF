using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class PdfSearchableTests
{
    private sealed class Reports : IProgress<OcrProgress>
    {
        public List<OcrProgress> Items { get; } = [];

        public void Report(OcrProgress value) => Items.Add(value);
    }

    private static Task<OcrResult> Run(PdfEditSession session, FakeRecognizer recognizer, OcrOptions? options = null, IProgress<OcrProgress>? progress = null,
                                       CancellationToken cancellation = default, FakeRenderer? renderer = null) =>
        PdfSearchable.RunAsync(session, recognizer, renderer ?? new FakeRenderer(session.Document), options ?? new OcrOptions(Dpi: 72), progress, cancellation);

    [Fact]
    public async Task ScannedPagesGetALayerAsOneUndoableStep()
    {
        var session = PdfEditSession.Open(OcrKit.ScanBytes(3));
        var recognizer = new FakeRecognizer(OcrKit.Words(dpi: 144));
        var renderer = new FakeRenderer(session.Document);
        var reports = new Reports();
        var result = await Run(session, recognizer, new OcrOptions("tr-TR", 144), reports, renderer: renderer);

        Assert.Equal(new OcrResult(3, 0, 0, 0, 12, true), result);
        Assert.Equal([(0, 144d), (1, 144d), (2, 144d)], renderer.Calls);
        Assert.All(recognizer.Calls, call => Assert.Equal((800, 1200, "tr-TR"), call));
        Assert.Equal([(0, 1, 3), (1, 2, 3), (2, 3, 3)], reports.Items.Select(r => (r.PageIndex, r.Done, r.Total)));
        Assert.All(reports.Items, r => Assert.Equal(OcrOutcome.Added, r.Outcome));
        Assert.Equal(OcrStatusText.Label, session.UndoLabel);

        for (int i = 0; i < 3; i++)
        {
            OcrKit.AssertAtBoxes(session.Document, i);
        }
        Assert.True(session.Undo());
        Assert.False(PdfOcrLayer.Has(session.Document, session.Document.Pages[0]));
    }

    [Fact]
    public async Task ReadingAloneLeavesTheDocumentAndGivesTheWordsToWrite()
    {
        var session = PdfEditSession.Open(OcrKit.ScanBytes(2));
        var read = await PdfSearchable.ReadAsync(session.Document, new FakeRecognizer(OcrKit.Words()), new FakeRenderer(session.Document), new OcrOptions(Dpi: 72));

        Assert.Equal(new OcrResult(2, 0, 0, 0, 0, false), read.Result);
        Assert.Equal([0, 1], read.Pages.Select(p => p.PageIndex));
        Assert.False(session.IsDirty);
        Assert.False(PdfOcrLayer.Has(session.Document, session.Document.Pages[0]));
    }

    [Fact]
    public async Task WordsAreAtTheirBoxesWhateverTheResolution()
    {
        var session = PdfEditSession.Open(OcrKit.ScanBytes(1, "/Rotate 90"));
        await Run(session, new FakeRecognizer(OcrKit.Words(dpi: 200)), new OcrOptions(Dpi: 200));
        OcrKit.AssertAtBoxes(session.Document);
    }

    [Fact]
    public async Task SecondRunSkipsReplaceKeepsOneLayer()
    {
        var session = PdfEditSession.Open(OcrKit.ScanBytes(2));
        await Run(session, new FakeRecognizer(OcrKit.Words()));
        byte[] first = session.Current.ToArray();

        var again = new FakeRecognizer(OcrKit.Words());
        var skipped = await Run(session, again);
        Assert.Equal(new OcrResult(0, 0, 2, 0, 0, false), skipped);
        Assert.Empty(again.Calls);
        Assert.Equal(first, session.Current.ToArray());

        var replaced = await Run(session, new FakeRecognizer([OcrKit.Word("Fresh", 40, 100, 80, 24)]), new OcrOptions(Dpi: 72, Existing: OcrExisting.Replace));
        Assert.Equal(new OcrResult(2, 0, 0, 0, 2, true), replaced);
        foreach (int i in new[] { 0, 1 })
        {
            Assert.Equal(1, OcrKit.LayerStreams(session.Document, i));
            Assert.Equal(["Fresh"], TextPage.Create(session.Document, session.Document.Pages[i]).Words.Select(w => w.Text));
        }

        await Run(session, new FakeRecognizer(OcrKit.Words()), new OcrOptions(Dpi: 72, Existing: OcrExisting.Replace));
        await Run(session, new FakeRecognizer(OcrKit.Words()), new OcrOptions(Dpi: 72, Existing: OcrExisting.Replace));
        Assert.Equal(1, OcrKit.LayerStreams(session.Document));
        OcrKit.AssertAtBoxes(session.Document);
        using var reopened = PdfDocument.Open(session.Current.ToArray());
        Assert.Equal(1, OcrKit.LayerStreams(reopened));
        Assert.Equal(4, TextPage.Create(reopened, reopened.Pages[0]).Words.Count);
    }

    [Fact]
    public async Task ReplaceWithNoWordsRemovesTheOldLayer()
    {
        var session = PdfEditSession.Open(OcrKit.ScanBytes());
        await Run(session, new FakeRecognizer(OcrKit.Words()));
        var result = await Run(session, new FakeRecognizer([]), new OcrOptions(Dpi: 72, Existing: OcrExisting.Replace));
        Assert.Equal(new OcrResult(0, 1, 0, 0, 0, true), result);
        Assert.False(PdfOcrLayer.Has(session.Document, session.Document.Pages[0]));
    }

    [Fact]
    public async Task PagesWithTextAreLeftAloneUnlessForced()
    {
        var pdf = OcrKit.Pages("BT /F1 12 Tf 50 500 Td (Printed) Tj ET", "");
        var session = PdfEditSession.Open(pdf.SaveRewrite());
        var recognizer = new FakeRecognizer(OcrKit.Words());
        var plain = await Run(session, recognizer);
        // The empty page has nothing drawn, so it is skipped too.
        Assert.Equal(new OcrResult(0, 0, 2, 0, 0, false), plain);
        Assert.Empty(recognizer.Calls);

        var forced = await Run(session, recognizer, new OcrOptions(Dpi: 72, Force: true));
        Assert.Equal(2, forced.Added);
        Assert.Contains("Printed", TextPage.Create(session.Document, session.Document.Pages[0]).Words.Select(w => w.Text));
        Assert.Contains("Hello", TextPage.Create(session.Document, session.Document.Pages[0]).Words.Select(w => w.Text));
    }

    [Fact]
    public async Task PageSelectionIsBoundedAndOrdered()
    {
        var session = PdfEditSession.Open(OcrKit.ScanBytes(4));
        var reports = new Reports();
        var result = await Run(session, new FakeRecognizer(OcrKit.Words()), new OcrOptions(Dpi: 72, Pages: [3, 1, 3, 99, -1]), reports);
        Assert.Equal(2, result.Added);
        Assert.Equal([1, 3], reports.Items.Select(r => r.PageIndex));
        Assert.Equal([false, true, false, true], session.Document.Pages.Select(p => PdfOcrLayer.Has(session.Document, p)));
    }

    [Fact]
    public async Task PageTheRendererCannotDrawIsCountedAndTheRestIsDone()
    {
        var session = PdfEditSession.Open(OcrKit.ScanBytes(3));
        var reports = new Reports();
        var result = await Run(session, new FakeRecognizer(OcrKit.Words()), progress: reports, renderer: new FakeRenderer(session.Document, 1));
        Assert.Equal(new OcrResult(2, 0, 0, 1, 8, true), result);
        Assert.Equal([OcrOutcome.Added, OcrOutcome.NotRendered, OcrOutcome.Added], reports.Items.Select(r => r.Outcome));
    }

    [Fact]
    public async Task NothingToDoCommitsNothing()
    {
        var session = PdfEditSession.Open(OcrKit.ScanBytes(1, "", ""));
        var result = await Run(session, new FakeRecognizer(OcrKit.Words()));
        Assert.False(result.Committed);
        Assert.False(session.CanUndo);
    }

    [Fact]
    public async Task CancelLeavesTheDocumentAsItWas()
    {
        var session = PdfEditSession.Open(OcrKit.ScanBytes(4));
        byte[] before = session.Current.ToArray();
        using var cancel = new CancellationTokenSource();
        var recognizer = new FakeRecognizer(OcrKit.Words()) { Before = call => { if (call == 2) cancel.Cancel(); return Task.CompletedTask; } };
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => Run(session, recognizer, cancellation: cancel.Token));
        Assert.Equal(3, recognizer.Calls.Count);
        Assert.Equal(before, session.Current.ToArray());
        Assert.False(session.CanUndo);
        Assert.False(session.Document.HasChanges);
    }

    [Fact]
    public async Task CancelBeforeStartDoesNotCallTheRecognizer()
    {
        var session = PdfEditSession.Open(OcrKit.ScanBytes(2));
        var recognizer = new FakeRecognizer(OcrKit.Words());
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => Run(session, recognizer, cancellation: new CancellationToken(true)));
        Assert.Empty(recognizer.Calls);
    }

    [Fact]
    public async Task RecognizerFailureLeavesTheDocumentAsItWas()
    {
        var session = PdfEditSession.Open(OcrKit.ScanBytes(3));
        var recognizer = new FakeRecognizer(OcrKit.Words()) { Before = call => call == 1 ? throw new IOException("engine") : Task.CompletedTask };
        await Assert.ThrowsAsync<IOException>(() => Run(session, recognizer));
        Assert.False(session.Document.HasChanges);
        Assert.False(session.CanUndo);
    }

    [Theory]
    [InlineData(10)]
    [InlineData(71)]
    [InlineData(601)]
    [InlineData(double.NaN)]
    public async Task ResolutionOutsideTheRangeIsRefused(double dpi)
    {
        var session = PdfEditSession.Open(OcrKit.ScanBytes());
        await Assert.ThrowsAsync<ArgumentOutOfRangeException>(() => Run(session, new FakeRecognizer(OcrKit.Words()), new OcrOptions(Dpi: dpi)));
    }

    [Theory]
    [InlineData(PdfCryptStrength.Aes256)]
    [InlineData(PdfCryptStrength.Aes128)]
    public async Task EncryptedFileKeepsItsEncryptionAndTakesTheLayer(PdfCryptStrength strength)
    {
        byte[] id = new byte[16];
        var security = PdfSecurity.Create("user", "owner", PdfPermissions.All, strength, id);
        byte[] locked = OcrKit.Scan(2).SaveRewrite(new PdfSaveOptions(Security: security, DocumentId: id));
        var session = PdfEditSession.Open(locked, "user");
        var result = await Run(session, new FakeRecognizer(OcrKit.Words()));
        Assert.Equal(2, result.Added);

        byte[] saved = session.Current.ToArray();
        Assert.Throws<PdfReadException>(() => PdfDocument.Open(saved, "wrong"));
        using var reopened = PdfDocument.Open(saved, "user");
        Assert.True(reopened.IsEncrypted);
        OcrKit.AssertAtBoxes(reopened, 0);
        OcrKit.AssertAtBoxes(reopened, 1);
        Assert.Contains("Hello world", OcrKit.PigText(saved, "user", 2));
        Assert.DoesNotContain("Hello", OcrKit.Latin(saved));
    }

    [Fact]
    public async Task DamagedPagesDoNotStopTheRun()
    {
        var session = PdfEditSession.Open(OcrKit.ScanBytes(2, "", "q 400 0 0 600 0 0 cm /Im1 Do Q [ ( BI ID"));
        var result = await Run(session, new FakeRecognizer(OcrKit.Words()));
        Assert.Equal(2, result.Added);
    }
}
