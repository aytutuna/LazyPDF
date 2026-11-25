using LazyPDF.App.Tools;
using LazyPDF.App.Tools.Compare;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// Running the tool as the shell does: the busy bar, the problem for a file that cannot be read, the report as a new tab.
public sealed class CompareFlowTests
{
    private static CompareFlow Flow(ViewModelFixture f) => new(f.Vm, () => new FakeRenderer(), new FakeFonts());

    private static CompareRequest Request(string? path, PdfVersion? version = null, bool fileIsOlder = false, bool pixels = false) =>
        new(path, version, fileIsOlder, new CompareOptions(), pixels);

    [Fact]
    public async Task AnotherFileIsTheOldSideUnlessTheOpenFileIsOlder()
    {
        using var f = new ViewModelFixture();
        string other = f.Dir.File("other.pdf", CompareKit.After());
        await f.Vm.OpenAsync(f.Dir.File("open.pdf", CompareKit.Before()));
        var tab = f.Vm.ActiveDocument!;

        using var older = (await Flow(f).RunAsync(tab, Request(other)))!;
        using var newer = (await Flow(f).RunAsync(tab, Request(other, fileIsOlder: true)))!;

        Assert.Equal(("other.pdf", "open.pdf"), (older.Old.Title, older.New.Title));
        Assert.Equal(("open.pdf", "other.pdf"), (newer.Old.Title, newer.New.Title));
        Assert.Contains(older.Result!.Changes, c => c.Kind == ChangeKind.Removed && c.Area == ChangeArea.Document);
        Assert.Contains(newer.Result!.Changes, c => c.Kind == ChangeKind.Added && c.Area == ChangeArea.Document);
        Assert.Equal($"{newer.Rows(Parts.All).Count} differences", f.Vm.StatusFull);
        Assert.False(f.Vm.IsBusy);
    }

    private static byte[] TwoRevisions()
    {
        var session = PdfEditSession.Open(Pdfs.Text(2));
        Pdfs.Retitle(session, "Changed title");
        session.Commit("Properties");
        return session.Current.ToArray();
    }

    [Fact]
    public async Task AnEarlierVersionIsComparedWithTheOpenFile()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenAsync(f.Dir.File("open.pdf", TwoRevisions()));
        var tab = f.Vm.ActiveDocument!;
        var earlier = Assert.Single(CompareFlow.Earlier(tab.Session));

        using var made = (await Flow(f).RunAsync(tab, Request(null, earlier)))!;

        Assert.Equal("open.pdf, version 1", made.Old.Title);
        var change = Assert.Single(made.Result!.Changes);
        Assert.Equal(("", "Changed title"), (change.OldText, change.NewText));
    }

    [Fact]
    public async Task AFileWithNoHistoryHasNoEarlierVersion()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenAsync(f.Pdf("open.pdf"));

        Assert.Empty(CompareFlow.Earlier(f.Vm.ActiveDocument!.Session));
    }

    [Fact]
    public async Task EditsNotYetSavedMakeTheOpenedStateAnEarlierVersion()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenAsync(f.Pdf("open.pdf"));
        var tab = f.Vm.ActiveDocument!;
        Pdfs.Retitle(tab.Session, "Edited");
        tab.Commit("Properties");

        Assert.Single(CompareFlow.Earlier(tab.Session));
    }

    [Fact]
    public async Task TheOpenFileIsReadAsItWasWhenTheToolRan()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenAsync(f.Pdf("open.pdf", 2));
        var tab = f.Vm.ActiveDocument!;
        string other = f.Dir.File("other.pdf", CompareKit.After());

        using var made = (await Flow(f).RunAsync(tab, Request(other, fileIsOlder: true)))!;
        Pdfs.Retitle(tab.Session, "Later");
        tab.Commit("Properties");

        Assert.DoesNotContain(made.Result!.Changes, c => c.NewText == "Later" || c.OldText == "Later");
        Assert.NotEqual("Later", DocumentMetadata.Read(made.Old.Document).Title);
    }

    [Fact]
    public async Task AFileThatIsGoneIsAProblemNotACrash()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenAsync(f.Pdf("open.pdf"));

        var made = await Flow(f).RunAsync(f.Vm.ActiveDocument!, Request(f.Dir.Sub("gone.pdf")));

        Assert.Null(made);
        Assert.Equal("File not found", f.Vm.Message!.Title);
        Assert.False(f.Vm.IsBusy);
    }

    [Fact]
    public async Task AFileThatIsNotAPdfIsAProblem()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenAsync(f.Pdf("open.pdf"));
        string junk = f.Dir.File("junk.pdf", "not a pdf at all"u8.ToArray());

        var made = await Flow(f).RunAsync(f.Vm.ActiveDocument!, Request(junk));

        Assert.Null(made);
        Assert.Equal("Not a PDF", f.Vm.Message!.Title);
    }

    [Fact]
    public async Task CancellingGivesNothingBack()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenAsync(f.Pdf("open.pdf"));
        string other = f.Dir.File("other.pdf", CompareKit.After());

        var made = await new CompareFlow(new CancellingHost(), () => new FakeRenderer(), new FakeFonts()).RunAsync(f.Vm.ActiveDocument!, Request(other));

        Assert.Null(made);
    }

    [Fact]
    public async Task TheReportOpensAsANewDocumentThatNeedsAName()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenAsync(f.Dir.File("open.pdf", CompareKit.Before()));
        using var made = (await Flow(f).RunAsync(f.Vm.ActiveDocument!, Request(f.Dir.File("other.pdf", CompareKit.After()), fileIsOlder: true)))!;

        await Flow(f).WriteReportAsync(made, Parts.All);

        var tab = f.Vm.ActiveDocument!;
        Assert.Equal("Comparison - other.pdf", tab.Title);
        Assert.True(tab.PageCount > made.New.PageCount);
        Assert.True(AppViewModel.NeedsName(tab));
    }

    [Fact]
    public async Task ALockedOtherFileAsksForItsPasswordInsteadOfFailing()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenAsync(f.Dir.File("open.pdf", CompareKit.Before()));
        var tab = f.Vm.ActiveDocument!;
        string locked = f.Dir.File("locked.pdf", CompareKit.Locked("pw"));
        var flow = Flow(f);

        Assert.Null(await flow.RunAsync(tab, Request(locked)));
        Assert.Equal(PdfReadProblem.PasswordRequired, flow.Locked);
        Assert.Null(f.Vm.Message);

        using var made = (await flow.RunAsync(tab, Request(locked) with { Password = "pw" }))!;
        Assert.Null(flow.Locked);
        Assert.Equal("locked.pdf", made.Old.Title);
    }

    [Fact]
    public async Task AWrongPasswordIsAskedAgain()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenAsync(f.Dir.File("open.pdf", CompareKit.Before()));
        var flow = Flow(f);

        Assert.Null(await flow.RunAsync(f.Vm.ActiveDocument!, Request(f.Dir.File("locked.pdf", CompareKit.Locked("pw"))) with { Password = "nope" }));
        Assert.Equal(PdfReadProblem.PasswordRequired, flow.Locked);
    }

    [Fact]
    public async Task AnotherOpenTabIsComparedAsItIsNowWithItsUnsavedEdits()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenAsync(f.Dir.File("open.pdf", CompareKit.Before()));
        var open = f.Vm.ActiveDocument!;
        await f.Vm.OpenAsync(f.Dir.File("other.pdf", CompareKit.Before()));
        var other = f.Vm.ActiveDocument!;
        using var same = (await Flow(f).RunAsync(open, Request(null) with { OtherTab = other }))!;
        Pdfs.Retitle(other.Session, "Edited");
        other.Commit("Properties");

        using var made = (await Flow(f).RunAsync(open, Request(null) with { OtherTab = other }))!;

        Assert.True(same.Result!.IsIdentical);
        Assert.Equal("other.pdf", made.Old.Title);
        Assert.Contains(made.Result!.Changes, c => c.NewText == "" && c.OldText == "Edited");
    }

    [Fact]
    public async Task ATabClosedBeforeRunningIsAProblem()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenAsync(f.Pdf("open.pdf"));
        var open = f.Vm.ActiveDocument!;
        await f.Vm.OpenAsync(f.Pdf("other.pdf"));
        var other = f.Vm.ActiveDocument!;
        f.Vm.Close(other);

        var made = await Flow(f).RunAsync(open, Request(null) with { OtherTab = other });

        Assert.Null(made);
        Assert.Equal("File closed", f.Vm.Message!.Title);
    }
}
