using System.Text;
using LazyPDF.App.Tools.Batch;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// Names from the template, saved sets, and the folder watcher.
public sealed class BatchSetTests
{
    private static readonly DateTimeOffset Date = new(2026, 3, 9, 12, 0, 0, TimeSpan.Zero);

    [Theory]
    [InlineData("{name}", "invoice.pdf")]
    [InlineData("", "invoice.pdf")]
    [InlineData("{name}-clean", "invoice-clean.pdf")]
    [InlineData("{date}_{name}", "2026-03-09_invoice.pdf")]
    [InlineData("{date:yyyyMMdd}-{n:000}", "20260309-004.pdf")]
    [InlineData("{name}.pdf", "invoice.pdf")]
    [InlineData("a/b:{name}", "a_b_invoice.pdf")]
    [InlineData("{other}", "{other}.pdf")]
    public void TheTemplateMakesTheFileName(string template, string expected) =>
        Assert.Equal(expected, BatchNames.Apply(template, "invoice", 4, Date));

    [Fact]
    public void SetsAreKeptByNameWithTheirSettings()
    {
        using var dir = new TempDir();
        var store = new BatchSetStore(dir.Path);
        var steps = new List<BatchStep>
        {
            new() { Kind = BatchStepKind.Bates, Text = "X-", Digits = 8, Start = 40 },
            new() { Kind = BatchStepKind.Compress, Preset = OptimizePreset.Small },
            new() { Kind = BatchStepKind.PdfA, Level = PdfALevel.A3u },
        };

        store.Save(new BatchSet { Name = "Cases", Steps = steps, OutputFolder = "C:\\out", NameTemplate = "{name}-b", WatchFolder = "C:\\in" });
        store.Save(new BatchSet { Name = "Other" });
        store.Save(new BatchSet { Name = "cases", OutputFolder = "C:\\again" });

        var loaded = new BatchSetStore(dir.Path).Load();
        Assert.Equal(["Other", "cases"], loaded.Select(s => s.Name).Order(StringComparer.Ordinal));
        Assert.Equal("C:\\again", loaded.Single(s => s.Name == "cases").OutputFolder);

        store.Save(new BatchSet { Name = "Cases", Steps = steps, NameTemplate = "{name}-b" });
        var back = new BatchSetStore(dir.Path).Load().Single(s => s.Name == "Cases");
        Assert.Equal([BatchStepKind.Bates, BatchStepKind.Compress, BatchStepKind.PdfA], back.Steps.Select(s => s.Kind));
        Assert.Equal(("X-", 8, 40L), (back.Steps[0].Text, back.Steps[0].Digits, back.Steps[0].Start));
        Assert.Equal(OptimizePreset.Small, back.Steps[1].Preset);
        Assert.Equal(PdfALevel.A3u, back.Steps[2].Level);
        Assert.Equal("{name}-b", back.NameTemplate);

        store.Delete("cases");
        Assert.Equal(["Other"], new BatchSetStore(dir.Path).Load().Select(s => s.Name));
    }

    [Fact]
    public void ANewCleanStepKeepsWhatPeopleCanSee()
    {
        var step = BatchStep.Of(BatchStepKind.Clean);
        Assert.Equal((true, true, true, false), (step.KeepComments, step.KeepForms, step.KeepLinks, step.KeepAttachments));
    }

    [Fact]
    public void ASavedCleanStepKeepsItsOwnFlags()
    {
        using var dir = new TempDir();
        dir.File("batch-sets.json", Encoding.UTF8.GetBytes("""{"sets":[{"name":"Strip","steps":[{"kind":"clean"}]}]}"""));
        var step = new BatchSetStore(dir.Path).Load().Single().Steps.Single();
        Assert.Equal((false, false, false), (step.KeepComments, step.KeepForms, step.KeepLinks));
        var fresh = BatchStep.Of(BatchStepKind.Clean);
        Assert.Equal((true, true, true), (fresh.KeepComments, fresh.KeepForms, fresh.KeepLinks));
    }

    [Fact]
    public void AnUnreadableSetsFileGivesNoSets()
    {
        using var dir = new TempDir();
        dir.File("batch-sets.json", Encoding.UTF8.GetBytes("not json"));

        Assert.Empty(new BatchSetStore(dir.Path).Load());
    }

    [Fact]
    public void ACopyDoesNotFollowLaterEdits()
    {
        var set = new BatchSet { Steps = [new() { Kind = BatchStepKind.Watermark, Text = "A" }] };

        var copy = set.Copy();
        set.Steps[0].Text = "B";
        set.Steps.Add(new BatchStep());

        Assert.Equal("A", Assert.Single(copy.Steps).Text);
    }

    [Fact]
    public void StopOnErrorSurvivesTheStoreAndACopy()
    {
        using var dir = new TempDir();
        new BatchSetStore(dir.Path).Save(new BatchSet { Name = "Cases", StopOnError = true });

        Assert.True(new BatchSetStore(dir.Path).Load().Single().StopOnError);
        Assert.True(new BatchSet { StopOnError = true }.Copy().StopOnError);
        Assert.False(new BatchSet().StopOnError);
    }

    [Fact]
    public async Task TheWatcherReportsANewPdfOnceAndNotTheOnesAlreadyThere()
    {
        using var dir = new TempDir();
        dir.File("old.pdf", Pdfs.Text());
        using var watcher = new FolderWatcher(dir.Path, TimeSpan.FromMilliseconds(100));
        var found = new TaskCompletionSource<string>();
        var all = new List<string>();
        watcher.Found += path =>
        {
            all.Add(path);
            found.TrySetResult(path);
        };

        string made = dir.File("new.pdf", Pdfs.Text());
        dir.File("note.txt", [1]);

        Assert.Equal(made, await found.Task.WaitAsync(TimeSpan.FromSeconds(10)));
        await Task.Delay(500);
        Assert.Equal([made], all);
    }

    [Fact]
    public async Task NothingIsReportedAfterTheWatcherIsDisposed()
    {
        using var dir = new TempDir();
        dir.File("old.pdf", Pdfs.Text());
        var watcher = new FolderWatcher(dir.Path, TimeSpan.FromMilliseconds(100));
        var all = new List<string>();
        watcher.Found += all.Add;

        dir.File("new.pdf", Pdfs.Text());
        watcher.Dispose();
        await Task.Delay(600);

        Assert.Empty(all);
    }
}
