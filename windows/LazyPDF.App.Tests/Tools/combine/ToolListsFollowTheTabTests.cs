using System.Collections.ObjectModel;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Windows;
using LazyPDF.App.Documents;
using LazyPDF.App.Tools;
using LazyPDF.App.Tools.Combine;
using LazyPDF.App.Tools.Compare;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// What Combine and Compare keep for a tab belongs to the tab, not to the panel that showed it, so a panel in another window finds it.
[Collection("Application")]
public sealed class ToolListsFollowTheTabTests
{
    private static DocumentTab Open() =>
        new(PdfEditSession.Open(Pdfs.Text(2), (string?)null), new FakeRenderer(), null, "a.pdf", null);

    private static void Attach(ToolPanel panel, DocumentTab tab) => panel.Attach(tab, FakeViewer.Create().Viewer, new RecordingHost());

    private static ObservableCollection<CombineEntry> ListOf(CombinePanel panel) => (ObservableCollection<CombineEntry>)panel.Files.ItemsSource;

    [Fact]
    public Task AFileAddedInAnotherPanelAfterAMoveUpdatesTheButton() => Sta.Run(() =>
    {
        using var tab = Open();
        var before = new CombinePanel();
        Attach(before, tab);
        ListOf(before).Add(new CombineEntry("b.pdf", 1, null, "b.pdf"));
        before.Detach();

        var after = new CombinePanel();
        Attach(after, tab);
        Assert.Same(ListOf(before), ListOf(after));
        Assert.Equal(2, ListOf(after).Count);
        ListOf(after).RemoveAt(1);
        Assert.False(after.Action!.CanRun());
        int changed = 0;
        after.ActionChanged += (_, _) => changed++;
        ListOf(after).Add(new CombineEntry("c.pdf", 1, null, "c.pdf"));

        Assert.True(after.Action.CanRun());
        Assert.True(changed > 0);
        return Task.CompletedTask;
    });

    [Fact]
    public Task APanelThatLetGoOfTheTabNoLongerHearsItsList() => Sta.Run(() =>
    {
        using var tab = Open();
        var before = new CombinePanel();
        Attach(before, tab);
        int changed = 0;
        before.ActionChanged += (_, _) => changed++;
        before.Detach();
        var after = new CombinePanel();
        Attach(after, tab);

        ListOf(after).Add(new CombineEntry("b.pdf", 1, null, "b.pdf"));

        Assert.Equal(0, changed);
        return Task.CompletedTask;
    });

    [Fact]
    public Task AComparisonKeptForATabShowsInAnotherPanel() => Sta.Run(() =>
    {
        using var tab = Open();
        var held = new HeldComparison(CompareKit.Session(CompareKit.Before(), CompareKit.After()), null, true, tab.Revision);
        var table = (ConditionalWeakTable<DocumentTab, HeldComparison>)typeof(ComparePanel)
            .GetField("Held", BindingFlags.Static | BindingFlags.NonPublic)!.GetValue(null)!;
        table.Add(tab, held);
        try
        {
            var panel = new ComparePanel(() => new FakeRenderer(), new FakeFonts());
            Attach(panel, tab);

            Assert.Equal(Visibility.Visible, panel.ResultGroup.Visibility);
        }
        finally
        {
            table.Remove(tab);
            held.Dispose();
        }
        return Task.CompletedTask;
    });
}
