using LazyPDF.App.Services;
using LazyPDF.App.Tools.Batch;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// The steps of a batch against real Core calls on small files.
public sealed class BatchRunnerTests
{
    private static readonly DateTimeOffset Now = new(2026, 3, 9, 12, 0, 0, TimeSpan.Zero);

    private sealed class FakeRecognizer : ITextRecognizer
    {
        public Task<IReadOnlyList<OcrWord>> RecognizeAsync(PdfRgbaImage image, string language, CancellationToken cancellation = default) =>
            Task.FromResult<IReadOnlyList<OcrWord>>([new OcrWord("Invoice", new OcrBox(0, 0, 2, 1))]);
    }

    private static BatchRunner Runner() => new(new FakeCodec(), new SystemFontSource(), new FakeRecognizer(), () => new FakeRenderer());

    private static BatchSet Set(TempDir dir, params BatchStep[] steps) => new() { Steps = [.. steps], OutputFolder = dir.Sub("out") };

    private static BatchStep Step(BatchStepKind kind, string text = "") => new() { Kind = kind, Text = text };

    private static Task<BatchResult> Run(BatchRunner runner, string file, BatchSet set, int number = 1) =>
        runner.RunAsync(file, set, number, Now, CancellationToken.None);

    private static string TextOf(string path, int page)
    {
        using var document = PdfDocument.Open(File.ReadAllBytes(path));
        return TextPage.Create(document, document.Pages[page]).Text;
    }

    [Fact]
    public async Task AFileGoesThroughTheStepsAndIsWrittenUnderANewName()
    {
        using var dir = new TempDir();
        byte[] original = Pdfs.Text(2);
        string file = dir.File("report.pdf", original);
        var set = Set(dir, Step(BatchStepKind.Watermark, "DRAFT"), Step(BatchStepKind.Compress), Step(BatchStepKind.Clean));
        set.NameTemplate = "{name}-{n}";

        var result = await Run(Runner(), file, set, 7);

        Assert.True(result.Ok, result.Detail);
        Assert.Equal(dir.Sub("out\\report-7.pdf"), result.Output);
        using var made = PdfDocument.Open(File.ReadAllBytes(result.Output!));
        Assert.Equal(2, made.Pages.Count);
        Assert.Equal("DRAFT", Assert.Single(new PdfStamper(made).List()).Label);
        Assert.Equal(original, File.ReadAllBytes(file));
    }

    [Fact]
    public async Task AFileFromASubfolderKeepsItsFolderInTheResults()
    {
        using var dir = new TempDir();
        string file = dir.File("a\\b\\x.pdf", Pdfs.Text());
        var set = Set(dir, Step(BatchStepKind.Clean));

        var result = await Runner().RunAsync(file, set, 1, Now, CancellationToken.None, "b");

        Assert.True(result.Ok, result.Detail);
        Assert.Equal(dir.Sub("out\\b\\x.pdf"), result.Output);
        Assert.StartsWith("b\\x.pdf", result.Detail);
    }

    [Fact]
    public async Task SameNamedFilesInDifferentFoldersDoNotCollide()
    {
        using var dir = new TempDir();
        var set = Set(dir, Step(BatchStepKind.Clean));

        var one = await Runner().RunAsync(dir.File("a\\x.pdf", Pdfs.Text()), set, 1, Now, CancellationToken.None, "a");
        var two = await Runner().RunAsync(dir.File("b\\x.pdf", Pdfs.Text()), set, 2, Now, CancellationToken.None, "b");

        Assert.Equal(dir.Sub("out\\a\\x.pdf"), one.Output);
        Assert.Equal(dir.Sub("out\\b\\x.pdf"), two.Output);
    }

    [Fact]
    public async Task AFolderAboveTheResultsFolderIsNotUsed()
    {
        using var dir = new TempDir();
        var set = Set(dir, Step(BatchStepKind.Clean));

        var result = await Runner().RunAsync(dir.File("x.pdf", Pdfs.Text()), set, 1, Now, CancellationToken.None, "..\\up");

        Assert.Equal(dir.Sub("out\\x.pdf"), result.Output);
    }

    [Fact]
    public async Task ALockedFileIsRefusedWithAPlainReason()
    {
        using var dir = new TempDir();
        byte[] locked = LazyPDF.App.Tools.Protect.ProtectWork.WithPassword(PdfDocument.Open(Pdfs.Text()), "secret", "secret", PdfPermissions.All, PdfCryptStrength.Aes256);
        string file = dir.File("locked.pdf", locked);

        var result = await Run(Runner(), file, Set(dir, Step(BatchStepKind.Clean)));

        Assert.False(result.Ok);
        Assert.Equal("File is locked", result.Title);
        Assert.Contains("locked.pdf", result.Detail);
        Assert.Contains("cannot ask", result.Detail);
    }

    [Fact]
    public async Task ANameThatIsTakenGetsANumberAndNothingIsOverwritten()
    {
        using var dir = new TempDir();
        string file = dir.File("a.pdf", Pdfs.Text());
        var set = Set(dir, Step(BatchStepKind.Clean));

        var first = await Run(Runner(), file, set);
        var second = await Run(Runner(), file, set);

        Assert.Equal(dir.Sub("out\\a.pdf"), first.Output);
        Assert.Equal(dir.Sub("out\\a (2).pdf"), second.Output);
    }

    [Fact]
    public async Task BatesNumbersRunOnFromOneFileToTheNext()
    {
        using var dir = new TempDir();
        string one = dir.File("one.pdf", Pdfs.Text(3));
        string two = dir.File("two.pdf", Pdfs.Text(2));
        var set = Set(dir, new BatchStep { Kind = BatchStepKind.Bates, Text = "AB-", Digits = 4, Start = 10 });
        var runner = Runner();

        var a = await Run(runner, one, set);
        Assert.Equal(13, set.Steps[0].Start);
        var b = await Run(runner, two, set);
        Assert.Equal(15, set.Steps[0].Start);

        Assert.Contains("AB-0010", TextOf(a.Output!, 0));
        Assert.Contains("AB-0012", TextOf(a.Output!, 2));
        Assert.Contains("AB-0013", TextOf(b.Output!, 0));

        set.Steps[0].Start = 10;
        var again = await Run(runner, two, set);
        Assert.Contains("AB-0010", TextOf(again.Output!, 0));
    }

    [Fact]
    public async Task PagesThatArePicturesGetATextLayer()
    {
        using var dir = new TempDir();
        string file = dir.File("scan.pdf", PdfFromPictures.Create([[1, 2, 3]], new FakeCodec()).Bytes);
        var set = Set(dir, Step(BatchStepKind.Ocr, "en-US"));

        var result = await Run(Runner(), file, set);

        Assert.True(result.Ok, result.Detail);
        using var made = PdfDocument.Open(File.ReadAllBytes(result.Output!));
        Assert.True(PdfOcrLayer.Has(made, made.Pages[0]));
    }

    [Fact]
    public async Task APdfAStepWritesAFileThatPassesTheFileRules()
    {
        using var dir = new TempDir();
        string file = dir.File("a.pdf", Pdfs.Text());
        var set = Set(dir, new BatchStep { Kind = BatchStepKind.PdfA, Level = PdfALevel.A2b });

        var result = await Run(Runner(), file, set);

        Assert.True(result.Ok, result.Detail);
        using var made = PdfDocument.Open(File.ReadAllBytes(result.Output!));
        Assert.DoesNotContain(PdfAValidator.Validate(made, PdfALevel.A2b).Issues, i => i.Where == "Catalog");
    }

    [Fact]
    public async Task AFileThatNeedsAPasswordIsReportedAndTheRunGoesOn()
    {
        using var dir = new TempDir();
        string locked = Pdfs.Fixture("locked.pdf");
        var set = Set(dir, Step(BatchStepKind.Clean));

        var failed = await Run(Runner(), locked, set);
        var fine = await Run(Runner(), dir.File("b.pdf", Pdfs.Text()), set);

        Assert.False(failed.Ok);
        Assert.Equal("File is locked", failed.Title);
        Assert.Null(failed.Output);
        Assert.True(fine.Ok);
    }

    [Fact]
    public async Task AWatermarkWithNoTextFailsWithWhatToDo()
    {
        using var dir = new TempDir();
        var set = Set(dir, Step(BatchStepKind.Watermark, "  "));

        var result = await Run(Runner(), dir.File("a.pdf", Pdfs.Text()), set);

        Assert.False(result.Ok);
        Assert.Equal("Watermark has no text", result.Title);
        Assert.False(Directory.Exists(set.OutputFolder));
    }

    [Fact]
    public async Task AMissingFileIsAResultNotACrash()
    {
        using var dir = new TempDir();

        var result = await Run(Runner(), dir.Sub("gone.pdf"), Set(dir, Step(BatchStepKind.Clean)));

        Assert.False(result.Ok);
        Assert.Equal("File not found", result.Title);
    }

    [Fact]
    public async Task ACancelStopsTheRun()
    {
        using var dir = new TempDir();
        using var cancel = new CancellationTokenSource();
        cancel.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            Runner().RunAsync(dir.File("a.pdf", Pdfs.Text()), Set(dir, Step(BatchStepKind.Clean)), 1, Now, cancel.Token));
    }

    private sealed class CancellingRecognizer(CancellationTokenSource cancel) : ITextRecognizer
    {
        public Task<IReadOnlyList<OcrWord>> RecognizeAsync(PdfRgbaImage image, string language, CancellationToken cancellation = default)
        {
            cancel.Cancel();
            return Task.FromResult<IReadOnlyList<OcrWord>>([new OcrWord("Invoice", new OcrBox(0, 0, 2, 1))]);
        }
    }

    private sealed class SilentRecognizer : ITextRecognizer
    {
        public Task<IReadOnlyList<OcrWord>> RecognizeAsync(PdfRgbaImage image, string language, CancellationToken cancellation = default) =>
            Task.FromResult<IReadOnlyList<OcrWord>>([]);
    }

    [Fact]
    public async Task AFileThatLimitsWhatMayBeDoneIsRefusedAndNothingIsWritten()
    {
        using var dir = new TempDir();
        string file = dir.File("a.pdf", Pdfs.Restricted(PdfPermissions.Print));
        var set = Set(dir, Step(BatchStepKind.Compress));

        var result = await Run(Runner(), file, set);

        Assert.False(result.Ok);
        Assert.Equal("File is protected", result.Title);
        Assert.False(Directory.Exists(set.OutputFolder));
    }

    [Fact]
    public async Task AFileThatOpensFreelyKeepsItsEncryptionThroughCompressAndClean()
    {
        using var dir = new TempDir();
        string file = dir.File("a.pdf", Pdfs.Restricted(PdfPermissions.All));
        var set = Set(dir, Step(BatchStepKind.Compress), Step(BatchStepKind.Clean));

        var result = await Run(Runner(), file, set);

        Assert.True(result.Ok, result.Detail);
        using var made = PdfDocument.Open(File.ReadAllBytes(result.Output!));
        Assert.NotNull(made.Security);
    }

    [Fact]
    public async Task ACompressThatCannotShrinkTheFileIsSaidInTheLog()
    {
        using var dir = new TempDir();
        string file = dir.File("a.pdf", Pdfs.Text());

        var result = await Run(Runner(), file, Set(dir, Step(BatchStepKind.Compress), Step(BatchStepKind.Compress)));

        Assert.True(result.Ok, result.Detail);
        Assert.Equal("Done, with notes", result.Title);
        Assert.Contains("Could not be made smaller, so it was left as it was.", result.Detail);
    }

    [Fact]
    public async Task ACancelDuringAStepStopsTheRunBeforeAnythingIsWritten()
    {
        using var dir = new TempDir();
        using var cancel = new CancellationTokenSource();
        var runner = new BatchRunner(new FakeCodec(), new SystemFontSource(), new CancellingRecognizer(cancel), () => new FakeRenderer());
        string file = dir.File("scan.pdf", PdfFromPictures.Create([[1, 2, 3]], new FakeCodec()).Bytes);
        var set = Set(dir, Step(BatchStepKind.Ocr, "en-US"), Step(BatchStepKind.Clean), Step(BatchStepKind.Compress));

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => runner.RunAsync(file, set, 1, Now, cancel.Token));

        Assert.False(Directory.Exists(set.OutputFolder));
    }

    [Fact]
    public async Task APageWithNoTextIsSaidInTheLogNotJustDone()
    {
        using var dir = new TempDir();
        var runner = new BatchRunner(new FakeCodec(), new SystemFontSource(), new SilentRecognizer(), () => new FakeRenderer());
        string file = dir.File("scan.pdf", PdfFromPictures.Create([[1, 2, 3]], new FakeCodec()).Bytes);

        var result = await runner.RunAsync(file, Set(dir, Step(BatchStepKind.Ocr, "en-US")), 1, Now, CancellationToken.None);

        Assert.True(result.Ok);
        Assert.Equal("Done, with notes", result.Title);
        Assert.Contains("No text found on 1 page", result.Detail);
    }

    [Fact]
    public async Task ARuleLeftAfterPdfAIsCountedWhenAStepComesAfterIt()
    {
        using var dir = new TempDir();
        string file = dir.File("a.pdf", Pdfs.Text());
        var set = Set(dir, new BatchStep { Kind = BatchStepKind.PdfA, Level = PdfALevel.A2b }, Step(BatchStepKind.Clean));

        var result = await Run(Runner(), file, set);

        Assert.True(result.Ok, result.Detail);
        Assert.Contains("PDF/A rule", result.Detail);
    }

    [Fact]
    public async Task CommentsAndFormsStayOnlyWhereTheStepKeepsThem()
    {
        using var dir = new TempDir();
        var session = PdfEditSession.Open(Pdfs.Text());
        new PdfAnnotationWriter(session.Document).AddNote(session.Document.Pages[0], new PdfRect(50, 50, 70, 70), new AnnotationInfo("Sam", "Check this"));
        session.Commit("Note");
        string file = dir.File("a.pdf", session.Current.ToArray());

        var removed = await Run(Runner(), file, Set(dir, Step(BatchStepKind.Clean)));
        var kept = await Run(Runner(), file, Set(dir, new BatchStep { Kind = BatchStepKind.Clean, KeepComments = true }));

        static int Notes(string path)
        {
            using var made = PdfDocument.Open(File.ReadAllBytes(path));
            return PdfAnnotations.Read(made, made.Pages[0]).Count(a => a.Type == AnnotationType.Text);
        }
        Assert.Equal(0, Notes(removed.Output!));
        Assert.Equal(1, Notes(kept.Output!));
    }

    [Fact]
    public async Task AResultsFolderThatCannotBeMadeIsAWriteProblemNotAReadProblem()
    {
        using var dir = new TempDir();
        string file = dir.File("a.pdf", Pdfs.Text());
        var set = Set(dir, Step(BatchStepKind.Clean));
        set.OutputFolder = dir.File("taken", [1]);

        var result = await Run(Runner(), file, set);

        Assert.False(result.Ok);
        Assert.Equal("Not saved", result.Title);
    }
}
