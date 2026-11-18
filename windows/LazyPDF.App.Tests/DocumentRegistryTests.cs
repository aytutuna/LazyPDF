using System.Runtime.InteropServices;
using LazyPDF.App.Documents;
using LazyPDF.App.Services;
using Xunit;

namespace LazyPDF.App.Tests;

// A file is held by one tab in the whole process, whichever window asks for it.
public sealed class DocumentRegistryTests
{
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CreateHardLinkW(string link, string existing, nint reserved);

    // The same file by a path that goes through a folder and back.
    private static string Spelled(string path)
    {
        string dir = Path.GetDirectoryName(path)!;
        Directory.CreateDirectory(Path.Combine(dir, "sub"));
        return Path.Combine(dir, "sub", "..", Path.GetFileName(path));
    }

    [Fact]
    public async Task AFileOpenInOneWindowIsBroughtForwardNotOpenedInAnother()
    {
        using var p = new TwoWindows();
        string path = p.A.Pdf();
        await p.A.Vm.OpenAsync(path);
        var tab = p.A.Vm.ActiveDocument;
        p.A.Vm.ActiveTab = HomeTab.Instance;

        await p.B.Vm.OpenAsync(path);

        Assert.Empty(p.B.Vm.Documents);
        Assert.Same(tab, p.A.Vm.ActiveDocument);
        Assert.Same(tab, Assert.Single(p.ForwardedA));
        Assert.Empty(p.ForwardedB);
    }

    [Fact]
    public async Task AnotherSpellingOfTheFileIsFoundInTheOtherWindow()
    {
        using var p = new TwoWindows();
        string path = p.A.Pdf();
        await p.A.Vm.OpenAsync(path);

        await p.B.Vm.OpenAsync(Spelled(path));

        Assert.Empty(p.B.Vm.Documents);
        Assert.Single(p.ForwardedA);
    }

    [Fact]
    public async Task AHardLinkToAnOpenFileIsFoundInTheOtherWindow()
    {
        using var p = new TwoWindows();
        string path = p.A.Pdf();
        string link = Path.Combine(Path.GetDirectoryName(path)!, "link.pdf");
        Assert.True(CreateHardLinkW(link, path, 0));
        await p.A.Vm.OpenAsync(path);

        await p.B.Vm.OpenAsync(link);

        Assert.Empty(p.B.Vm.Documents);
        Assert.Single(p.ForwardedA);
    }

    [Fact]
    public async Task AMovedFileIsFollowedByTheTabInTheOtherWindow()
    {
        using var p = new TwoWindows();
        string path = p.A.Pdf();
        string moved = Path.Combine(Path.GetDirectoryName(path)!, "moved.pdf");
        await p.A.Vm.OpenAsync(path);
        var tab = p.A.Vm.ActiveDocument!;
        File.Move(path, moved);

        await p.B.Vm.OpenAsync(moved);

        Assert.Empty(p.B.Vm.Documents);
        Assert.Equal(moved, tab.Path);
        Assert.Equal("File moved", p.A.Vm.Message?.Title);
        Assert.Null(p.B.Vm.Message);
    }

    [Fact]
    public async Task TwoWindowsOpeningTheSameFileAtOnceEndWithOneTab()
    {
        using var p = new TwoWindows();
        string path = p.A.Pdf();

        await Task.WhenAll(p.A.Vm.OpenAsync(path), p.B.Vm.OpenAsync(path));

        Assert.Equal(1, p.A.Vm.Documents.Count() + p.B.Vm.Documents.Count());
        Assert.Equal(1, p.ForwardedA.Count + p.ForwardedB.Count);
    }

    [Fact]
    public async Task TwoSpellingsOpeningAtOnceInTwoWindowsEndWithOneTab()
    {
        using var p = new TwoWindows();
        string path = p.A.Pdf();

        await Task.WhenAll(p.A.Vm.OpenAsync(path), p.B.Vm.OpenAsync(Spelled(path)));

        Assert.Equal(1, p.A.Vm.Documents.Count() + p.B.Vm.Documents.Count());
    }

    [Fact]
    public async Task AFileWaitingForItsPasswordInOneWindowAsksNothingInAnother()
    {
        using var p = new TwoWindows();
        string path = p.A.Dir.File("locked.pdf", File.ReadAllBytes(Pdfs.Fixture("locked.pdf")));
        await p.A.Vm.OpenAsync(path);

        await p.B.Vm.OpenAsync(path);

        Assert.NotNull(p.A.Vm.PasswordRequest);
        Assert.Null(p.B.Vm.PasswordRequest);
        Assert.Equal(new DocumentTab?[] { null }, p.ForwardedA);
    }

    [Fact]
    public async Task AFileThatFailedToOpenCanBeOpenedByTheOtherWindow()
    {
        using var p = new TwoWindows();
        string path = p.A.Dir.File("bad.pdf", [1, 2, 3]);
        await p.A.Vm.OpenAsync(path);
        File.WriteAllBytes(path, Pdfs.Text(1));

        await p.B.Vm.OpenAsync(path);

        Assert.Single(p.B.Vm.Documents);
    }

    [Fact]
    public async Task ATabIsFoundByItsIdInTheWindowThatHoldsIt()
    {
        using var p = new TwoWindows();
        await p.B.Vm.OpenAsync(p.B.Pdf());

        Assert.Same(p.B.Vm, p.Registry.Find(p.B.Vm.ActiveDocument!.Id));
        Assert.Null(p.Registry.Find(Guid.NewGuid()));
    }

    [Fact]
    public async Task SavingAsOntoAFileOpenInAnotherWindowIsRefused()
    {
        using var p = new TwoWindows();
        string path = p.A.Pdf();
        await p.A.Vm.OpenAsync(path);
        await p.B.Vm.OpenAsync(p.B.Pdf("b.pdf"));
        var mine = p.B.Vm.ActiveDocument!;

        Assert.False(p.B.Vm.SaveAs(mine, path));
        Assert.False(p.B.Vm.SaveCopy(mine, path));

        Assert.Equal("File is open", p.B.Vm.Message!.Title);
        Assert.Single(p.A.Vm.Documents);
    }

    [Fact]
    public async Task RestoringAFileOpenInAnotherWindowBringsItBackAsACopyThatNeedsAName()
    {
        using var p = new TwoWindows();
        string path = p.A.Pdf("report.pdf");
        await p.A.Vm.OpenAsync(path);
        p.Recovery.Write(Guid.NewGuid(), Pdfs.Text(2), new RecoveryMeta { Title = "report.pdf", OriginalPath = path, Saved = DateTimeOffset.Now });
        p.Recovery.Flush();
        p.B.Vm.CheckRecovery();

        await p.B.Vm.RestoreAsync();

        Assert.Equal(path, Assert.Single(p.A.Vm.Documents).Path);
        Assert.True(AppViewModel.NeedsName(p.B.Vm.ActiveDocument!));
    }
}
