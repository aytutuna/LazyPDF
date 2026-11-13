using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Threading;
using LazyPDF.App.Documents;
using LazyPDF.App.Panels.Search;
using LazyPDF.App.Viewer;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

[Collection("Application")]
public sealed class SearchPanelTests
{
    private static (SearchSidePanel Panel, ViewerSearch Search, DocumentTab Tab) Open(byte[] bytes)
    {
        var ui = Dispatcher.CurrentDispatcher;
        var search = new ViewerSearch(() => TextSource.OpenAsync(bytes, null), () => 0, action => ui.InvokeAsync(action));
        var tab = new DocumentTab(PdfEditSession.Open(bytes), new FakeRenderer(), null, "a.pdf", null);
        var panel = new SearchSidePanel();
        panel.Attach(tab, FakeViewer.Create(search), new RecordingHost());
        return (panel, search, tab);
    }

    [Fact]
    public Task ALateBatchDoesNotOverwriteWhatIsBeingTyped() => Sta.Run(async () =>
    {
        var (panel, search, tab) = Open(Pdfs.Text(2, "The quick brown fox jumps over the lazy dog."));
        using var _ = tab;
        var box = (TextBox)panel.FindName("Query");
        box.Text = "b";

        await search.Start("fo", new TextSearchOptions());
        await Sta.Until(() => !search.Running);

        Assert.Equal("b", box.Text);
    });

    [Fact]
    public Task AFileWithoutTextSaysToMakeItSearchable() => Sta.Run(async () =>
    {
        var (panel, search, tab) = Open(PdfFromText.Create("", new FakeFonts()).Bytes);
        using var _ = tab;

        await search.Start("fox", new TextSearchOptions());
        await Sta.Until(() => !search.Running);

        Assert.Equal(Loc.T("This file has no text to search. Try Make searchable."), ((System.Windows.Controls.TextBlock)panel.FindName("Summary")).Text);
    });

    [Fact]
    public Task APageHiddenBehindAToolIsSaid() => Sta.Run(() =>
    {
        var (panel, _, tab) = Open(Pdfs.Text(1, "fox"));
        using var _ = tab;

        Assert.Equal(Visibility.Visible, ((UIElement)panel.FindName("StageNote")).Visibility);
        return Task.CompletedTask;
    });

    [Fact]
    public Task StopShowsWhileSearchingAndTheCapIsSaid() => Sta.Run(async () =>
    {
        var (panel, search, tab) = Open(Pdfs.Text(ViewerSearch.MaxHits + 20, "fox"));
        using var _ = tab;
        var stop = (Button)panel.FindName("StopButton");
        var summary = (System.Windows.Controls.TextBlock)panel.FindName("Summary");

        var run = search.Start("fox", new TextSearchOptions());
        Assert.Equal(Visibility.Visible, stop.Visibility);
        await run;
        await Sta.Until(() => !search.Running);

        Assert.Equal(Visibility.Collapsed, stop.Visibility);
        Assert.EndsWith(Loc.T("First {0} shown. Narrow the search to see the rest.", ViewerSearch.MaxHits), summary.Text);
    });

    [Fact]
    public Task StoppingSaysSoInTheSummary() => Sta.Run(async () =>
    {
        var (panel, search, tab) = Open(Pdfs.Text(2, "fox"));
        using var _ = tab;
        var summary = (System.Windows.Controls.TextBlock)panel.FindName("Summary");

        var run = search.Start("fox", new TextSearchOptions());
        ((Button)panel.FindName("StopButton")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));

        Assert.Equal(Loc.T("Stopped"), summary.Text);
        await run;
    });

    [Fact]
    public Task AShownPageSaysNothing() => Sta.Run(() =>
    {
        var bytes = Pdfs.Text(1, "fox");
        var ui = Dispatcher.CurrentDispatcher;
        var search = new ViewerSearch(() => TextSource.OpenAsync(bytes, null), () => 0, action => ui.InvokeAsync(action));
        using var tab = new DocumentTab(PdfEditSession.Open(bytes), new FakeRenderer(), null, "a.pdf", null);
        var viewer = FakeViewer.Create(search);
        var window = new Window { Content = viewer.View };
        window.Show();
        var panel = new SearchSidePanel();
        panel.Attach(tab, viewer, new RecordingHost());

        Assert.Equal(Visibility.Collapsed, ((UIElement)panel.FindName("StageNote")).Visibility);

        window.Content = null;
        Assert.Equal(Visibility.Visible, ((UIElement)panel.FindName("StageNote")).Visibility);
        window.Close();
        return Task.CompletedTask;
    });

    // The panel listens to the left-button events, which WPF raises from the generic ones.
    private static void Click(ListBoxItem item)
    {
        item.RaiseEvent(new MouseButtonEventArgs(Mouse.PrimaryDevice, 0, MouseButton.Left) { RoutedEvent = UIElement.PreviewMouseDownEvent });
        item.RaiseEvent(new MouseButtonEventArgs(Mouse.PrimaryDevice, 0, MouseButton.Left) { RoutedEvent = UIElement.MouseDownEvent });
        item.RaiseEvent(new MouseButtonEventArgs(Mouse.PrimaryDevice, 0, MouseButton.Left) { RoutedEvent = UIElement.PreviewMouseUpEvent });
    }

    [Fact]
    public Task ClickingTheCurrentResultGoesToItAgain() => Sta.Run(async () =>
    {
        var (panel, search, tab) = Open(Pdfs.Text(3, "The quick brown fox jumps over the lazy dog."));
        using var _ = tab;
        var window = new Window { Content = panel };
        window.Show();
        await search.Start("fox", new TextSearchOptions());
        await Sta.Until(() => !search.Running);
        var results = (ListBox)panel.FindName("Results");
        results.UpdateLayout();
        int moves = 0;
        search.CurrentChanged += (_, _) => moves++;
        Assert.Equal(3, search.Hits.Count);

        Click((ListBoxItem)results.ItemContainerGenerator.ContainerFromIndex(search.Current));
        Assert.Equal(1, moves);

        int other = search.Current == 2 ? 1 : 2;
        Click((ListBoxItem)results.ItemContainerGenerator.ContainerFromIndex(other));
        Assert.Equal(2, moves);
        Assert.Equal(other, search.Current);
        window.Close();
    });
}
