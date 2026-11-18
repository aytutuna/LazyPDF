using System.Reflection;
using System.Runtime.CompilerServices;
using System.Windows;
using LazyPDF.App.Documents;
using LazyPDF.App.Services;
using LazyPDF.App.Tools.Compare;
using Xunit;

namespace LazyPDF.App.Tests;

// What closing a window does to the others, the next start and the questions. Windows are built but never shown.
[Collection("Application")]
public sealed class WindowCloseTests
{
    /// <summary>Two main windows over two view models that share a registry, with preferences in a folder of their own.</summary>
    private sealed class Rig : IDisposable
    {
        private readonly TempDir _prefs = new();
        private readonly string _saved = StoreFiles.DefaultDirectory;

        public Rig()
        {
            StoreFiles.DefaultDirectory = _prefs.Path;
            AppPreferencesStore.Update(p => p.ReopenLast = true);
            Both = new TwoWindows();
            A = new MainWindow(Both.A.Vm, null, primary: true);
            B = new MainWindow(Both.B.Vm, null, primary: false);
            // A window that was never shown has no place, and one that cannot be written is not saved.
            (A.Left, A.Top, B.Left, B.Top) = (10, 10, 40, 40);
        }

        public TwoWindows Both { get; }
        public MainWindow A { get; }
        public MainWindow B { get; }
        public AppPreferences Saved => AppPreferencesStore.Load();

        public void Dispose()
        {
            foreach (var window in WindowHub.Windows.ToList())
            {
                window.Close();
                if (WindowHub.Windows.Contains(window)) throw new InvalidOperationException("A test left a window with a question open.");
            }
            WindowHub.Reset();
            Both.Dispose();
            StoreFiles.DefaultDirectory = _saved;
            _prefs.Dispose();
        }
    }

    [Fact]
    public void TheOwnedWorkQuestionIsAskedBeforeTheCloseBeginsAndNotWhenItComesBack()
    {
        Assert.True(MainWindow.AsksAboutOwnedWork(false, true, false));
        Assert.False(MainWindow.AsksAboutOwnedWork(true, true, false));
        Assert.False(MainWindow.AsksAboutOwnedWork(false, false, false));
        Assert.False(MainWindow.AsksAboutOwnedWork(false, true, true));
    }

    [Fact]
    public Task AnOpenComparisonCountsAsOwnedWorkAndKeepsItsTabFromMoving() => Sta.Run(async () =>
    {
        using var rig = new Rig();
        await rig.Both.A.Vm.OpenAsync(rig.Both.A.Pdf());
        var tab = rig.Both.A.Vm.ActiveDocument!;
        Assert.False(rig.Both.A.Vm.HasOwnedWork);
        var table = (ConditionalWeakTable<DocumentTab, HeldComparison>)typeof(ComparePanel)
            .GetField("Held", BindingFlags.Static | BindingFlags.NonPublic)!.GetValue(null)!;
        var held = new HeldComparison(CompareKit.Session(CompareKit.Before(), CompareKit.After()), null, true, tab.Revision);
        held.Window = new CompareWindow(held.Session, held.Session.Rows(Parts.Text));
        table.Add(tab, held);
        try
        {
            Assert.True(rig.Both.A.Vm.HasOwnedWork);
            Assert.False(rig.Both.A.Vm.CanRelease(tab, out var reason));
            Assert.Equal("Close the comparison first.", reason);
            Assert.False(rig.Both.B.Vm.HasOwnedWork);
        }
        finally
        {
            held.Window.Close();
            table.Remove(tab);
            held.Dispose();
        }
    });

    [Fact]
    public Task ClosingAWindowThatHoldsAnUnsavedQuestionAndAnswerItClosesWithoutAskingAgain() => Sta.Run(async () =>
    {
        using var rig = new Rig();
        await rig.Both.B.Vm.OpenAsync(rig.Both.B.Pdf("clean.pdf"));
        await rig.Both.B.Vm.OpenAsync(rig.Both.B.Pdf("edited.pdf"));
        var edited = rig.Both.B.Vm.ActiveDocument!;
        Pdfs.Retitle(edited.Session, "Edited");
        edited.Commit("Properties");

        rig.B.Close();
        Assert.Same(edited, rig.Both.B.Vm.CloseQuestion);
        Assert.Contains(rig.B, WindowHub.Windows);

        rig.Both.B.Vm.Close(edited);

        Assert.DoesNotContain(rig.B, WindowHub.Windows);
    });

    private static async Task<DocumentTab> OpenEdited(ViewModelFixture f, string name)
    {
        await f.Vm.OpenAsync(f.Pdf(name));
        var tab = f.Vm.ActiveDocument!;
        Pdfs.Retitle(tab.Session, name);
        tab.Commit("Properties");
        return tab;
    }

    [Fact]
    public Task AnEndedWindowsSessionIsNotCalledOffByAWindowThatDeclinesToClose() => Sta.Run(async () =>
    {
        using var rig = new Rig();
        var edited = await OpenEdited(rig.Both.A, "x.pdf");
        await rig.Both.B.Vm.OpenAsync(rig.Both.B.Pdf("y.pdf"));
        WindowHub.BeginExit(rig.Both.Registry, session: true);

        // The question is up, then the answer keeps the document; WPF closes the window all the same.
        rig.A.Close();
        rig.Both.A.Vm.CancelClose();

        Assert.True(WindowHub.Exiting);
        rig.Both.A.Vm.Close(edited);
        rig.A.Close();
        rig.B.Close();
        Assert.Equal([edited.Path!, rig.Both.B.Dir.Sub("y.pdf")], rig.Saved.LastFiles);
    });

    [Fact]
    public Task ClosingAllWindowsTogetherWritesTheFilesOfBoth() => Sta.Run(async () =>
    {
        using var rig = new Rig();
        await rig.Both.A.Vm.OpenAsync(rig.Both.A.Pdf("x.pdf"));
        await rig.Both.B.Vm.OpenAsync(rig.Both.B.Pdf("y.pdf"));

        rig.A.Close();
        rig.B.Close();

        Assert.Equal([rig.Both.A.Dir.Sub("x.pdf"), rig.Both.B.Dir.Sub("y.pdf")], rig.Saved.LastFiles);
    });

    [Fact]
    public Task WindowsClosedOneAtATimeKeepOnlyTheLastOnesFiles() => Sta.Run(async () =>
    {
        using var rig = new Rig();
        await rig.Both.A.Vm.OpenAsync(rig.Both.A.Pdf("x.pdf"));
        await rig.Both.B.Vm.OpenAsync(rig.Both.B.Pdf("y.pdf"));

        rig.A.Close();
        WindowHub.EndPass();
        Assert.Empty(rig.Saved.LastFiles);
        rig.B.Close();

        Assert.Equal([rig.Both.B.Dir.Sub("y.pdf")], rig.Saved.LastFiles);
        Assert.Equal([rig.Both.A.Dir.Sub("x.pdf")], rig.Both.B.Vm.ClosedFiles);
    });

    [Fact]
    public Task ASecondaryThatClosesLeavesItsFilesToReopenInTheWindowThatStays() => Sta.Run(async () =>
    {
        using var rig = new Rig();
        await rig.Both.A.Vm.OpenAsync(rig.Both.A.Pdf("x.pdf"));
        await rig.Both.B.Vm.OpenAsync(rig.Both.B.Pdf("y.pdf"));

        rig.B.Close();

        Assert.Empty(rig.Saved.LastFiles);
        Assert.Equal([rig.Both.B.Dir.Sub("y.pdf")], rig.Both.A.Vm.ClosedFiles);
        Assert.Single(WindowHub.Windows);
    });

    [Fact]
    public Task WhenTheAppEndsTheFirstWindowsPlaceIsKept() => Sta.Run(async () =>
    {
        using var rig = new Rig();
        await rig.Both.A.Vm.OpenAsync(rig.Both.A.Pdf("x.pdf"));
        await rig.Both.B.Vm.OpenAsync(rig.Both.B.Pdf("y.pdf"));
        rig.A.Left = 100;
        WindowHub.BeginExit(rig.Both.Registry, session: true);

        rig.A.Close();
        rig.B.Close();

        Assert.Equal(100, rig.Saved.Window!.Left);
    });

    [Fact]
    public Task MovingATabWhileAnActionRunsSaysWhyItStays() => Sta.Run(async () =>
    {
        using var rig = new Rig();
        await rig.Both.A.Vm.OpenAsync(rig.Both.A.Pdf());
        var tab = rig.Both.A.Vm.ActiveDocument!;
        typeof(MainWindow).GetField("_actionRunning", BindingFlags.Instance | BindingFlags.NonPublic)!.SetValue(rig.A, true);

        Assert.False(rig.A.MoveTab(tab, rig.B, 1));

        typeof(MainWindow).GetField("_actionRunning", BindingFlags.Instance | BindingFlags.NonPublic)!.SetValue(rig.A, false);
        Assert.Equal("Tab not moved", rig.Both.A.Vm.Message?.Title);
        Assert.Equal("Wait for the job to end, or cancel it, then move the tab.", rig.Both.A.Vm.Message?.Text);
        Assert.Contains(tab, rig.Both.A.Vm.Documents);
    });
}
