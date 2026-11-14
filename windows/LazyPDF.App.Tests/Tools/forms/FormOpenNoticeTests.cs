using Xunit;

namespace LazyPDF.App.Tests;

public sealed class FormOpenNoticeTests
{
    [Fact]
    public async Task AFormWithScriptsSaysTheyWillNotRun()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenAsync(f.Dir.File("s.pdf", FormPdfs.Scripted()));

        Assert.Equal("Form scripts will not run", f.Vm.Message?.Title);
    }

    [Fact]
    public async Task ADynamicXfaFormSaysSoWhenItOpens()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenAsync(f.Dir.File("x.pdf", FormPdfs.DynamicXfa()));

        Assert.Equal("XFA form", f.Vm.Message?.Title);
        Assert.Equal("Open in another app", f.Vm.Message?.Action?.Text);
    }

    [Fact]
    public async Task ADynamicXfaFormDoesNotReplaceTheReadOnlyNotice()
    {
        using var f = new ViewModelFixture();
        string path = f.Dir.File("x.pdf", FormPdfs.DynamicXfa());
        File.SetAttributes(path, FileAttributes.ReadOnly);
        try
        {
            await f.Vm.OpenAsync(path);

            Assert.Equal("File is read-only", f.Vm.Message?.Title);
        }
        finally
        {
            File.SetAttributes(path, FileAttributes.Normal);
        }
    }

    [Fact]
    public async Task AStaticXfaFormOpensQuietly()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenAsync(f.Dir.File("x.pdf", FormPdfs.StaticXfa()));

        Assert.Null(f.Vm.Message);
    }

    [Fact]
    public async Task AFormWithScriptsOffersNoButton()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenAsync(f.Dir.File("s.pdf", FormPdfs.Scripted()));

        Assert.Null(f.Vm.Message?.Action);
    }

    [Fact]
    public async Task AFileWithoutScriptsOpensQuietly()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenAsync(f.Pdf());

        Assert.Null(f.Vm.Message);
    }
}
