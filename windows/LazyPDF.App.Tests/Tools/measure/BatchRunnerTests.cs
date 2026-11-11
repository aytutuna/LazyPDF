using LazyPDF.App.Services;
using LazyPDF.App.Tools.Batch;
using LazyPDF.App.Tools.Export;
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
        Assert.Contains("Password for locked files", result.Detail);
    }

    private static byte[] Locked() =>
        LazyPDF.App.Tools.Protect.ProtectWork.WithPassword(PdfDocument.Open(Pdfs.Text()), "x", "owner", PdfPermissions.All, PdfCryptStrength.Aes256);

    [Fact]
    public async Task ALockedFileRunsWithItsPasswordAndIsSavedUnprotected()
    {
        using var dir = new TempDir();
        string file = dir.File("locked.pdf", Locked());

        var result = await Runner().RunAsync(file, Set(dir, Step(BatchStepKind.Clean)), 1, Now, CancellationToken.None, "", "x");

        Assert.True(result.Ok, result.Detail);
        using var made = PdfDocument.Open(File.ReadAllBytes(result.Output!));
        Assert.Null(made.Security);
    }

    [Fact]
    public async Task AWrongPasswordIsRefusedWithoutNamingIt()
    {
        using var dir = new TempDir();
        string file = dir.File("locked.pdf", Locked());

        var result = await Runner().RunAsync(file, Set(dir, Step(BatchStepKind.Clean)), 1, Now, CancellationToken.None, "", "y");

        Assert.False(result.Ok);
        Assert.Equal("File is locked", result.Title);
        Assert.Equal("The password does not open locked.pdf.", result.Detail);
    }

    [Fact]
    public async Task ASavedSetHoldsNoPassword()
    {
        using var dir = new TempDir();
        var set = Set(dir, Step(BatchStepKind.Clean));
        set.Name = "Locked";
        await Runner().RunAsync(dir.File("locked.pdf", Locked()), set, 1, Now, CancellationToken.None, "", "x");
        var store = new BatchSetStore(dir.Path);

        store.Save(set);

        Assert.DoesNotContain("\"x\"", File.ReadAllText(Path.Combine(dir.Path, "batch-sets.json")), StringComparison.Ordinal);
        Assert.DoesNotContain("assword", File.ReadAllText(Path.Combine(dir.Path, "batch-sets.json")));
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
    public async Task PageNumbersArePrintedOnThePages()
    {
        using var dir = new TempDir();
        var step = BatchStep.Of(BatchStepKind.PageNumbers);
        var set = Set(dir, step);

        var result = await Run(Runner(), dir.File("a.pdf", Pdfs.Text(3)), set);

        Assert.True(result.Ok, result.Detail);
        Assert.Contains("Page 2 of 3", TextOf(result.Output!, 1));
    }

    [Fact]
    public async Task PageNumbersFillInTheDateAndTheFileName()
    {
        using var dir = new TempDir();
        var step = BatchStep.Of(BatchStepKind.PageNumbers);
        step.Text = "{file} {date}";

        var result = await Run(Runner(), dir.File("a.pdf", Pdfs.Text()), Set(dir, step));

        Assert.True(result.Ok, result.Detail);
        Assert.Contains("a.pdf 2026-03-09", TextOf(result.Output!, 0));
    }

    [Fact]
    public async Task PageNumbersWithNoTextFailWithWhatToDo()
    {
        using var dir = new TempDir();
        var set = Set(dir, new BatchStep { Kind = BatchStepKind.PageNumbers, Text = " " });

        var result = await Run(Runner(), dir.File("a.pdf", Pdfs.Text()), set);

        Assert.False(result.Ok);
        Assert.Equal("Page number text is empty", result.Title);
    }

    [Fact]
    public void APageNumbersStepSurvivesASavedSet()
    {
        using var dir = new TempDir();
        var set = Set(dir, new BatchStep { Kind = BatchStepKind.PageNumbers, Text = "{page}/{pages}", Place = BatesPlace.HeaderCenter, FontSize = 14 });
        set.Name = "Numbers";
        var store = new BatchSetStore(dir.Path);

        store.Save(set);

        var step = store.Load().Single().Steps.Single();
        Assert.Equal(BatchStepKind.PageNumbers, step.Kind);
        Assert.Equal("{page}/{pages}", step.Text);
        Assert.Equal(BatesPlace.HeaderCenter, step.Place);
        Assert.Equal(14, step.FontSize);
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

    private static List<int> Turns(string path)
    {
        using var document = PdfDocument.Open(File.ReadAllBytes(path));
        return [.. document.Pages.Select(p => p.Rotate)];
    }

    [Fact]
    public async Task RotateTurnsEveryPageOrOnlyTheOddOrEvenOnes()
    {
        using var dir = new TempDir();
        string file = dir.File("a.pdf", Pdfs.Text(3));

        var all = await Run(Runner(), file, Set(dir, new BatchStep { Kind = BatchStepKind.Rotate, Turn = 90 }));
        var even = await Run(Runner(), file, Set(dir, new BatchStep { Kind = BatchStepKind.Rotate, Turn = 180, Pages = BatchPages.Even }), 2);

        Assert.Equal([90, 90, 90], Turns(all.Output!));
        Assert.Equal([0, 180, 0], Turns(even.Output!));
    }

    [Fact]
    public async Task RotateAddsToThePageTurnItAlreadyHas()
    {
        using var dir = new TempDir();
        var session = PdfEditSession.Open(Pdfs.Text());
        PageOperations.Rotate(session.Document, [0], 270);
        session.Commit("Rotate");
        string file = dir.File("a.pdf", session.Current.ToArray());

        var result = await Run(Runner(), file, Set(dir, new BatchStep { Kind = BatchStepKind.Rotate, Turn = 90 }));

        Assert.Equal([0], Turns(result.Output!));
    }

    [Fact]
    public async Task RotatePassesAFileWithNoMatchingPageThroughWithANote()
    {
        using var dir = new TempDir();
        string file = dir.File("a.pdf", Pdfs.Text());

        var result = await Run(Runner(), file, Set(dir, new BatchStep { Kind = BatchStepKind.Rotate, Pages = BatchPages.Even }));

        Assert.True(result.Ok, result.Detail);
        Assert.Contains("No page matched", result.Detail, StringComparison.Ordinal);
        Assert.Equal([0], Turns(result.Output!));
    }

    [Fact]
    public void ARotateStepSurvivesBeingSaved()
    {
        using var dir = new TempDir();
        var set = Set(dir, new BatchStep { Kind = BatchStepKind.Rotate, Turn = 270, Pages = BatchPages.Odd });
        set.Name = "Turn";
        var store = new BatchSetStore(dir.Path);

        store.Save(set);

        var step = Assert.Single(Assert.Single(store.Load()).Steps);
        Assert.Equal((BatchStepKind.Rotate, 270, BatchPages.Odd), (step.Kind, step.Turn, step.Pages));
    }

    [Fact]
    public async Task ProtectLocksTheResultWithThePassword()
    {
        using var dir = new TempDir();
        string file = dir.File("a.pdf", Pdfs.Text(2));

        var result = await Run(Runner(), file, Set(dir, new BatchStep { Kind = BatchStepKind.Protect, Password = "pw" }));

        Assert.True(result.Ok, result.Detail);
        byte[] made = File.ReadAllBytes(result.Output!);
        Assert.Equal(PdfReadProblem.PasswordRequired, Assert.Throws<PdfReadException>(() => PdfDocument.Open(made)).Problem);
        Assert.Throws<PdfReadException>(() => PdfDocument.Open(made, "other"));
        using var opened = PdfDocument.Open(made, "pw");
        Assert.Equal(2, opened.Pages.Count);
    }

    [Fact]
    public void ThePasswordOfAProtectStepIsNotSaved()
    {
        using var dir = new TempDir();
        var set = Set(dir, new BatchStep { Kind = BatchStepKind.Protect, Password = "pw-secret" });
        set.Name = "Lock";
        var store = new BatchSetStore(dir.Path);

        store.Save(set);

        Assert.DoesNotContain("pw-secret", File.ReadAllText(dir.Sub("batch-sets.json")), StringComparison.Ordinal);
        Assert.Equal("", Assert.Single(Assert.Single(store.Load()).Steps).Password);
        Assert.Equal("pw-secret", set.Copy().Steps[0].Password);
    }

    [Fact]
    public async Task ProtectThatIsNotLastRefusesTheRun()
    {
        using var dir = new TempDir();
        string file = dir.File("a.pdf", Pdfs.Text());

        var result = await Run(Runner(), file, Set(dir, new BatchStep { Kind = BatchStepKind.Protect, Password = "pw" }, Step(BatchStepKind.Clean)));

        Assert.False(result.Ok);
        Assert.Equal("Protect must be the last step", result.Title);
        Assert.False(Directory.Exists(dir.Sub("out")));
    }

    [Fact]
    public async Task ProtectWithPdfARefusesTheRun()
    {
        using var dir = new TempDir();
        string file = dir.File("a.pdf", Pdfs.Text());

        var result = await Run(Runner(), file, Set(dir, new BatchStep { Kind = BatchStepKind.PdfA, Level = PdfALevel.A2b }, new BatchStep { Kind = BatchStepKind.Protect, Password = "pw" }));

        Assert.False(result.Ok);
        Assert.Equal("PDF/A cannot be locked", result.Title);
        Assert.False(Directory.Exists(dir.Sub("out")));
    }

    [Fact]
    public void AStepCanJoinASetWithProtectExceptAnotherProtectPdfAOrPictures()
    {
        using var dir = new TempDir();
        var set = Set(dir, new BatchStep { Kind = BatchStepKind.Protect, Password = "pw" });

        Assert.Null(BatchRunner.CannotAdd(set, BatchStepKind.Compress));
        Assert.Equal("Protect is already there", BatchRunner.CannotAdd(set, BatchStepKind.Protect)?.Title);
        Assert.Equal("PDF/A cannot be locked", BatchRunner.CannotAdd(set, BatchStepKind.PdfA)?.Title);
        Assert.Equal("Pictures cannot be locked", BatchRunner.CannotAdd(set, BatchStepKind.ExportPictures)?.Title);
        Assert.Null(BatchRunner.CannotAdd(Set(dir), BatchStepKind.PdfA));
    }

    [Fact]
    public async Task ProtectWithNoPasswordRefusesTheRun()
    {
        using var dir = new TempDir();
        string file = dir.File("a.pdf", Pdfs.Text());

        var result = await Run(Runner(), file, Set(dir, Step(BatchStepKind.Protect)));

        Assert.False(result.Ok);
        Assert.Equal("No password", result.Title);
        Assert.False(Directory.Exists(dir.Sub("out")));
    }

    [Fact]
    public async Task ExportPicturesWritesAFolderOfPicturesAndNoPdf()
    {
        using var dir = new TempDir();
        string file = dir.File("name.pdf", Pdfs.Text(2));
        var set = Set(dir, Step(BatchStepKind.Watermark, "DRAFT"), Step(BatchStepKind.ExportPictures));

        var result = await Run(Runner(), file, set);

        Assert.True(result.Ok, result.Detail);
        Assert.Equal(dir.Sub("out\name"), result.Output);
        Assert.Equal([dir.Sub("out\name\name page 1.png"), dir.Sub("out\name\name page 2.png")], Directory.GetFiles(result.Output!).Order());
        Assert.Empty(Directory.GetFiles(dir.Sub("out"), "*.pdf"));
        Assert.Contains("Saved 2 pictures in name.", result.Detail);
    }

    [Fact]
    public async Task ASecondRunOfExportPicturesMakesANewFolder()
    {
        using var dir = new TempDir();
        string file = dir.File("name.pdf", Pdfs.Text());
        var set = Set(dir, Step(BatchStepKind.ExportPictures));

        await Run(Runner(), file, set);
        var second = await Run(Runner(), file, set);

        Assert.Equal(dir.Sub("out\name (2)"), second.Output);
        Assert.True(File.Exists(dir.Sub("out\name (2)\name page 1.png")));
        Assert.Contains("Saved 1 picture in", second.Detail);
    }

    [Fact]
    public async Task ExportPicturesFailsWhenThePagesCannotBeDrawn()
    {
        using var dir = new TempDir();
        var runner = new BatchRunner(new FakeCodec(), new SystemFontSource(), new FakeRecognizer(), () => new FakeRenderer { Draws = false });

        var result = await Run(runner, dir.File("a.pdf", Pdfs.Text()), Set(dir, Step(BatchStepKind.ExportPictures)));

        Assert.False(result.Ok);
        Assert.Equal("Pages cannot be drawn", result.Title);
    }

    [Fact]
    public async Task ExportPicturesThatIsNotLastRefusesTheRun()
    {
        using var dir = new TempDir();

        var result = await Run(Runner(), dir.File("a.pdf", Pdfs.Text()), Set(dir, Step(BatchStepKind.ExportPictures), Step(BatchStepKind.Clean)));

        Assert.False(result.Ok);
        Assert.Equal("Export pictures must be the last step", result.Title);
        Assert.False(Directory.Exists(dir.Sub("out")));
    }

    [Fact]
    public void ThePictureSettingsOfASetAreSaved()
    {
        using var dir = new TempDir();
        var set = Set(dir, new BatchStep { Kind = BatchStepKind.ExportPictures, Picture = PictureFormat.Jpeg, Dpi = 300, Quality = 70 });
        set.Name = "Pictures";
        var store = new BatchSetStore(dir.Path);

        store.Save(set);

        var step = Assert.Single(Assert.Single(store.Load()).Steps);
        Assert.Equal((BatchStepKind.ExportPictures, PictureFormat.Jpeg, 300, 70), (step.Kind, step.Picture, step.Dpi, step.Quality));
    }
}
