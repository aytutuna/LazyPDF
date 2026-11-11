using LazyPDF.App.Documents;
using LazyPDF.App.Services;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// After a crash: what was open is offered back, with its unsaved changes.
public sealed class RecoveryFlowTests
{
    // A document with a change in it, as the app left it in the recovery folder when it died.
    private static void Crash(ViewModelFixture f, string name, string? originalPath)
    {
        var session = PdfEditSession.Open(Pdfs.Text());
        Pdfs.Retitle(session, "Unsaved title");
        session.Commit("Properties");
        var store = new RecoveryStore(f.Dir.Sub("recovery"));
        store.Write(Guid.NewGuid(), session.Current, new RecoveryMeta { Title = name, OriginalPath = originalPath, Saved = DateTimeOffset.Now });
        store.Flush();
    }

    [Fact]
    public void WithNothingLeftThereIsNothingToOffer()
    {
        using var f = new ViewModelFixture();

        f.Vm.CheckRecovery();

        Assert.Null(f.Vm.RecoveryOffer);
    }

    [Fact]
    public void WhatACrashLeftIsOffered()
    {
        using var f = new ViewModelFixture();
        Crash(f, "report.pdf", f.Dir.Sub("report.pdf"));

        f.Vm.CheckRecovery();

        var entry = Assert.Single(f.Vm.RecoveryOffer!);
        Assert.Equal("report.pdf", entry.Meta.Title);
    }

    [Fact]
    public async Task RestoringOpensItAsADocumentWithUnsavedChanges()
    {
        using var f = new ViewModelFixture();
        string original = f.Pdf("report.pdf");
        Crash(f, "report.pdf", original);
        f.Vm.CheckRecovery();

        await f.Vm.RestoreAsync();

        Assert.Null(f.Vm.RecoveryOffer);
        var tab = Assert.Single(f.Vm.Documents);
        Assert.True(tab.IsDirty);
        Assert.Equal(original, tab.Path);
        Assert.Equal("Unsaved title", DocumentMetadata.Read(tab.Document).Title);
    }

    [Fact]
    public async Task ARestoredCopyOfAReadOnlyFileNeedsAName()
    {
        using var f = new ViewModelFixture();
        string original = f.Pdf("report.pdf");
        Crash(f, "report.pdf", original);
        f.Vm.CheckRecovery();
        File.SetAttributes(original, FileAttributes.ReadOnly);
        try
        {
            await f.Vm.RestoreAsync();

            var tab = Assert.Single(f.Vm.Documents);
            Assert.True(tab.ReadOnly);
            Assert.True(AppViewModel.NeedsName(tab));
        }
        finally
        {
            File.SetAttributes(original, FileAttributes.Normal);
        }
    }

    [Fact]
    public async Task ARestoredDocumentSavesOverTheOriginal()
    {
        using var f = new ViewModelFixture();
        string original = f.Pdf("report.pdf");
        Crash(f, "report.pdf", original);
        f.Vm.CheckRecovery();
        await f.Vm.RestoreAsync();

        Assert.True(f.Vm.Save(f.Vm.ActiveDocument!));

        Assert.Equal("Unsaved title", DocumentMetadata.Read(PdfDocument.Open(original)).Title);
        Assert.False(f.Vm.ActiveDocument!.IsDirty);
    }

    [Fact]
    public async Task ARestoredDocumentIsNotOfferedAgainAfterItIsSaved()
    {
        using var f = new ViewModelFixture();
        Crash(f, "report.pdf", f.Pdf("report.pdf"));
        f.Vm.CheckRecovery();
        await f.Vm.RestoreAsync();
        f.Vm.Save(f.Vm.ActiveDocument!);

        f.Vm.CheckRecovery();

        Assert.Null(f.Vm.RecoveryOffer);
    }

    [Fact]
    public async Task ADocumentWithNoFileComesBackNeedingAName()
    {
        using var f = new ViewModelFixture();
        Crash(f, "scan.pdf", null);
        f.Vm.CheckRecovery();

        await f.Vm.RestoreAsync();

        Assert.True(AppViewModel.NeedsName(f.Vm.ActiveDocument!));
        Assert.Equal("scan.pdf", f.Vm.ActiveDocument!.Title);
    }

    [Fact]
    public void DiscardingRemovesWhatWasLeft()
    {
        using var f = new ViewModelFixture();
        Crash(f, "a.pdf", null);
        Crash(f, "b.pdf", null);
        f.Vm.CheckRecovery();

        f.Vm.DiscardRecovery();
        f.Vm.CheckRecovery();

        Assert.Null(f.Vm.RecoveryOffer);
        Assert.Empty(new RecoveryStore(f.Dir.Sub("recovery")).List());
    }

    [Fact]
    public async Task EveryCommitIsWrittenAndAClosedDocumentLeavesNothing()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenAsync(f.Pdf());
        var tab = f.Vm.ActiveDocument!;
        Pdfs.Retitle(tab.Session, "x");
        tab.Commit("x");
        var store = new RecoveryStore(f.Dir.Sub("recovery"));
        for (int i = 0; i < 50 && store.List().Count == 0; i++) Thread.Sleep(20);

        Assert.Single(store.List());

        f.Vm.Close(tab);
        Assert.Empty(store.List());
    }
}
