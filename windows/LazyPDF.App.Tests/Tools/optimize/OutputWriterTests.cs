using LazyPDF.App.Tools.Optimize;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// Where a rewritten file goes: a new tab, or over the file on disk.
public sealed class OutputWriterTests
{
    [Fact]
    public async Task ANewFileOpensAsAnUnsavedTabThatNeedsAName()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenAsync(f.Pdf("report.pdf", 2));
        var tab = f.Vm.ActiveDocument!;

        bool done = await OutputWriter.DeliverAsync(f.Vm, tab, tab.Revision, Pdfs.Text(2), replace: false, "report (smaller).pdf");

        Assert.True(done);
        Assert.Equal(2, f.Vm.Documents.Count());
        Assert.Equal("report (smaller).pdf", f.Vm.ActiveDocument!.Title);
        Assert.True(AppViewModel.NeedsName(f.Vm.ActiveDocument));
    }

    [Fact]
    public async Task TheSameFileIsWrittenAndTheTabReadAgain()
    {
        using var f = new ViewModelFixture();
        string path = f.Pdf("report.pdf", 4);
        await f.Vm.OpenAsync(path);
        var tab = f.Vm.ActiveDocument!;
        byte[] replacement = Pdfs.Text(4);

        bool done = await OutputWriter.DeliverAsync(f.Vm, tab, tab.Revision, replacement, replace: true, "unused.pdf");

        Assert.True(done);
        Assert.Equal(replacement, File.ReadAllBytes(path));
        var reloaded = Assert.Single(f.Vm.Documents);
        Assert.NotSame(tab, reloaded);
        Assert.Equal(4, reloaded.PageCount);
        Assert.False(reloaded.IsDirty);
    }

    [Fact]
    public async Task ADocumentWithoutAFileGoesToANewTabEvenWhenAskedToReplace()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenNewAsync(Pdfs.Text(), "Made.pdf");
        var tab = f.Vm.ActiveDocument!;

        await OutputWriter.DeliverAsync(f.Vm, tab, tab.Revision, Pdfs.Text(2), replace: true, "Made (clean).pdf");

        Assert.Equal(2, f.Vm.Documents.Count());
        Assert.Equal("Made (clean).pdf", f.Vm.ActiveDocument!.Title);
    }

    [Fact]
    public async Task AFileThatCannotBeWrittenIsReportedAndLeftAlone()
    {
        using var f = new ViewModelFixture();
        string path = f.Pdf("report.pdf");
        await f.Vm.OpenAsync(path);
        var tab = f.Vm.ActiveDocument!;
        byte[] before = File.ReadAllBytes(path);

        bool done = await OutputWriter.DeliverAsync(f.Vm, tab, tab.Revision, [1, 2, 3], replace: true, "unused.pdf");

        Assert.False(done);
        Assert.True(f.Vm.Message!.IsError);
        Assert.Equal(before, File.ReadAllBytes(path));
        Assert.Same(tab, f.Vm.ActiveDocument);
    }

    [Fact]
    public async Task AnEncryptedResultOpensWithoutAskingForThePasswordAgain()
    {
        using var f = new ViewModelFixture();
        string path = f.Dir.File("locked.pdf", File.ReadAllBytes(Pdfs.Fixture("locked.pdf")));
        await f.Vm.OpenAsync(path);
        await f.Vm.SubmitPasswordAsync("secret");
        var tab = f.Vm.ActiveDocument!;

        bool done = await OutputWriter.DeliverAsync(f.Vm, tab, tab.Revision, File.ReadAllBytes(path), replace: false, "locked (clean).pdf");

        Assert.True(done);
        Assert.Null(f.Vm.PasswordRequest);
        Assert.Equal("locked (clean).pdf", f.Vm.ActiveDocument!.Title);
    }

    [Fact]
    public async Task AFileChangedByAnotherProgramIsNotReplaced()
    {
        using var f = new ViewModelFixture();
        string path = f.Pdf("report.pdf", 1);
        await f.Vm.OpenAsync(path);
        var tab = f.Vm.ActiveDocument!;
        File.WriteAllBytes(path, Pdfs.Text(3));
        File.SetLastWriteTimeUtc(path, DateTime.UtcNow.AddMinutes(5));
        byte[] theirs = File.ReadAllBytes(path);

        Assert.True(OutputWriter.Refuses(f.Vm, tab, replace: true));
        bool done = await OutputWriter.DeliverAsync(f.Vm, tab, tab.Revision, Pdfs.Text(4), replace: true, "unused.pdf");

        Assert.False(done);
        Assert.True(f.Vm.Message!.IsError);
        Assert.Equal(theirs, File.ReadAllBytes(path));
        Assert.False(OutputWriter.Refuses(f.Vm, tab, replace: false));
    }

    [Fact]
    public async Task ABytesMadeBeforeAnEditAreNotDelivered()
    {
        using var f = new ViewModelFixture();
        string path = f.Pdf("report.pdf", 1);
        await f.Vm.OpenAsync(path);
        var tab = f.Vm.ActiveDocument!;
        int before = tab.Revision;
        Pdfs.Retitle(tab.Session, "Edited");
        tab.Commit("Properties");
        byte[] onDisk = File.ReadAllBytes(path);

        bool done = await OutputWriter.DeliverAsync(f.Vm, tab, before, Pdfs.Text(2), replace: true, "unused.pdf");

        Assert.False(done);
        Assert.Equal(onDisk, File.ReadAllBytes(path));
        Assert.Same(tab, f.Vm.ActiveDocument);
        Assert.Single(f.Vm.Documents);
    }

    [Fact]
    public async Task AResultWithOtherPagesIsRefusedOverTheFile()
    {
        using var f = new ViewModelFixture();
        string path = f.Pdf("report.pdf", 3);
        await f.Vm.OpenAsync(path);
        var tab = f.Vm.ActiveDocument!;
        byte[] before = File.ReadAllBytes(path);

        bool done = await OutputWriter.DeliverAsync(f.Vm, tab, tab.Revision, Pdfs.Text(2), replace: true, "unused.pdf");

        Assert.False(done);
        Assert.Equal(before, File.ReadAllBytes(path));
    }

    [Fact]
    public async Task TheViewStaysWhereItWasAfterTheFileIsWritten()
    {
        using var f = new ViewModelFixture();
        string path = f.Pdf("report.pdf", 4);
        await f.Vm.OpenAsync(path);
        var tab = f.Vm.ActiveDocument!;
        tab.PageIndex = 2;
        tab.Zoom = 1.5;

        await OutputWriter.DeliverAsync(f.Vm, tab, tab.Revision, Pdfs.Text(4), replace: true, "unused.pdf");

        var reloaded = f.Vm.ActiveDocument!;
        Assert.Equal(2, reloaded.PageIndex);
        Assert.Equal(1.5, reloaded.Zoom);
    }
}
