using Xunit;

namespace LazyPDF.App.Tests;

// A locked file: the question, retries, giving up, and what a file that only the owner restricts does.
public sealed class PasswordFlowTests
{
    private static string Locked(ViewModelFixture f) =>
        f.Dir.File("locked.pdf", File.ReadAllBytes(Pdfs.Fixture("locked.pdf")));

    [Fact]
    public async Task AFileWithAPasswordAsksForIt()
    {
        using var f = new ViewModelFixture();

        await f.Vm.OpenAsync(Locked(f));

        Assert.Empty(f.Vm.Documents);
        var request = f.Vm.PasswordRequest!;
        Assert.Equal("locked.pdf", request.Name);
        Assert.False(request.NeedsCertificate);
        Assert.Equal(0, request.Attempts);
        Assert.Null(request.Problem);
    }

    [Fact]
    public async Task TheRightPasswordOpensItAndEndsTheQuestion()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenAsync(Locked(f));

        await f.Vm.SubmitPasswordAsync("secret");

        Assert.Null(f.Vm.PasswordRequest);
        var tab = Assert.Single(f.Vm.Documents);
        Assert.Equal("locked.pdf", tab.Title);
        Assert.False(tab.IsDirty);
    }

    [Fact]
    public async Task AWrongPasswordSaysSoAndAsksAgain()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenAsync(Locked(f));

        await f.Vm.SubmitPasswordAsync("wrong");
        var first = f.Vm.PasswordRequest!;
        await f.Vm.SubmitPasswordAsync("still wrong");
        var second = f.Vm.PasswordRequest!;

        Assert.Equal("That password is not right.", first.Problem);
        Assert.Equal(1, first.Attempts);
        Assert.Equal(2, second.Attempts);
        Assert.Empty(f.Vm.Documents);
    }

    [Fact]
    public async Task ARetryAfterAMistakeStillWorks()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenAsync(Locked(f));
        await f.Vm.SubmitPasswordAsync("wrong");

        await f.Vm.SubmitPasswordAsync("secret");

        Assert.Null(f.Vm.PasswordRequest);
        Assert.Single(f.Vm.Documents);
    }

    [Fact]
    public async Task GivingUpDropsTheFileAndOpensNothing()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenAsync(Locked(f));

        f.Vm.CancelPending();

        Assert.Null(f.Vm.PasswordRequest);
        Assert.Empty(f.Vm.Documents);
    }

    [Fact]
    public async Task TheOwnerPasswordOpensItToo()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenAsync(f.Dir.File("aes.pdf", File.ReadAllBytes(Pdfs.Fixture("crypt-aes128.pdf"))));

        await f.Vm.SubmitPasswordAsync("owner");

        Assert.Single(f.Vm.Documents);
    }

    [Fact]
    public async Task SeveralLockedFilesAreAskedAboutOneAfterTheOther()
    {
        using var f = new ViewModelFixture();
        string first = f.Dir.File("one.pdf", File.ReadAllBytes(Pdfs.Fixture("locked.pdf")));
        string second = f.Dir.File("two.pdf", File.ReadAllBytes(Pdfs.Fixture("crypt-aes128.pdf")));

        await f.Vm.OpenFilesAsync([first, second]);
        Assert.Equal("one.pdf", f.Vm.PasswordRequest?.Name);
        await f.Vm.SubmitPasswordAsync("secret");

        Assert.Equal("two.pdf", f.Vm.PasswordRequest?.Name);
        await f.Vm.SubmitPasswordAsync("secret");
        Assert.Null(f.Vm.PasswordRequest);
        Assert.Equal(["one.pdf", "two.pdf"], f.Vm.Documents.Select(d => d.Title));
    }

    [Fact]
    public async Task AFileOnlyTheOwnerRestrictsOpensWithNoQuestion()
    {
        using var f = new ViewModelFixture();
        string path = f.Dir.File("owner.pdf", File.ReadAllBytes(Pdfs.Fixture("owner-only-aes.pdf")));

        await f.Vm.OpenAsync(path);

        Assert.Null(f.Vm.PasswordRequest);
        Assert.Single(f.Vm.Documents);
    }

    [Fact]
    public async Task AnAes256FileOpensWithItsPassword()
    {
        using var f = new ViewModelFixture();
        string path = f.Dir.File("aes256.pdf", File.ReadAllBytes(Pdfs.Fixture("crypt-aes256.pdf")));

        await f.Vm.OpenAsync(path);
        await f.Vm.SubmitPasswordAsync("secret");

        Assert.Single(f.Vm.Documents);
    }
}
