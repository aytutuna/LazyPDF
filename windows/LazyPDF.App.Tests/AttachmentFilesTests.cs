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
    [InlineData("query.iqy")]
    [InlineData("connect.RDP")]
    [InlineData("page.mhtml")]
    [InlineData(@"..\..\tools\run.bat")]
    public void ProgramsAreRecognisedWhateverTheyEndWith(string name) =>
        Assert.True(AttachmentFiles.CouldRun(AttachmentFiles.SafeName(name)));

    [Theory]
    [InlineData("report.pdf")]
    [InlineData("photo.jpg")]
    [InlineData("notes")]
    public void DocumentsAreNot(string name) =>
        Assert.False(AttachmentFiles.CouldRun(AttachmentFiles.SafeName(name)));

    [Theory]
    [InlineData("NUL", "_NUL")]
    [InlineData("con.txt", "_con.txt")]
    [InlineData("COM1.pdf", "_COM1.pdf")]
    [InlineData("LPT9", "_LPT9")]
    [InlineData("console.txt", "console.txt")]
    [InlineData("NULL.txt", "NULL.txt")]
    [InlineData("com10.txt", "com10.txt")]
    public void ReservedDeviceNamesGetAPrefix(string name, string expected) =>
        Assert.Equal(expected, AttachmentFiles.SafeName(name));

    [Fact]
    public void TheNameIsTheOneWindowsWillWrite()
    {
        Assert.Equal("a.txt", AttachmentFiles.SafeName("a.txt. "));
        Assert.Equal("a_b.txt", AttachmentFiles.SafeName("a*b.txt"));
        Assert.Equal("c.txt", AttachmentFiles.SafeName(@"..\x\c.txt"));
    }
}
