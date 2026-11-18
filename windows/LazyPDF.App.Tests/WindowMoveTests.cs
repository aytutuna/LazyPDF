using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using LazyPDF.App.Documents;
using LazyPDF.App.Services;
using Xunit;

namespace LazyPDF.App.Tests;

// Moving a tab to a new window or another window from the tab's menu. Most windows are only built; a tear-out and the
// cases that need an owner for a batch window show real ones.
[Collection("Application")]
public sealed class WindowMoveTests
{
    private static string[] Headers(ItemsControl menu) => [.. menu.Items.OfType<MenuItem>().Select(i => (string)i.Header)];

    [Fact]
    public Task TheMenuOffersANewWindowAndTheOtherWindowsByTitle() => Sta.Run(async () =>
    {
        using var rig = new WindowCloseTests.Rig();
        await rig.Both.A.Vm.OpenAsync(rig.Both.A.Pdf("a.pdf"));
        var tab = rig.Both.A.Vm.ActiveDocument!;

        var menu = rig.A.TabMenu(tab);

        Assert.Contains("Move to new window", Headers(menu));
        var submenu = menu.Items.OfType<MenuItem>().Single(i => (string)i.Header == "Move to window");
        Assert.Equal([rig.B.Title], Headers(submenu));
    });

    [Fact]
    public Task WithOneWindowOnlyTheNewWindowEntryIsOffered() => Sta.Run(async () =>
    {
        using var rig = new WindowCloseTests.Rig();
        await rig.Both.A.Vm.OpenAsync(rig.Both.A.Pdf("a.pdf"));
        rig.B.Close();

        var headers = Headers(rig.A.TabMenu(rig.Both.A.Vm.ActiveDocument!));

        Assert.Contains("Move to new window", headers);
        Assert.DoesNotContain("Move to window", headers);
    });

    [Fact]
    public Task MovingToAnotherWindowKeepsTheTabAndSaysSo() => Sta.Run(async () =>
    {
        using var rig = new WindowCloseTests.Rig();
        await rig.Both.A.Vm.OpenAsync(rig.Both.A.Pdf("a.pdf"));
        var tab = rig.Both.A.Vm.ActiveDocument!;

        Assert.True(rig.A.MoveTab(tab, rig.B, int.MaxValue));

        Assert.Same(tab, rig.Both.B.Vm.ActiveDocument);
        Assert.True(rig.Both.A.Vm.IsHome);
        Assert.Equal("Moved a.pdf to another window.", rig.Both.B.Vm.StatusFull);
        Assert.Contains(rig.A, WindowHub.Windows);
    });

    [Fact]
    public Task AnEmptiedSecondaryWindowClosesAndAnEmptiedFirstOneStays() => Sta.Run(async () =>
    {
        using var rig = new WindowCloseTests.Rig();
        await rig.Both.B.Vm.OpenAsync(rig.Both.B.Pdf("b.pdf"));
        var tab = rig.Both.B.Vm.ActiveDocument!;

        Assert.True(rig.B.MoveTab(tab, rig.A, 1));

        Assert.DoesNotContain(rig.B, WindowHub.Windows);
        Assert.Same(tab, rig.Both.A.Vm.ActiveDocument);
        Assert.Contains(tab, rig.Both.A.Vm.Documents);
    });

    [Fact]
    public Task AFirstWindowThatIsEmptiedStays() => Sta.Run(async () =>
    {
        using var rig = new WindowCloseTests.Rig();
        await rig.Both.A.Vm.OpenAsync(rig.Both.A.Pdf("a.pdf"));

        Assert.True(rig.A.MoveTab(rig.Both.A.Vm.ActiveDocument!, rig.B, 1));

        Assert.Contains(rig.A, WindowHub.Windows);
    });

    [Fact]
    public Task ATornOutTabLivesInAWindowOfItsOwnWithItsEdits() => Sta.Run(async () =>
    {
        using var rig = new WindowCloseTests.Rig();
        await rig.Both.A.Vm.OpenAsync(rig.Both.A.Pdf("a.pdf"));
        var tab = rig.Both.A.Vm.ActiveDocument!;
        Pdfs.Retitle(tab.Session, "Edited");
        tab.Commit("Properties");
        int before = WindowHub.Windows.Count;

        Assert.True(rig.A.TearOut(tab));

        Assert.Equal(before + 1, WindowHub.Windows.Count);
        var owner = rig.Both.Registry.Find(tab.Id)!;
        Assert.NotSame(rig.Both.A.Vm, owner);
        Assert.Equal("Properties", owner.UndoLabel);
        Assert.True(tab.IsDirty);
        Assert.True(rig.Both.A.Vm.IsHome);
        owner.Close(tab);
    });

    [Fact]
    public Task ATearOutThatIsRefusedLeavesNoWindowBehind() => Sta.Run(async () =>
    {
        using var rig = new WindowCloseTests.Rig();
        await rig.Both.A.Vm.OpenAsync(rig.Both.A.Pdf("a.pdf"));
        var tab = rig.Both.A.Vm.ActiveDocument!;
        var finish = new TaskCompletionSource();
        var started = new TaskCompletionSource();
        var run = rig.Both.A.Vm.RunBusyAsync("Working", async _ =>
        {
            started.SetResult();
            await finish.Task;
        });
        await started.Task;
        int before = WindowHub.Windows.Count;

        Assert.False(rig.A.TearOut(tab));

        Assert.Equal(before, WindowHub.Windows.Count);
        Assert.Same(rig.Both.A.Vm, rig.Both.Registry.Find(tab.Id));
        Assert.Equal("Tab not moved", rig.Both.A.Vm.Message?.Title);
        finish.SetResult();
        await run;
    });

    [Fact]
    public Task AnEmptiedSecondaryThatTornOutItsLastTabCloses() => Sta.Run(async () =>
    {
        using var rig = new WindowCloseTests.Rig();
        await rig.Both.B.Vm.OpenAsync(rig.Both.B.Pdf("b.pdf"));
        var tab = rig.Both.B.Vm.ActiveDocument!;

        Assert.True(rig.B.TearOut(tab));

        Assert.DoesNotContain(rig.B, WindowHub.Windows);
        Assert.NotNull(rig.Both.Registry.Find(tab.Id));
    });

    private static System.Collections.IDictionary OpenBatches() => (System.Collections.IDictionary)typeof(LazyPDF.App.Tools.Batch.BatchWindow)
        .GetField("Opened", System.Reflection.BindingFlags.Static | System.Reflection.BindingFlags.NonPublic)!.GetValue(null)!;

    [Fact]
    public Task AnEmptiedSecondaryWaitsForItsBatchWindowAndClosesOnceItIsGone() => Sta.Run(async () =>
    {
        using var rig = new WindowCloseTests.Rig();
        rig.B.Show();
        await rig.Both.B.Vm.OpenAsync(rig.Both.B.Pdf("b.pdf"));
        LazyPDF.App.Tools.Batch.BatchWindow.Open(rig.B, rig.Both.B.Vm);
        var batch = Application.Current.Windows.OfType<LazyPDF.App.Tools.Batch.BatchWindow>().Single();

        Assert.True(rig.B.MoveTab(rig.Both.B.Vm.ActiveDocument!, rig.A, 1));

        Assert.Contains(rig.B, WindowHub.Windows);
        batch.Close();
        Assert.DoesNotContain(rig.B, WindowHub.Windows);
        Assert.False(OpenBatches().Contains(rig.Both.B.Vm));
    });

    [Fact]
    public Task ClosingAnEmptiedSecondaryWithItsBatchWindowOpenDoesNotCloseItTwice() => Sta.Run(async () =>
    {
        using var rig = new WindowCloseTests.Rig();
        rig.B.Show();
        await rig.Both.B.Vm.OpenAsync(rig.Both.B.Pdf("b.pdf"));
        await rig.Both.B.Vm.OpenAsync(rig.Both.B.Pdf("c.pdf"));
        LazyPDF.App.Tools.Batch.BatchWindow.Open(rig.B, rig.Both.B.Vm);
        var first = rig.Both.B.Vm.Documents.First();
        var second = rig.Both.B.Vm.Documents.Last();
        Assert.True(rig.B.MoveTab(first, rig.A, 1));
        Assert.True(rig.B.MoveTab(second, rig.A, 1));

        rig.B.Close();

        Assert.DoesNotContain(rig.B, WindowHub.Windows);
        Assert.False(OpenBatches().Contains(rig.Both.B.Vm));
    });

    [Fact]
    public Task AnEmptiedSecondaryWithAFileAtItsPasswordQuestionStaysUntilItIsAnswered() => Sta.Run(async () =>
    {
        using var rig = new WindowCloseTests.Rig();
        await rig.Both.B.Vm.OpenAsync(rig.Both.B.Pdf("b.pdf"));
        string locked = rig.Both.B.Dir.File("locked.pdf", File.ReadAllBytes(Pdfs.Fixture("locked.pdf")));
        await rig.Both.B.Vm.OpenAsync(locked);
        Assert.NotNull(rig.Both.B.Vm.PasswordRequest);

        Assert.True(rig.B.MoveTab(rig.Both.B.Vm.ActiveDocument!, rig.A, 1));

        Assert.Contains(rig.B, WindowHub.Windows);
        Assert.NotNull(rig.Both.B.Vm.PasswordRequest);
        rig.Both.B.Vm.CancelPending();
        await Dispatcher.Yield(DispatcherPriority.Background);
        Assert.DoesNotContain(rig.B, WindowHub.Windows);
    });

    private static readonly Rect Strip = new(100, 50, 800, 36);

    [Theory]
    [InlineData(DragDropEffects.None, false, 500, 400, MainWindow.DragOutcome.TearOut)]
    [InlineData(DragDropEffects.None, false, 500, 120, MainWindow.DragOutcome.Nothing)]
    [InlineData(DragDropEffects.None, false, 500, -20, MainWindow.DragOutcome.TearOut)]
    [InlineData(DragDropEffects.None, false, 1400, 60, MainWindow.DragOutcome.TearOut)]
    [InlineData(DragDropEffects.None, true, 500, 400, MainWindow.DragOutcome.Nothing)]
    [InlineData(DragDropEffects.Move, false, 500, 400, MainWindow.DragOutcome.Nothing)]
    public void ADragNobodyTookOpensAWindowOnlyWhenItEndsFarFromTheStrip(DragDropEffects result, bool escaped, double x, double y, MainWindow.DragOutcome expected) =>
        Assert.Equal(expected, MainWindow.OutcomeOf(result, escaped, false, new(x, y), Strip, 60));

    [Fact]
    public void ADropOnAnotherWindowsStripIsCarriedOutEvenFarFromThisOne() =>
        Assert.Equal(MainWindow.DragOutcome.MoveToWindow, MainWindow.OutcomeOf(DragDropEffects.Move, false, true, new(500, 400), Strip, 60));

    [Fact]
    public Task TheDraggedIdFindsTheTabInAnyWindowAndAForeignIdFindsNothing() => Sta.Run(async () =>
    {
        using var rig = new WindowCloseTests.Rig();
        await rig.Both.A.Vm.OpenAsync(rig.Both.A.Pdf("a.pdf"));
        var tab = rig.Both.A.Vm.ActiveDocument!;

        Assert.Same(tab, rig.B.DraggedTab(new DataObject(MainWindow.TabIdFormat, tab.Id.ToString())));
        Assert.Null(rig.B.DraggedTab(new DataObject(MainWindow.TabIdFormat, Guid.NewGuid().ToString())));
        Assert.Null(rig.B.DraggedTab(new DataObject(MainWindow.TabIdFormat, "not an id")));
    });

    [Fact]
    public Task ADropOnAnotherStripIsOnlyNotedAndTheTabStaysUntilTheSourceMovesIt() => Sta.Run(async () =>
    {
        using var rig = new WindowCloseTests.Rig();
        await rig.Both.A.Vm.OpenAsync(rig.Both.A.Pdf("a.pdf"));
        await rig.Both.B.Vm.OpenAsync(rig.Both.B.Pdf("b.pdf"));
        await rig.Both.B.Vm.OpenAsync(rig.Both.B.Pdf("c.pdf"));
        var tab = rig.Both.A.Vm.ActiveDocument!;

        // Over the first document tab, then over empty space.
        Assert.Equal(DragDropEffects.Move, rig.B.DropTab(tab, rig.Both.B.Vm.Strip[1]));
        Assert.Equal((rig.B, 1), WindowHub.Dropped);
        Assert.Equal(DragDropEffects.Move, rig.B.DropTab(tab, null));
        Assert.Equal((rig.B, 3), WindowHub.Dropped);
        Assert.Contains(tab, rig.Both.A.Vm.Documents);

        Assert.True(rig.A.MoveTab(tab, WindowHub.Dropped!.Value.Window, WindowHub.Dropped.Value.Index));
        Assert.Equal(tab, rig.Both.B.Vm.Documents.Last());
    });

    [Fact]
    public Task ADropOfAnIdNobodyOwnsIsRefusedAndNoted() => Sta.Run(() =>
    {
        using var rig = new WindowCloseTests.Rig();

        Assert.Equal(DragDropEffects.None, rig.B.DropTab(null, null));
        Assert.Null(WindowHub.Dropped);
        return Task.CompletedTask;
    });

    [Fact]
    public Task ADropOnTheSameStripReordersAtOnce() => Sta.Run(async () =>
    {
        using var rig = new WindowCloseTests.Rig();
        await rig.Both.A.Vm.OpenAsync(rig.Both.A.Pdf("a.pdf"));
        await rig.Both.A.Vm.OpenAsync(rig.Both.A.Pdf("b.pdf"));
        var first = rig.Both.A.Vm.Documents.First();

        rig.A.DropTab(first, null);

        Assert.Equal(first, rig.Both.A.Vm.Documents.Last());
        Assert.Null(WindowHub.Dropped);
    });
}
