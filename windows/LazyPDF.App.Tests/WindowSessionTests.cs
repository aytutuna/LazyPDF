using LazyPDF.App.Documents;
using Xunit;

namespace LazyPDF.App.Tests;

// What the next start reopens, and what Ctrl+Shift+T brings back, when windows close.
public sealed class WindowSessionTests
{
    [Fact]
    public async Task TheSessionHoldsTheFilesOfEveryWindowFirstWindowFirst()
    {
        using var p = new TwoWindows();
        string a1 = p.A.Pdf("a1.pdf"), a2 = p.A.Pdf("a2.pdf"), b1 = p.B.Pdf("b1.pdf");
        await p.A.Vm.OpenAsync(a1);
        await p.B.Vm.OpenAsync(b1);
        await p.A.Vm.OpenAsync(a2);

        var (files, active) = p.Registry.Session();

        Assert.Equal([a1, a2, b1], files);
        Assert.Equal(a2, active);
    }

    [Fact]
    public async Task TheActiveFileIsTheFirstWindowsThatShowsOne()
    {
        using var p = new TwoWindows();
        string b1 = p.B.Pdf("b1.pdf");
        await p.B.Vm.OpenAsync(b1);

        Assert.Equal(b1, p.Registry.Session().Active);
    }

    [Fact]
    public async Task AWindowThatClosedIsNotInTheSession()
    {
        using var p = new TwoWindows();
        await p.A.Vm.OpenAsync(p.A.Pdf("a.pdf"));
        string b = p.B.Pdf("b.pdf");
        await p.B.Vm.OpenAsync(b);

        p.A.Vm.LeaveRegistry();

        Assert.Equal([b], p.Registry.Session().Files);
    }

    [Fact]
    public async Task FilesOfAClosedWindowComeBackWithReopenInTheOneThatStays()
    {
        using var p = new TwoWindows();
        string x = p.A.Pdf("x.pdf"), y = p.A.Pdf("y.pdf");

        p.B.Vm.RememberClosed(x);
        p.B.Vm.RememberClosed(y);
        await p.B.Vm.ReopenClosedAsync();

        Assert.Equal(y, p.B.Vm.ActiveDocument!.Path);
        Assert.Empty(p.A.Vm.Documents);
    }

    [Fact]
    public async Task AFileClosedTwiceIsRememberedOnce()
    {
        using var f = new ViewModelFixture();
        string path = f.Pdf();
        await f.Vm.OpenAsync(path);
        f.Vm.RequestClose(f.Vm.ActiveDocument!);

        f.Vm.RememberClosed(path);

        Assert.Equal([path], f.Vm.ClosedFiles);
    }

    [Fact]
    public async Task ATabThatTheWindowCannotLetGoOfStaysWhereItWas()
    {
        using var p = new TwoWindows();
        await p.A.Vm.OpenAsync(p.A.Pdf());
        var tab = p.A.Vm.ActiveDocument!;
        p.A.Vm.Released += (_, _) => throw new InvalidOperationException();

        Assert.False(p.Registry.Transfer(tab, p.A.Vm, p.B.Vm, 1));

        Assert.Same(tab, p.A.Vm.ActiveDocument);
        Assert.Empty(p.B.Vm.Documents);
        Assert.Same(p.A.Vm, p.Registry.Find(tab.Id));
    }

    [Fact]
    public async Task TheWindowIsToldBeforeTheTabLeaves()
    {
        using var p = new TwoWindows();
        await p.A.Vm.OpenAsync(p.A.Pdf());
        var tab = p.A.Vm.ActiveDocument!;
        bool stillThere = false;
        p.A.Vm.Released += (_, left) => stillThere = ReferenceEquals(left, tab) && p.A.Vm.Strip.Contains(tab) && ReferenceEquals(p.A.Vm.ActiveDocument, tab);

        Assert.True(p.Registry.Transfer(tab, p.A.Vm, p.B.Vm, 1));

        Assert.True(stillThere);
    }

    [Fact]
    public void AWindowWithNothingRunningHasNoOwnedWork()
    {
        using var f = new ViewModelFixture();

        Assert.False(f.Vm.HasOwnedWork);
    }
}
