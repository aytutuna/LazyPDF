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
    public async Task ADynamicXfaFormSaysItCannotBeFilledWhenItOpens()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenAsync(f.Dir.File("x.pdf", FormPdfs.DynamicXfa()));

        Assert.Equal("Form cannot be filled", f.Vm.Message?.Title);
    }

    [Fact]
    public async Task AFileWithoutScriptsOpensQuietly()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenAsync(f.Pdf());

        Assert.Null(f.Vm.Message);
    }
}
