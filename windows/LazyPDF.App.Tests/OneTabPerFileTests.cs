using LazyPDF.App.Services;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// A file is open in one tab only, however it is asked for: twice at once, by Restore, or by Save as.
public sealed class OneTabPerFileTests
{
    [Fact]
    public async Task OpeningTheSameFileTwiceAtOnceMakesOneTab()
    {
        using var f = new ViewModelFixture();
        string path = f.Pdf();

        await Task.WhenAll(f.Vm.OpenAsync(path), f.Vm.OpenAsync(path));

        Assert.Single(f.Vm.Documents);
    }

    [Fact]
    public async Task AskingForALockedFileWhileItsQuestionIsUpAddsNoSecondQuestion()
    {
        using var f = new ViewModelFixture();
        string path = f.Dir.File("locked.pdf", File.ReadAllBytes(Pdfs.Fixture("locked.pdf")));
        await f.Vm.OpenAsync(path);

        await f.Vm.OpenAsync(path);
        f.Vm.CancelPending();

        Assert.Null(f.Vm.PasswordRequest);
    }

    [Fact]
    public async Task SendingThePasswordTwiceAtOnceMakesOneTab()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenAsync(f.Dir.File("locked.pdf", File.ReadAllBytes(Pdfs.Fixture("locked.pdf"))));

        await Task.WhenAll(f.Vm.SubmitPasswordAsync("secret"), f.Vm.SubmitPasswordAsync("secret"));

        Assert.Single(f.Vm.Documents);
    }

    [Fact]
    public async Task GivingUpWhileThePasswordIsBeingCheckedOpensNothing()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenAsync(f.Dir.File("locked.pdf", File.ReadAllBytes(Pdfs.Fixture("locked.pdf"))));

        var submit = f.Vm.SubmitPasswordAsync("secret");
        f.Vm.CancelPending();
        await submit;

        Assert.Empty(f.Vm.Documents);
    }

    [Fact]
    public async Task RestoringAFileThatIsOpenBringsItBackAsACopyThatNeedsAName()
    {
        using var f = new ViewModelFixture();
        string path = f.Pdf("report.pdf");
        await f.Vm.OpenAsync(path);
        var store = new RecoveryStore(f.Dir.Sub("recovery"));
        store.Write(Guid.NewGuid(), Pdfs.Text(2), new RecoveryMeta { Title = "report.pdf", OriginalPath = path, Saved = DateTimeOffset.Now });
        store.Flush();
        f.Vm.CheckRecovery();

        await f.Vm.RestoreAsync();

        Assert.Equal(2, f.Vm.Documents.Count());
        Assert.Single(f.Vm.Documents, d => d.Path == path);
        Assert.True(AppViewModel.NeedsName(f.Vm.ActiveDocument!));
    }

    [Fact]
    public async Task SavingAsOntoAFileOpenInAnotherTabIsRefused()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenFilesAsync([f.Pdf("a.pdf"), f.Pdf("b.pdf")]);
        var a = f.Vm.Documents.First();
        string other = f.Vm.Documents.Last().Path!;

        Assert.False(f.Vm.SaveAs(a, other));

        Assert.Equal("File is open", f.Vm.Message!.Title);
    }

    [Fact]
    public async Task SavingAsOntoItsOwnFileIsAllowed()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenAsync(f.Pdf());
        var tab = f.Vm.ActiveDocument!;

        Assert.True(f.Vm.SaveAs(tab, tab.Path!));
    }

    [Fact]
    public async Task AFileThatIsNotThereAnyMoreLeavesTheRecentList()
    {
        using var f = new ViewModelFixture();
        string path = f.Pdf();
        await f.Vm.OpenAsync(path);
        f.Vm.Close(f.Vm.ActiveDocument!);
        File.Delete(path);

        await f.Vm.OpenAsync(path);

        Assert.DoesNotContain(f.Vm.Recent, r => r.Path == path);
    }

    [Fact]
    public async Task AFileAnotherProgramHoldsStaysInTheRecentList()
    {
        using var f = new ViewModelFixture();
        string path = f.Pdf();
        await f.Vm.OpenAsync(path);
        f.Vm.Close(f.Vm.ActiveDocument!);
        using var held = new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.None);

        await f.Vm.OpenAsync(path);

        Assert.Contains(f.Vm.Recent, r => r.Path == path);
        Assert.True(f.Vm.Message!.IsError);
    }
}
