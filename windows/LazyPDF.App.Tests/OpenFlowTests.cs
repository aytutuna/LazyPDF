using LazyPDF.App.Documents;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// Opening: from a path, a picture or a text file, what an error says, and what the recent list remembers.
public sealed class OpenFlowTests
{
    [Fact]
    public void TheStripStartsWithHomeAndNothingElse()
    {
        using var f = new ViewModelFixture();

        Assert.Equal([HomeTab.Instance], f.Vm.Strip);
        Assert.True(f.Vm.IsHome);
        Assert.Null(f.Vm.ActiveDocument);
    }

    [Fact]
    public async Task APdfOpensInATabAndBecomesTheActiveOne()
    {
        using var f = new ViewModelFixture();
        string path = f.Pdf("report.pdf");

        await f.Vm.OpenAsync(path);

        var tab = Assert.Single(f.Vm.Documents);
        Assert.Same(tab, f.Vm.ActiveTab);
        Assert.False(f.Vm.IsHome);
        Assert.Equal("report.pdf", tab.Title);
        Assert.Equal(path, tab.Path);
        Assert.Equal([HomeTab.Instance, tab], f.Vm.Strip);
    }

    [Fact]
    public async Task OpeningTheSameFileAgainShowsTheTabItAlreadyHas()
    {
        using var f = new ViewModelFixture();
        string path = f.Pdf();
        await f.Vm.OpenAsync(path);
        await f.Vm.OpenAsync(f.Pdf("b.pdf"));
        f.Vm.ActiveTab = HomeTab.Instance;

        await f.Vm.OpenAsync(path.ToUpperInvariant());

        Assert.Equal(2, f.Vm.Documents.Count());
        Assert.Equal("a.pdf", f.Vm.ActiveDocument?.Title);
    }

    [Fact]
    public async Task SeveralFilesOpenInOrderAndTheLastIsActive()
    {
        using var f = new ViewModelFixture();

        await f.Vm.OpenFilesAsync([f.Pdf("a.pdf"), f.Pdf("b.pdf"), f.Pdf("c.pdf")]);

        Assert.Equal(["a.pdf", "b.pdf", "c.pdf"], f.Vm.Documents.Select(d => d.Title));
        Assert.Equal("c.pdf", f.Vm.ActiveDocument?.Title);
    }

    [Fact]
    public async Task APictureOpensAsAnUnsavedDocumentWithNoFile()
    {
        using var f = new ViewModelFixture();
        string path = f.Dir.File("photo.jpg", [1, 2, 3, 4]);

        await f.Vm.OpenAsync(path);

        var tab = f.Vm.ActiveDocument!;
        Assert.Equal("photo.pdf", tab.Title);
        Assert.Null(tab.Path);
        Assert.True(tab.IsDirty);
        Assert.True(AppViewModel.NeedsName(tab));
        Assert.Empty(f.Vm.Recent);
    }

    [Fact]
    public async Task ATextFileOpensAsAnUnsavedDocument()
    {
        using var f = new ViewModelFixture();
        string path = f.Dir.File("notes.txt", "Some notes."u8.ToArray());

        await f.Vm.OpenAsync(path);

        Assert.Equal("notes.pdf", f.Vm.ActiveDocument?.Title);
        Assert.True(f.Vm.ActiveDocument?.IsDirty);
    }

    [Fact]
    public async Task ATextThatNeedsAFontThereIsNoneForSaysSoInWords()
    {
        using var f = new ViewModelFixture();
        string path = f.Dir.File("tr.txt", System.Text.Encoding.UTF8.GetBytes("Çalışma"));

        await f.Vm.OpenAsync(path);

        Assert.Empty(f.Vm.Documents);
        Assert.Equal("Nothing to open", f.Vm.Message?.Title);
        Assert.True(f.Vm.Message?.IsError);
    }

    [Fact]
    public async Task AFileThatIsNotThereIsSaidInWordsAndOpensNothing()
    {
        using var f = new ViewModelFixture();

        await f.Vm.OpenAsync(f.Dir.Sub("gone.pdf"));

        Assert.Empty(f.Vm.Documents);
        Assert.Equal("File not found", f.Vm.Message?.Title);
        Assert.Contains("gone.pdf", f.Vm.Message?.Text);
    }

    [Fact]
    public async Task AFileTooLargeToHoldIsSaidInWordsAndOpensNothing()
    {
        using var f = new ViewModelFixture();
        string path = f.Dir.File("huge.pdf", []);
        using (var stream = new FileStream(path, FileMode.Open)) stream.SetLength(int.MaxValue + 1L);

        await f.Vm.OpenAsync(path);

        Assert.Empty(f.Vm.Documents);
        Assert.Equal("File is too large", f.Vm.Message?.Title);
        Assert.Contains("huge.pdf", f.Vm.Message?.Text);
    }

    [Fact]
    public async Task ATabThatCannotBeBuiltIsSaidInWordsNotLost()
    {
        using var dir = new TempDir();
        var vm = new AppViewModel(() => throw new NotSupportedException(), new FakeCodec(), new FakeFonts(), new FakeSisters(),
                                  dir.Sub("settings"), dir.Sub("recovery"), dir.Sub("print"));

        await vm.OpenAsync(dir.File("a.pdf", Pdfs.Text()));

        Assert.Empty(vm.Documents);
        Assert.Equal("File cannot be opened", vm.Message?.Title);
        Assert.True(vm.Message?.IsError);
        Assert.Contains("a.pdf", vm.Message?.Text);
    }

    [Fact]
    public void AnUnknownErrorSaysTheFileCouldNotBeOpened()
    {
        var problem = Problems.Open(new NotSupportedException(), "a.pdf");

        Assert.Equal("File cannot be opened", problem.Title);
        Assert.Equal("a.pdf could not be opened.", problem.Text);
    }

    [Theory]
    [InlineData(typeof(OutOfMemoryException))]
    [InlineData(typeof(PdfReadException))]
    public void AFileTooLargeIsNotReportedAsOneAnotherProgramHolds(Type kind)
    {
        Exception error = kind == typeof(PdfReadException)
            ? new PdfReadException(PdfReadProblem.Unsupported, DocumentOpener.TooLarge)
            : new OutOfMemoryException();

        var problem = Problems.Open(error, "a.pdf");

        Assert.Equal("File is too large", problem.Title);
        Assert.Equal("a.pdf is too large for Lazy PDF to open.", problem.Text);
    }

    [Fact]
    public async Task AFileThatIsNotAPdfIsSaidInWords()
    {
        using var f = new ViewModelFixture();
        string path = f.Dir.File("fake.pdf", "just words"u8.ToArray());

        await f.Vm.OpenAsync(path);

        Assert.Empty(f.Vm.Documents);
        Assert.Equal("Not a PDF", f.Vm.Message?.Title);
        Assert.Contains("fake.pdf", f.Vm.Message?.Text);
    }

    [Fact]
    public async Task ADamagedFileSaysItIsDamagedAndOffersAnEarlierCopy()
    {
        using var f = new ViewModelFixture();
        string path = f.Dir.File("broken.pdf", "%PDF-1.7\n1 0 obj\n<< /Type /Catalog"u8.ToArray());

        await f.Vm.OpenAsync(path);

        Assert.Empty(f.Vm.Documents);
        Assert.True(f.Vm.Message?.IsError);
        Assert.Contains("broken.pdf", f.Vm.Message?.Text);
    }

    [Fact]
    public async Task ADocumentTheSystemCannotDrawOpensWithANotice()
    {
        using var f = new ViewModelFixture { Draws = false };

        await f.Vm.OpenAsync(f.Pdf());

        Assert.Single(f.Vm.Documents);
        Assert.Equal("Pages cannot be shown", f.Vm.Message?.Title);
        Assert.False(f.Vm.Message?.IsError);
    }

    [Fact]
    public async Task AnOpenedFileIsRememberedAndAMissingOneIsForgotten()
    {
        using var f = new ViewModelFixture();
        string path = f.Pdf("kept.pdf");
        await f.Vm.OpenAsync(path);

        Assert.Equal(["kept.pdf"], f.Vm.Recent.Select(r => r.Name));
        Assert.True(f.Vm.Recent[0].Exists);

        File.Delete(path);
        await f.Vm.OpenAsync(path.Replace("kept", "kept2"));
        f.Vm.Close(f.Vm.ActiveDocument!);
        Assert.Equal(["kept.pdf"], f.Vm.Recent.Select(r => r.Name));
        Assert.False(f.Vm.Recent[0].Exists);

        await f.Vm.OpenAsync(path);
        Assert.Empty(f.Vm.Recent);
    }

    [Fact]
    public async Task TheRecentListCanBeEdited()
    {
        using var f = new ViewModelFixture();
        string a = f.Pdf("a.pdf");
        string b = f.Pdf("b.pdf");
        await f.Vm.OpenFilesAsync([a, b]);

        f.Vm.ForgetRecent(a);
        Assert.Equal(["b.pdf"], f.Vm.Recent.Select(r => r.Name));

        f.Vm.ClearRecent();
        Assert.Empty(f.Vm.Recent);
    }

    [Fact]
    public async Task EveryChangeIsAnnouncedWithAnEmptyName()
    {
        using var f = new ViewModelFixture();
        var names = new List<string?>();
        f.Vm.PropertyChanged += (_, e) => names.Add(e.PropertyName);

        await f.Vm.OpenAsync(f.Pdf());

        Assert.NotEmpty(names);
        Assert.All(names, n => Assert.Equal("", n));
    }
}
