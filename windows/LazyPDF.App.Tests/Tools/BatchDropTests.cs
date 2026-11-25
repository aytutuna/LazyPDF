using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows;
using LazyPDF.App.Documents;
using LazyPDF.App.Tools;
using LazyPDF.App.Tools.Batch;
using Xunit;

namespace LazyPDF.App.Tests;

[Collection("Application")]
public sealed class BatchDropTests
{
    internal static DragEventArgs Drop(UIElement target, DataObject data)
    {
        var make = typeof(DragEventArgs).GetConstructors(BindingFlags.Instance | BindingFlags.NonPublic).Single();
        var e = (DragEventArgs)make.Invoke([data, DragDropKeyStates.None, DragDropEffects.Copy, target, new Point()]);
        e.RoutedEvent = UIElement.PreviewDropEvent;
        e.Source = target;
        return e;
    }

    internal static DragEventArgs Drop(UIElement target, params string[] paths) => Drop(target, new DataObject(DataFormats.FileDrop, paths));

    [Fact]
    public Task DroppedPdfsAreListedAndOtherFilesIgnored() => Sta.Run(() =>
    {
        var panel = new BatchPanel();
        panel.RaiseEvent(Drop(panel, @"C:\x\a.pdf", @"C:\x\b.txt"));

        var rows = Assert.IsAssignableFrom<IEnumerable<FileRow>>(panel.FileList.ItemsSource);
        Assert.Equal([@"C:\x\a.pdf"], rows.Select(r => r.Path));
        return Task.CompletedTask;
    });

    [Fact]
    public Task AFileDroppedOnTheTemplateBoxIsListed() => Sta.Run(() =>
    {
        var panel = new BatchPanel();
        var e = Drop(panel.TemplateBox, @"C:\x\a.pdf");
        panel.TemplateBox.RaiseEvent(e);

        var rows = Assert.IsAssignableFrom<IEnumerable<FileRow>>(panel.FileList.ItemsSource);
        Assert.Equal([@"C:\x\a.pdf"], rows.Select(r => r.Path));
        Assert.True(e.Handled);
        return Task.CompletedTask;
    });

    [Fact]
    public Task TextDroppedOnTheTemplateBoxIsLeftToTheBox() => Sta.Run(() =>
    {
        var panel = new BatchPanel();
        var e = Drop(panel.TemplateBox, new DataObject(DataFormats.Text, "name"));
        panel.TemplateBox.RaiseEvent(e);

        Assert.False(e.Handled);
        return Task.CompletedTask;
    });

    [Fact]
    public Task APathThatIsNeitherAFolderNorAPdfAddsNothing() => Sta.Run(() =>
    {
        var host = new RecordingHost();
        var panel = new BatchPanel();
        panel.AttachHost(host);
        panel.RaiseEvent(Drop(panel, Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N"), "gone")));

        Assert.Empty(Assert.IsAssignableFrom<IEnumerable<FileRow>>(panel.FileList.ItemsSource));
        Assert.Equal(["Only PDF files can be added."], host.Statuses);
        return Task.CompletedTask;
    });

    [Fact]
    public Task AFolderThatCannotBeListedShowsAProblem() => Sta.Run(async () =>
    {
        var host = new RecordingHost();
        var panel = new BatchPanel();
        panel.AttachHost(host);
        var missing = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N"), "scans");

        Assert.Empty(await panel.PdfsInAsync(missing, true));
        var problem = Assert.Single(host.Problems);
        Assert.Contains("scans", problem.Text);
    });

    [Fact]
    public Task AFolderIsListedInNameOrder() => Sta.Run(async () =>
    {
        var folder = Directory.CreateTempSubdirectory();
        try
        {
            foreach (var name in new[] { "b.pdf", "A.pdf", "c.txt" }) File.WriteAllText(Path.Combine(folder.FullName, name), "x");
            var panel = new BatchPanel();
            Assert.Equal(["A.pdf", "b.pdf"], (await panel.PdfsInAsync(folder.FullName, false)).Select(Path.GetFileName));
        }
        finally
        {
            folder.Delete(true);
        }
    });

    [Fact]
    public Task ADroppedFolderAddsItsSubfoldersInPathOrder() => Sta.Run(() =>
    {
        using var dir = new TempDir();
        string top = dir.File("in\\b.pdf", Pdfs.Text());
        string inner = dir.File("in\\a\\x.pdf", Pdfs.Text());
        var panel = new BatchPanel();
        panel.RaiseEvent(Drop(panel, dir.Sub("in")));

        var rows = Assert.IsAssignableFrom<IEnumerable<FileRow>>(panel.FileList.ItemsSource);
        Assert.Equal([inner, top], rows.Select(r => r.Path));
        return Task.CompletedTask;
    });

    [Fact]
    public Task AFolderLinkThatLoopsBackIsNotFollowed() => Sta.Run(async () =>
    {
        using var dir = new TempDir();
        string file = dir.File("in\\a.pdf", Pdfs.Text());
        try
        {
            Directory.CreateSymbolicLink(dir.Sub("in\\loop"), dir.Sub("in"));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return;
        }
        Assert.Equal([file], await new BatchPanel().PdfsInAsync(dir.Sub("in"), true));
    });

    [Fact]
    public void TheResultsFolderInsideTheSourceIsLeftOut()
    {
        using var dir = new TempDir();
        string top = dir.File("scans\\a.pdf", Pdfs.Text());
        dir.File("scans\\done\\a.pdf", Pdfs.Text());

        var found = BatchPanel.Walk(dir.Sub("scans"), true, dir.Sub("scans\\done"), out bool leftOut, CancellationToken.None);

        Assert.Equal([top], found);
        Assert.True(leftOut);
    }

    [Fact]
    public void HiddenFoldersAreNotWalked()
    {
        using var dir = new TempDir();
        string top = dir.File("in\\a.pdf", Pdfs.Text());
        dir.File("in\\secret\\b.pdf", Pdfs.Text());
        File.SetAttributes(dir.Sub("in\\secret"), FileAttributes.Hidden);

        Assert.Equal([top], BatchPanel.Walk(dir.Sub("in"), true, null, out _, CancellationToken.None));
    }

    [Fact]
    public void AWalkStopsWhenCancelled()
    {
        using var dir = new TempDir();
        dir.File("in\\a.pdf", Pdfs.Text());
        using var source = new CancellationTokenSource(0);

        Assert.Throws<OperationCanceledException>(() => BatchPanel.Walk(dir.Sub("in"), true, null, out _, source.Token));
    }

    [Fact]
    public Task ThreeThousandPathsAreAddedQuickly() => Sta.Run(() =>
    {
        var panel = new BatchPanel();
        var paths = Enumerable.Range(0, 3000).Select(i => $@"C:\x\file{i}.pdf").ToList();
        var clock = Stopwatch.StartNew();
        panel.AddFiles(paths);
        panel.AddFiles(paths.Select(p => p.ToUpperInvariant()));

        Assert.True(clock.ElapsedMilliseconds < 1000);
        Assert.Equal(3000, Assert.IsAssignableFrom<IEnumerable<FileRow>>(panel.FileList.ItemsSource).Count());
        return Task.CompletedTask;
    });

    [Fact]
    public Task AFailedFileLeavesTheBatesStartAndTheSavedSetAlone() => Sta.Run(async () =>
    {
        using var dir = new TempDir();
        var store = new BatchSetStore(dir.Path);
        store.Save(new BatchSet { Name = "Cases", Steps = [new() { Kind = BatchStepKind.Bates, Start = 5 }, new() { Kind = BatchStepKind.Watermark }] });
        var panel = new BatchPanel();
        Field<BatchSetStore>(panel, "_store", store);
        var set = Field<BatchSet>(panel, "_set");
        var saved = store.Load().Single();
        set.Name = saved.Name;
        set.Steps = saved.Steps;
        set.OutputFolder = dir.Sub("out");
        var live = set.Steps.ToList();

        var failed = await panel.RunOneAsync(dir.File("a.pdf", Pdfs.Text(2)), set.Copy(), live, 1, CancellationToken.None);

        Assert.False(failed.Ok);
        Assert.Equal(5, live[0].Start);
        Assert.Equal(5, store.Load().Single().Steps[0].Start);

        set.Steps = [live[0]];
        var good = await panel.RunOneAsync(dir.File("b.pdf", Pdfs.Text(2)), set.Copy(), set.Steps, 2, CancellationToken.None);

        Assert.True(good.Ok, good.Detail);
        Assert.Equal(7, set.Steps[0].Start);
    });

    [Theory]
    [InlineData(true, 2, "Stopped at b.txt. 1 file was not run.")]
    [InlineData(false, 3, "1 file failed")]
    public Task AFailedFileStopsTheRunOnlyWhenAsked(bool stop, int rows, string status) => Sta.Run(async () =>
    {
        using var dir = new TempDir();
        var host = new RecordingHost();
        var panel = new BatchPanel();
        panel.AttachHost(host);
        var set = Field<BatchSet>(panel, "_set");
        set.Steps = [new() { Kind = BatchStepKind.Watermark, Text = "X" }];
        set.OutputFolder = dir.Sub("out");
        set.StopOnError = stop;
        string a = dir.File("a.pdf", Pdfs.Text());
        string b = dir.File("b.txt", "not a pdf"u8.ToArray());
        string c = dir.File("c.pdf", Pdfs.Text());
        panel.AddFiles([a, b, c]);

        await panel.Action!.Run();

        Assert.Equal(rows, panel.LogList.Items.Count);
        var left = Assert.IsAssignableFrom<IEnumerable<FileRow>>(panel.FileList.ItemsSource).Select(r => r.Path);
        Assert.Equal(stop ? [b, c] : [b], left);
        Assert.Equal(status, host.Statuses[^1]);
    });

    [Fact]
    public Task AFolderAddedDuringARunDoesNotTakeOverTheBusyState() => Sta.Run(async () =>
    {
        using var dir = new TempDir();
        string file = dir.File("in\\a.pdf", Pdfs.Text());
        var host = new RecordingHost();
        var panel = new BatchPanel();
        panel.AttachHost(host);
        typeof(BatchPanel).GetField("_running", BindingFlags.Instance | BindingFlags.NonPublic)!.SetValue(panel, true);

        Assert.Equal([file], await panel.PdfsInAsync(dir.Sub("in"), false));
        Assert.Equal(0, host.Busy);
    });

    [Fact]
    public Task TheOpenPasswordSurvivesUnloadWhileAFolderIsWatched() => Sta.Run(() =>
    {
        using var dir = new TempDir();
        var panel = new BatchPanel();
        var set = Field<BatchSet>(panel, "_set");
        set.Steps = [new() { Kind = BatchStepKind.Watermark, Text = "X" }];
        set.WatchFolder = dir.Sub("in");
        set.OutputFolder = dir.Sub("out");
        panel.OpenPassword.Password = "secret";
        Directory.CreateDirectory(set.WatchFolder);
        panel.WatchToggle.IsChecked = true;
        panel.WatchToggle.RaiseEvent(new RoutedEventArgs(System.Windows.Controls.Primitives.ButtonBase.ClickEvent));
        panel.RaiseEvent(new RoutedEventArgs(FrameworkElement.UnloadedEvent));
        try
        {
            Assert.Equal("secret", panel.OpenPassword.Password);
        }
        finally
        {
            panel.StopWatching();
        }
        panel.RaiseEvent(new RoutedEventArgs(FrameworkElement.UnloadedEvent));
        Assert.Equal("", panel.OpenPassword.Password);
        return Task.CompletedTask;
    });

    private static T Field<T>(BatchPanel panel, string name, T? value = null) where T : class
    {
        var field = typeof(BatchPanel).GetField(name, BindingFlags.Instance | BindingFlags.NonPublic)!;
        if (value is not null) field.SetValue(panel, value);
        return (T)field.GetValue(panel)!;
    }

    private sealed class RecordingHost : IToolHost
    {
        public List<Problem> Problems { get; } = [];
        public List<string> Statuses { get; } = [];

        public int Busy { get; private set; }

        public Task RunBusyAsync(string text, Func<CancellationToken, Task> work)
        {
            Busy++;
            return work(CancellationToken.None);
        }
        public void ShowProblem(Problem problem) => Problems.Add(problem);
        public void ShowNotice(string title, string text, NoticeAction? action = null) { }
        public void SetStatus(string sentence) => Statuses.Add(sentence);
        public Task OpenAsync(string path) => Task.CompletedTask;
        public Task<bool> OpenNewAsync(byte[] pdf, string title) => Task.FromResult(true);
        public Task ReloadAsync(DocumentTab tab) => Task.CompletedTask;
    }
}
