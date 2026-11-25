using LazyPDF.App.Services;
using Xunit;

namespace LazyPDF.App.Tests;

public sealed class RecentFilesTests
{
    [Fact]
    public void TheNewestIsFirst()
    {
        using var dir = new TempDir();
        var recent = new RecentFiles(dir.Path);
        recent.Add(@"C:\docs\a.pdf");
        recent.Add(@"C:\docs\b.pdf");

        Assert.Equal([@"C:\docs\b.pdf", @"C:\docs\a.pdf"], recent.Load().Select(f => f.Path));
    }

    [Fact]
    public void OpeningAgainMovesItToTheFrontWithoutADuplicate()
    {
        using var dir = new TempDir();
        var recent = new RecentFiles(dir.Path);
        recent.Add(@"C:\docs\a.pdf");
        recent.Add(@"C:\docs\b.pdf");
        recent.Add(@"C:\DOCS\A.pdf");

        Assert.Equal(2, recent.Load().Count);
        Assert.Equal(@"C:\DOCS\A.pdf", recent.Load()[0].Path);
    }

    [Fact]
    public void TheViewIsRememberedAndKeptWhenOpenedAgain()
    {
        using var dir = new TempDir();
        var recent = new RecentFiles(dir.Path);
        recent.Add(@"C:\docs\a.pdf");
        recent.Add(@"C:\docs\b.pdf");
        recent.RememberView(@"C:\DOCS\A.pdf", 4, 1.5, 0);

        var files = new RecentFiles(dir.Path).Load();
        Assert.Equal([@"C:\docs\b.pdf", @"C:\docs\a.pdf"], files.Select(f => f.Path));
        Assert.Equal((4, 1.5), (files[1].Page, files[1].Zoom));

        recent.Add(@"C:\docs\a.pdf");
        Assert.Equal((4, 1.5), (recent.Load()[0].Page, recent.Load()[0].Zoom));
    }

    [Fact]
    public void AViewForAnUnlistedFileIsIgnored()
    {
        using var dir = new TempDir();
        var recent = new RecentFiles(dir.Path);
        recent.RememberView(@"C:\docs.pdf", 2, 1, 1);

        Assert.Empty(recent.Load());
    }

    [Fact]
    public void TheListIsCutAtItsLimit()
    {
        using var dir = new TempDir();
        var recent = new RecentFiles(dir.Path);
        for (int i = 0; i < RecentFiles.Limit + 5; i++) recent.Add($@"C:\docs\{i}.pdf");

        var files = recent.Load();

        Assert.Equal(RecentFiles.Limit, files.Count);
        Assert.Equal($@"C:\docs\{RecentFiles.Limit + 4}.pdf", files[0].Path);
    }

    [Fact]
    public void RemoveAndClearTakeEntriesOut()
    {
        using var dir = new TempDir();
        var recent = new RecentFiles(dir.Path);
        recent.Add(@"C:\docs\a.pdf");
        recent.Add(@"C:\docs\b.pdf");

        recent.Remove(@"C:\docs\A.pdf");
        Assert.Equal([@"C:\docs\b.pdf"], recent.Load().Select(f => f.Path));

        recent.Clear();
        Assert.Empty(recent.Load());
    }

    [Fact]
    public void ItSurvivesTheNextStart()
    {
        using var dir = new TempDir();
        var when = new DateTimeOffset(2026, 3, 1, 9, 0, 0, TimeSpan.Zero);
        new RecentFiles(dir.Path).Add(@"C:\docs\a.pdf", when);

        var loaded = new RecentFiles(dir.Path).Load();

        Assert.Equal(when, loaded[0].Opened);
    }

    [Fact]
    public void PinnedFilesComeFirstMostRecentlyPinnedFirst()
    {
        using var dir = new TempDir();
        var recent = new RecentFiles(dir.Path);
        recent.Add(@"C:\docs.pdf");
        recent.Add(@"C:\docs.pdf");
        recent.Add(@"C:\docs\c.pdf");
        recent.SetPinned(@"C:\docs.pdf", true);
        recent.SetPinned(@"C:\docs.pdf", true);

        Assert.Equal([@"C:\docs.pdf", @"C:\docs.pdf", @"C:\docs\c.pdf"], recent.Load().Select(f => f.Path));
    }

    [Fact]
    public void TheLimitCountsOnlyUnpinnedFiles()
    {
        using var dir = new TempDir();
        var recent = new RecentFiles(dir.Path);
        recent.Add(@"C:\docs\old.pdf");
        recent.SetPinned(@"C:\docs\old.pdf", true);
        for (int i = 0; i < RecentFiles.Limit + 3; i++) recent.Add($@"C:\docs\{i}.pdf");

        var files = recent.Load();
        Assert.Equal(RecentFiles.Limit + 1, files.Count);
        Assert.Equal(@"C:\docs\old.pdf", files[0].Path);
    }

    [Fact]
    public void OpeningAPinnedFileKeepsItPinned()
    {
        using var dir = new TempDir();
        var recent = new RecentFiles(dir.Path);
        recent.Add(@"C:\docs.pdf");
        recent.SetPinned(@"C:\docs.pdf", true);
        recent.Add(@"C:\docs.pdf");

        Assert.True(recent.Load().Single().Pinned);
    }

    [Fact]
    public void ClearKeepsPinnedFilesAndRemoveDropsThem()
    {
        using var dir = new TempDir();
        var recent = new RecentFiles(dir.Path);
        recent.Add(@"C:\docs.pdf");
        recent.Add(@"C:\docs.pdf");
        recent.SetPinned(@"C:\docs.pdf", true);

        recent.Clear();
        Assert.Equal([@"C:\docs.pdf"], recent.Load().Select(f => f.Path));

        recent.Remove(@"C:\docs.pdf");
        Assert.Empty(recent.Load());
    }
}
