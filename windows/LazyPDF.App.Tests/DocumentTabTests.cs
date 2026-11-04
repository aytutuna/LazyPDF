using LazyPDF.App.Documents;
using LazyPDF.App.Services;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// One open document: the session, its renderer, the dirty state, saving, the recovery copy and the file on disk.
public sealed class DocumentTabTests
{
    private static DocumentTab Open(TempDir dir, out FakeRenderer renderer, string? path = null, bool unsaved = false, RecoveryStore? recovery = null, int pages = 1)
    {
        renderer = new FakeRenderer();
        var session = PdfEditSession.Open(Pdfs.Text(pages));
        return new DocumentTab(session, renderer, path, "Untitled.pdf", recovery: recovery, unsaved: unsaved);
    }

    private static string Written(TempDir dir, string name = "a.pdf") => dir.File(name, Pdfs.Text());

    [Fact]
    public void ANewTabIsCleanAndDrawsItsFirstLoad()
    {
        using var dir = new TempDir();
        using var tab = Open(dir, out var renderer);

        Assert.False(tab.IsDirty);
        Assert.True(tab.CanDraw);
        Assert.Equal(1, renderer.Loads);
        Assert.Equal(0, tab.Revision);
        Assert.Equal(1, tab.PageCount);
    }

    [Fact]
    public void ACommitMakesItDirtyAndLoadsTheRendererAgain()
    {
        using var dir = new TempDir();
        using var tab = Open(dir, out var renderer);
        int raised = 0;
        tab.Changed += (_, _) => raised++;
        Pdfs.Retitle(tab.Session, "New title");

        Assert.True(tab.Commit("Properties"));

        Assert.True(tab.IsDirty);
        Assert.Equal(2, renderer.Loads);
        Assert.Equal(1, tab.Revision);
        Assert.Equal(1, raised);
    }

    [Fact]
    public void ACommitWithNothingChangedDoesNothing()
    {
        using var dir = new TempDir();
        using var tab = Open(dir, out var renderer);

        Assert.False(tab.Commit("Nothing"));

        Assert.Equal(1, renderer.Loads);
        Assert.False(tab.IsDirty);
    }

    [Fact]
    public void UndoAndRedoMoveThroughTheSession()
    {
        using var dir = new TempDir();
        using var tab = Open(dir, out var renderer);
        Pdfs.Retitle(tab.Session, "One");
        tab.Commit("One");

        Assert.True(tab.Undo());
        Assert.False(tab.IsDirty);
        Assert.True(tab.Redo());
        Assert.True(tab.IsDirty);
        Assert.Equal(4, renderer.Loads);
        Assert.False(tab.Redo());
        Assert.Equal(3, tab.Revision);
    }

    [Fact]
    public void AnUnsavedTabIsDirtyEvenWithNoHistory()
    {
        using var dir = new TempDir();
        using var tab = Open(dir, out _, unsaved: true);

        Assert.True(tab.IsDirty);
    }

    [Fact]
    public void ATabWithNoFileTakesItsTitleFromTheGivenName()
    {
        using var dir = new TempDir();
        using var tab = Open(dir, out _);

        Assert.Null(tab.Path);
        Assert.Equal("Untitled.pdf", tab.Title);
    }

    [Fact]
    public void SaveWritesToTheFileItCameFromAndIsCleanAfterwards()
    {
        using var dir = new TempDir();
        string path = Written(dir);
        using var tab = Open(dir, out _, path);
        Pdfs.Retitle(tab.Session, "Saved title");
        tab.Commit("Properties");

        tab.Save();

        Assert.False(tab.IsDirty);
        Assert.Equal("Saved title", DocumentMetadata.Read(PdfDocument.Open(path)).Title);
        Assert.Equal("a.pdf", tab.Title);
    }

    [Fact]
    public void SaveWithNoFileIsAMistake()
    {
        using var dir = new TempDir();
        using var tab = Open(dir, out _);

        Assert.Throws<InvalidOperationException>(tab.Save);
    }

    [Fact]
    public void SaveAsGivesTheTabItsFileAndName()
    {
        using var dir = new TempDir();
        using var tab = Open(dir, out _, unsaved: true);
        string path = dir.Sub("made.pdf");
        Directory.CreateDirectory(dir.Path);

        tab.SaveAs(path);

        Assert.Equal(path, tab.Path);
        Assert.Equal("made.pdf", tab.Title);
        Assert.False(tab.IsDirty);
        Assert.Single(PdfDocument.Open(path).Pages);
    }

    [Fact]
    public void SaveCompactDropsTheHistory()
    {
        using var dir = new TempDir();
        string path = Written(dir);
        using var tab = Open(dir, out _, path);
        Pdfs.Retitle(tab.Session, "Compact");
        tab.Commit("Properties");
        Assert.True(tab.Session.CanUndo);

        tab.SaveCompact(path);

        Assert.False(tab.Session.CanUndo);
        Assert.False(tab.IsDirty);
        Assert.Equal("Compact", DocumentMetadata.Read(PdfDocument.Open(path)).Title);
    }

    [Fact]
    public void SaveGoesThroughTheSafeWriterAndLeavesNoTemporaryFile()
    {
        using var dir = new TempDir();
        string path = Written(dir);
        using var tab = Open(dir, out _, path);
        Pdfs.Retitle(tab.Session, "x");
        tab.Commit("x");

        tab.Save();

        Assert.Equal([path], Directory.GetFiles(dir.Path));
    }

    [Fact]
    public void ACommitIsWrittenToTheRecoveryFolder()
    {
        using var dir = new TempDir();
        var recovery = new RecoveryStore(dir.Sub("recovery"));
        using var tab = Open(dir, out _, recovery: recovery);
        Pdfs.Retitle(tab.Session, "Recover me");
        tab.Commit("Properties");

        recovery.Flush();

        var entry = Assert.Single(recovery.List());
        Assert.Equal(tab.Id, entry.Id);
        Assert.Equal(tab.Session.Current.ToArray(), File.ReadAllBytes(entry.PdfPath));
    }

    [Fact]
    public void AnUnsavedTabIsInTheRecoveryFolderFromTheStart()
    {
        using var dir = new TempDir();
        var recovery = new RecoveryStore(dir.Sub("recovery"));
        using var tab = Open(dir, out _, unsaved: true, recovery: recovery);

        recovery.Flush();

        Assert.Single(recovery.List());
    }

    [Fact]
    public void SavingRemovesTheRecoveryCopy()
    {
        using var dir = new TempDir();
        string path = Written(dir);
        var recovery = new RecoveryStore(dir.Sub("recovery"));
        using var tab = Open(dir, out _, path, recovery: recovery);
        Pdfs.Retitle(tab.Session, "x");
        tab.Commit("x");

        tab.Save();
        recovery.Flush();

        Assert.Empty(recovery.List());
    }

    [Fact]
    public void ClosingOnPurposeRemovesTheRecoveryCopyAndLetsGoOfTheRenderer()
    {
        using var dir = new TempDir();
        var recovery = new RecoveryStore(dir.Sub("recovery"));
        var tab = Open(dir, out var renderer, recovery: recovery);
        Pdfs.Retitle(tab.Session, "x");
        tab.Commit("x");

        tab.Dispose();

        Assert.True(renderer.Disposed);
        Assert.Empty(recovery.List());
    }

    [Fact]
    public void AFileChangedByAnotherProgramIsNoticed()
    {
        using var dir = new TempDir();
        string path = Written(dir);
        using var tab = Open(dir, out _, path);
        Assert.False(tab.ChangedOnDisk);

        File.WriteAllBytes(path, Pdfs.Text(pages: 2));
        File.SetLastWriteTimeUtc(path, DateTime.UtcNow.AddMinutes(5));

        Assert.True(tab.ChangedOnDisk);
        tab.AcceptDiskState();
        Assert.False(tab.ChangedOnDisk);
    }

    [Fact]
    public void AFileThatWasDeletedCountsAsChanged()
    {
        using var dir = new TempDir();
        string path = Written(dir);
        using var tab = Open(dir, out _, path);

        File.Delete(path);

        Assert.True(tab.ChangedOnDisk);
    }

    [Fact]
    public void OurOwnSaveIsNotAChangeByAnotherProgram()
    {
        using var dir = new TempDir();
        string path = Written(dir);
        using var tab = Open(dir, out _, path);
        Pdfs.Retitle(tab.Session, "x");
        tab.Commit("x");

        tab.Save();

        Assert.False(tab.ChangedOnDisk);
    }

    [Fact]
    public void ATabWithNoFileNeverChangesOnDisk()
    {
        using var dir = new TempDir();
        using var tab = Open(dir, out _);

        Assert.False(tab.ChangedOnDisk);
    }

    [Fact]
    public void ADocumentTheSystemCannotDrawStillOpens()
    {
        var renderer = new FakeRenderer { Draws = false };

        using var tab = new DocumentTab(PdfEditSession.Open(Pdfs.Text()), renderer, null, "x.pdf");

        Assert.False(tab.CanDraw);
        Assert.Equal(1, tab.PageCount);
    }

    [Fact]
    public void ThePageAndZoomAreKeptForTheViewer()
    {
        using var dir = new TempDir();
        using var tab = Open(dir, out _, pages: 3);

        tab.PageIndex = 2;
        tab.Zoom = 1.5;

        Assert.Equal((2, 1.5), (tab.PageIndex, tab.Zoom));
    }

    [Fact]
    public void ThePropertiesAreAnnouncedWhenTheStateChanges()
    {
        using var dir = new TempDir();
        using var tab = Open(dir, out _);
        var names = new List<string?>();
        tab.PropertyChanged += (_, e) => names.Add(e.PropertyName);
        Pdfs.Retitle(tab.Session, "x");

        tab.Commit("x");

        Assert.Equal([""], names);
    }
}
