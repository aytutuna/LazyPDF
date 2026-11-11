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
    public Task AFolderThatCannotBeListedShowsAProblem() => Sta.Run(() =>
    {
        var host = new RecordingHost();
        var panel = new BatchPanel();
        panel.AttachHost(host);
        var missing = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N"), "scans");

        Assert.Empty(panel.PdfsIn(missing));
        var problem = Assert.Single(host.Problems);
        Assert.Contains("scans", problem.Text);
        return Task.CompletedTask;
    });

    [Fact]
    public Task AFolderIsListedInNameOrder() => Sta.Run(() =>
    {
        var folder = Directory.CreateTempSubdirectory();
        try
        {
            foreach (var name in new[] { "b.pdf", "A.pdf", "c.txt" }) File.WriteAllText(Path.Combine(folder.FullName, name), "x");
            var panel = new BatchPanel();
            Assert.Equal(["A.pdf", "b.pdf"], panel.PdfsIn(folder.FullName).Select(Path.GetFileName));
        }
        finally
        {
            folder.Delete(true);
        }
        return Task.CompletedTask;
    });

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

    private sealed class RecordingHost : IToolHost
    {
        public List<Problem> Problems { get; } = [];
        public List<string> Statuses { get; } = [];

        public Task RunBusyAsync(string text, Func<CancellationToken, Task> work) => work(CancellationToken.None);
        public void ShowProblem(Problem problem) => Problems.Add(problem);
        public void ShowNotice(string title, string text, NoticeAction? action = null) { }
        public void SetStatus(string sentence) => Statuses.Add(sentence);
        public Task OpenAsync(string path) => Task.CompletedTask;
        public Task<bool> OpenNewAsync(byte[] pdf, string title) => Task.FromResult(true);
        public Task ReloadAsync(DocumentTab tab) => Task.CompletedTask;
    }
}
