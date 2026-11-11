using LazyPDF.App.Services;
using Xunit;

namespace LazyPDF.App.Tests;

public sealed class AttachmentFilesTests
{
    [Theory]
    [InlineData("invoice.exe")]
    [InlineData("INVOICE.EXE")]
    [InlineData("invoice.exe ")]
    [InlineData("invoice.exe.")]
    [InlineData("invoice.exe. . ")]
    [InlineData("help.chm")]
    [InlineData("link.url")]
    [InlineData("setup.appref-ms")]
    [InlineData("budget.xlsm")]
    [InlineData("disk.ISO")]
    [InlineData("run.py")]
    [InlineData("search.search-ms")]
    [InlineData("update.msix")]
    [InlineData("notes.one")]
    [InlineData(@"..\..\tools\run.bat")]
    public void ProgramsAreRecognisedWhateverTheyEndWith(string name) =>
        Assert.True(AttachmentFiles.CouldRun(AttachmentFiles.SafeName(name)));

    [Theory]
    [InlineData("report.pdf")]
    [InlineData("photo.jpg")]
    [InlineData("notes")]
    public void DocumentsAreNot(string name) =>
        Assert.False(AttachmentFiles.CouldRun(AttachmentFiles.SafeName(name)));

    [Fact]
    public void TheNameIsTheOneWindowsWillWrite()
    {
        Assert.Equal("a.txt", AttachmentFiles.SafeName("a.txt. "));
        Assert.Equal("a_b.txt", AttachmentFiles.SafeName("a*b.txt"));
        Assert.Equal("c.txt", AttachmentFiles.SafeName(@"..\x\c.txt"));
    }
}
