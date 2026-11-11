using System.Reflection;
using System.Windows;
using LazyPDF.App.Tools.Batch;
using Xunit;

namespace LazyPDF.App.Tests;

[Collection("Application")]
public sealed class BatchDropTests
{
    private static DragEventArgs Drop(UIElement target, params string[] paths)
    {
        var make = typeof(DragEventArgs).GetConstructors(BindingFlags.Instance | BindingFlags.NonPublic).Single();
        var data = new DataObject(DataFormats.FileDrop, paths);
        var e = (DragEventArgs)make.Invoke([data, DragDropKeyStates.None, DragDropEffects.Copy, target, new Point()]);
        e.RoutedEvent = UIElement.DropEvent;
        e.Source = target;
        return e;
    }

    [Fact]
    public Task DroppedPdfsAreListedAndOtherFilesIgnored() => Sta.Run(() =>
    {
        var panel = new BatchPanel();
        panel.RaiseEvent(Drop(panel, @"C:\x\a.pdf", @"C:\x\b.txt"));

        var rows = Assert.IsAssignableFrom<IEnumerable<FileRow>>(panel.FileList.ItemsSource);
        Assert.Equal([@"C:\x\a.pdf"], rows.Select(r => r.Path));
        return Task.CompletedTask;
    });
}
