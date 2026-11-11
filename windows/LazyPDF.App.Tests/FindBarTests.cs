using System.Windows.Threading;
using LazyPDF.App.Viewer;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

[Collection("Application")]
public sealed class FindBarTests
{
    [Fact]
    public Task OpeningAgainSearchesTheTextLeftInTheBox() => Sta.Run(async () =>
    {
        var bytes = Pdfs.Text(2, "The quick brown fox jumps over the lazy dog.");
        var ui = Dispatcher.CurrentDispatcher;
        var search = new ViewerSearch(() => TextSource.OpenAsync(bytes, null), () => 0, action => ui.InvokeAsync(action));
        var bar = new FindBar();
        bar.Attach(search);
        bar.Query.Text = "fox";
        await Sta.Until(() => search.Query == "fox");
        await Sta.Until(() => !search.Running);

        search.Clear();
        Assert.Equal("", search.Query);
        bar.Open();

        Assert.Equal("fox", search.Query);
        await Sta.Until(() => !search.Running);
        Assert.Equal(2, search.Hits.Count);
    });

    [Fact]
    public Task OpeningKeepsTextStillBeingTypedAndShowsTheRunningOptions() => Sta.Run(async () =>
    {
        var bytes = Pdfs.Text(2, "The quick brown fox jumps over the lazy dog.");
        var ui = Dispatcher.CurrentDispatcher;
        var search = new ViewerSearch(() => TextSource.OpenAsync(bytes, null), () => 0, action => ui.InvokeAsync(action));
        var bar = new FindBar();
        bar.Attach(search);
        await search.Start("fox", new TextSearchOptions(MatchCase: true, WholeWord: true));
        await Sta.Until(() => !search.Running);

        bar.Open();
        Assert.Equal("fox", bar.Query.Text);
        Assert.True(bar.CaseToggle.IsChecked);
        Assert.True(bar.WordToggle.IsChecked);
        Assert.False(bar.RegexToggle.IsChecked);

        int changes = 0;
        search.Changed += (_, _) => changes++;
        await Task.Delay(500);
        Assert.Equal(0, changes);

        bar.Query.Text = "dog";
        bar.Open();

        Assert.Equal("dog", bar.Query.Text);
    });
}
