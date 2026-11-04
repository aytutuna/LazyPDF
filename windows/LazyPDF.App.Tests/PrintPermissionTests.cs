using LazyPDF.App.Documents;
using LazyPDF.App.Services;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// Printing respects the file's permission, and a page that cannot be drawn is counted, not printed as success.
public sealed class PrintPermissionTests
{
    [Fact]
    public async Task AFileThatForbidsPrintingIsNotPrinted()
    {
        using var f = new ViewModelFixture();
        f.Sisters.PrintTaken = true;
        await f.Vm.OpenAsync(f.Dir.File("nope.pdf", Pdfs.Restricted(PdfPermissions.All & ~PdfPermissions.Print)));
        DocumentTab? asked = null;
        f.Vm.SystemPrintRequested += (_, t) => asked = t;

        f.Vm.Print();

        Assert.Empty(f.Sisters.Printed);
        Assert.Null(asked);
        Assert.Equal("Printing is not allowed", f.Vm.Message!.Title);
    }

    [Fact]
    public async Task AFileThatAllowsPrintingIsPrinted()
    {
        using var f = new ViewModelFixture();
        f.Sisters.PrintTaken = true;
        await f.Vm.OpenAsync(f.Dir.File("ok.pdf", Pdfs.Restricted(PdfPermissions.All & ~PdfPermissions.Copy)));

        f.Vm.Print();

        Assert.Single(f.Sisters.Printed);
    }

    [Fact]
    public void PagesTheRendererCannotDrawAreCounted()
    {
        var renderer = new FakeRenderer { Draws = false };
        var paginator = new PagePaginator(renderer, 3);

        for (int i = 0; i < 3; i++) paginator.GetPage(i);

        Assert.Equal(3, paginator.Blank);
    }
}
