using System.Reflection;
using System.Windows;
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
}
