using System.IO.Compression;
using LazyPDF.App.Services;
using LazyPDF.App.Tools.Export;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// The export tool: which pages, what each format writes, and what the window is told.
public sealed class ExportToolTests
{
    private static ExportSource SourceOf(string name, byte[] pdf, IImageCodec? codec = null, string? password = null) =>
        new(pdf, password, null, new FakeRenderer(), codec ?? new FakeCodec(), name);

    private static string Read(string docx, string part)
    {
        using var zip = ZipFile.OpenRead(docx);
        using var reader = new StreamReader(zip.GetEntry(part)!.Open());
        return reader.ReadToEnd();
    }

    // Text on the first line of a page reads as a running head, so the pages start lower down.
    private static byte[] Report(int pages) =>
        Pdfs.Text(pages, "\n\n\n\nHello from the tests.\nA second line to follow it.\nIt ends");

    private static byte[] Png() => PngWriter.Encode(new PdfRgbaImage(8, 8, Enumerable.Repeat((byte)200, 8 * 8 * 4).ToArray()));

    [Fact]
    public void PagesAreAllTheCurrentOneOrWhatWasTyped()
    {
        Assert.Null(ExportPages.Of(PageScope.All, "", 2, 5).Pages);
        Assert.Equal([2], ExportPages.Of(PageScope.Current, "", 2, 5).Pages);
        Assert.Equal([0, 1, 4], ExportPages.Of(PageScope.Typed, "1-2, 5, 2", 0, 5).Pages);
    }

    [Fact]
    public void PagesTypedWrongSayWhatIsWrong()
    {
        Assert.NotNull(ExportPages.Of(PageScope.Typed, "9", 0, 5).Error);
        Assert.NotNull(ExportPages.Of(PageScope.Typed, "", 0, 5).Error);
        Assert.NotNull(ExportPages.Of(PageScope.Typed, "two", 0, 5).Error);
    }

    [Theory]
    [InlineData(ExportFormat.Word, ".docx")]
    [InlineData(ExportFormat.Excel, ".xlsx")]
    [InlineData(ExportFormat.PowerPoint, ".pptx")]
    [InlineData(ExportFormat.Html, ".html")]
    [InlineData(ExportFormat.Markdown, ".md")]
    [InlineData(ExportFormat.Rtf, ".rtf")]
    [InlineData(ExportFormat.Text, ".txt")]
    public void EveryFormatWritesAFile(ExportFormat format, string extension)
    {
        using var dir = new TempDir();
        var options = new ExportOptions(format);
        Assert.Equal(extension, options.Extension);
        string target = dir.Sub("out" + extension);
        Directory.CreateDirectory(dir.Path);

        var result = Exporter.Write(SourceOf("a", Report(2)), options, target, CancellationToken.None);

        Assert.Equal(new ExportResult(1, target), result);
        Assert.True(new FileInfo(target).Length > 20);
        Assert.False(File.Exists(target + ".tmp"));
    }

    [Fact]
    public void OnlyTheChosenPagesAreWritten()
    {
        using var dir = new TempDir();
        Directory.CreateDirectory(dir.Path);
        string target = dir.Sub("out.docx");

        Exporter.Write(SourceOf("a", Report(3)), new ExportOptions(ExportFormat.Word, [1]), target, CancellationToken.None);

        string body = Read(target, "word/document.xml");
        Assert.Contains("Page 2", body);
        Assert.DoesNotContain("Page 1", body);
        Assert.DoesNotContain("Page 3", body);
    }

    [Fact]
    public void TurkishTextSurvivesAsUtf8()
    {
        using var dir = new TempDir();
        Directory.CreateDirectory(dir.Path);
        string target = dir.Sub("out.txt");
        var pdf = PdfFromText.Create("Çalışma notları: ğ ş ı İ ö ü", new SystemFontSource()).Bytes;

        Exporter.Write(SourceOf("a", pdf), new ExportOptions(ExportFormat.Text), target, CancellationToken.None);

        var bytes = File.ReadAllBytes(target);
        Assert.NotEqual(0xEF, bytes[0]);
        Assert.Contains("Çalışma notları: ğ ş ı İ ö ü", File.ReadAllText(target));
    }

    [Fact]
    public void HtmlCanKeepTheLinesWhereTheyAre()
    {
        using var dir = new TempDir();
        Directory.CreateDirectory(dir.Path);
        string reflowed = dir.Sub("a.html"), fixedLayout = dir.Sub("b.html");

        Exporter.Write(SourceOf("a", Report(1)), new ExportOptions(ExportFormat.Html), reflowed, CancellationToken.None);
        Exporter.Write(SourceOf("a", Report(1)), new ExportOptions(ExportFormat.Html, FixedHtml: true), fixedLayout, CancellationToken.None);

        Assert.NotEqual(File.ReadAllText(reflowed), File.ReadAllText(fixedLayout));
        Assert.Contains("position:absolute", File.ReadAllText(fixedLayout).Replace(" ", ""));
    }

    [Fact]
    public void PicturesOfPagesAreNumberedAndNeverReplaceFiles()
    {
        using var dir = new TempDir();
        Directory.CreateDirectory(dir.Path);
        var source = SourceOf("Report", Report(12));
        var options = new ExportOptions(ExportFormat.Pictures, [0, 11], Dpi: 72);

        var first = Exporter.Write(source, options, dir.Path, CancellationToken.None);
        Exporter.Write(source, options, dir.Path, CancellationToken.None);

        Assert.Equal(2, first.Files);
        var names = Directory.GetFiles(dir.Path).Select(Path.GetFileName).Order(StringComparer.Ordinal);
        Assert.Equal(new[] { "Report page 01.png", "Report page 01 (2).png", "Report page 12.png", "Report page 12 (2).png" }.Order(StringComparer.Ordinal), names);
        Assert.Equal(new byte[] { 0x89, 0x50, 0x4E, 0x47 }, File.ReadAllBytes(Path.Combine(dir.Path, "Report page 01.png"))[..4]);
    }

    [Fact]
    public void JpegPicturesAreJpeg()
    {
        using var dir = new TempDir();
        Directory.CreateDirectory(dir.Path);

        Exporter.Write(SourceOf("a", Report(1), new WicImageCodec()), new ExportOptions(ExportFormat.Pictures, Picture: PictureFormat.Jpeg, Quality: 60), dir.Path, CancellationToken.None);

        var bytes = File.ReadAllBytes(Path.Combine(dir.Path, "a page 1.jpg"));
        Assert.Equal(new byte[] { 0xFF, 0xD8 }, bytes[..2]);
    }

    [Fact]
    public void PagesTheSystemCannotDrawAreCounted()
    {
        using var dir = new TempDir();
        Directory.CreateDirectory(dir.Path);
        var source = SourceOf("a", Report(2)) with { Renderer = new FakeRenderer { Draws = false } };

        var result = Exporter.Write(source, new ExportOptions(ExportFormat.Pictures), dir.Path, CancellationToken.None);

        Assert.Equal(0, result.Files);
        Assert.Equal(2, result.Skipped);
    }

    [Fact]
    public void PicturesInTheFileAreSavedAsTheyAre()
    {
        using var dir = new TempDir();
        Directory.CreateDirectory(dir.Path);
        var codec = new WicImageCodec();
        var pdf = PdfFromPictures.Create([Png()], codec).Bytes;

        var result = Exporter.Write(SourceOf("a", pdf, codec), new ExportOptions(ExportFormat.Images), dir.Path, CancellationToken.None);

        Assert.Equal(1, result.Files);
        Assert.Single(Directory.GetFiles(dir.Path, "page1_*.png"));
    }

    [Fact]
    public void AFileOpenedWithAPasswordIsReadWithIt()
    {
        using var dir = new TempDir();
        Directory.CreateDirectory(dir.Path);
        var document = PdfDocument.Open(Report(1));
        var security = PdfSecurity.Create("open", "owner", PdfPermissions.All, PdfCryptStrength.Aes256, document.FirstId ?? []);
        var locked = document.SaveRewrite(new PdfSaveOptions(Security: security));
        string target = dir.Sub("out.txt");

        Exporter.Write(SourceOf("a", locked, password: "open"), new ExportOptions(ExportFormat.Text), target, CancellationToken.None);

        Assert.Contains("Hello from the tests", File.ReadAllText(target));
    }

    [Fact]
    public void ACopyBanStopsTheExportForWhoOpenedWithoutTheOwnerPassword()
    {
        Assert.False(Exporter.Allowed(PdfDocument.Open(Pdfs.Restricted(PdfPermissions.Print))));
        Assert.True(Exporter.Allowed(PdfDocument.Open(Pdfs.Restricted(PdfPermissions.Print | PdfPermissions.Copy))));
        Assert.True(Exporter.Allowed(PdfDocument.Open(Pdfs.Restricted(PdfPermissions.None), "owner")));
        Assert.True(Exporter.Allowed(PdfDocument.Open(Report(1))));
    }

    [Fact]
    public async Task ACancelledExportWritesNoFile()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenAsync(f.Dir.File("a.pdf", Report(3)));
        string target = f.Dir.Sub("out.docx");

        using var cancelled = new CancellationTokenSource();
        cancelled.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => Task.Run(() =>
            Exporter.Write(Exporter.Source(f.Vm.ActiveDocument!, new FakeCodec()), new ExportOptions(ExportFormat.Word), target, cancelled.Token)));

        Assert.False(File.Exists(target));
        Assert.Null(f.Vm.Message);
    }

    [Fact]
    public async Task AnExportTellsWhereTheFileWent()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenAsync(f.Dir.File("a.pdf", Report(2)));
        string target = f.Dir.Sub("a.md");

        await ExportJob.RunAsync(f.Vm.ActiveDocument!, f.Vm, new FakeCodec(), new ExportOptions(ExportFormat.Markdown), target);

        Assert.True(File.Exists(target));
        Assert.False(f.Vm.Message!.IsError);
        Assert.Contains("a.md", f.Vm.Message.Text);
        Assert.NotNull(f.Vm.Message.Action);
        Assert.False(f.Vm.IsBusy);
    }

    [Fact]
    public async Task AFolderThatIsNotThereIsAProblemNotACrash()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenAsync(f.Pdf());

        await ExportJob.RunAsync(f.Vm.ActiveDocument!, f.Vm, new FakeCodec(), new ExportOptions(ExportFormat.Text), Path.Combine(f.Dir.Path, "missing", "a.txt"));

        Assert.True(f.Vm.Message!.IsError);
        Assert.Equal("Not exported", f.Vm.Message.Title);
    }

    [Fact]
    public async Task AFileWithNoPicturesSaysSo()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenAsync(f.Pdf());
        string folder = f.Dir.Sub("pictures");
        Directory.CreateDirectory(folder);

        await ExportJob.RunAsync(f.Vm.ActiveDocument!, f.Vm, new FakeCodec(), new ExportOptions(ExportFormat.Images), folder);

        Assert.False(f.Vm.Message!.IsError);
        Assert.Equal("No pictures found", f.Vm.Message.Title);
        Assert.Empty(Directory.GetFiles(folder));
    }

    [Fact]
    public async Task ExportingDoesNotChangeTheDocument()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenAsync(f.Pdf());
        var tab = f.Vm.ActiveDocument!;
        int revision = tab.Revision;

        await ExportJob.RunAsync(tab, f.Vm, new FakeCodec(), new ExportOptions(ExportFormat.Rtf), f.Dir.Sub("a.rtf"));

        Assert.Equal(revision, tab.Revision);
        Assert.False(f.Vm.CanUndo);
    }

    private static ExportPage PageOf(int index, params ExportBlock[] blocks) => new(index, 612, 792, blocks, [], []);

    private static ExportTable Table() => new(new DisplayRect(0, 0, 100, 50), [["a", "b"]], null, false);

    private static ExportParagraph Words() => new(new DisplayRect(0, 60, 100, 12), [new ExportRun("words", false, false, 11)]);

    [Fact]
    public void AScanWithNoTextWritesNothingAndSaysSo()
    {
        using var dir = new TempDir();
        Directory.CreateDirectory(dir.Path);
        var blank = PdfFromText.Create(new string('\f', 2), new SystemFontSource()).Bytes;
        string target = dir.Sub("out.txt");

        var result = Exporter.Write(SourceOf("a", blank), new ExportOptions(ExportFormat.Text), target, CancellationToken.None);

        Assert.Equal(new ExportResult(0, target, Gap: ExportGap.NoText), result);
        Assert.False(File.Exists(target));
    }

    [Fact]
    public async Task AnExportWithNoTextIsANoticeThatPointsToMakeSearchable()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenAsync(f.Dir.File("blank.pdf", PdfFromText.Create(new string('\f', 2), new SystemFontSource()).Bytes));
        string target = f.Dir.Sub("out.xlsx");

        await ExportJob.RunAsync(f.Vm.ActiveDocument!, f.Vm, new FakeCodec(), new ExportOptions(ExportFormat.Excel), target);

        Assert.False(f.Vm.Message!.IsError);
        Assert.Equal("No text found", f.Vm.Message.Title);
        Assert.Contains("Make searchable", f.Vm.Message.Text);
        Assert.False(File.Exists(target));
    }

    [Fact]
    public async Task AnExportOfAScanPointsToMakeSearchableAsAScan()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenAsync(f.Dir.File("scan.pdf", PdfFromPictures.Create([new byte[] { 1 }], new FakeCodec(), new PdfPageSetup(PdfPaper.Picture, Margin: 0)).Bytes));
        string target = f.Dir.Sub("out.txt");

        await ExportJob.RunAsync(f.Vm.ActiveDocument!, f.Vm, new FakeCodec(), new ExportOptions(ExportFormat.Text), target);

        Assert.Equal("This looks like a scan", f.Vm.Message!.Title);
        Assert.Contains("Make searchable", f.Vm.Message.Text);
    }

    [Fact]
    public void AWorkbookWithTablesLeavesOutTheTextAroundThem()
    {
        var tablesOnly = new ExportDocument(null, [PageOf(0, Table()), PageOf(1, Table())], 11);
        var mixed = new ExportDocument(null, [PageOf(0, Table(), Words())], 11);

        Assert.Equal(ExportGap.None, Exporter.ExcelGap(tablesOnly));
        Assert.Equal(ExportGap.OutsideTables, Exporter.ExcelGap(mixed));
    }

    [Fact]
    public void AWorkbookStopsAtAThousandSheets()
    {
        var pages = Enumerable.Range(0, 1001).Select(i => PageOf(i, Words())).ToList();
        var tables = Enumerable.Range(0, 1001).Select(i => PageOf(i, Table())).ToList();

        Assert.Equal(ExportGap.PastSheetLimit, Exporter.ExcelGap(new ExportDocument(null, pages, 11)));
        Assert.Equal(ExportGap.PastSheetLimit, Exporter.ExcelGap(new ExportDocument(null, tables, 11)));
        Assert.Equal(ExportGap.None, Exporter.ExcelGap(new ExportDocument(null, pages.Take(1000).ToList(), 11)));
    }

    [Fact]
    public void PicturesOfAllPagesAreSavedPageByPage()
    {
        using var dir = new TempDir();
        Directory.CreateDirectory(dir.Path);
        var codec = new WicImageCodec();
        var pdf = PdfFromPictures.Create([Png(), Png(), Png()], codec).Bytes;

        var result = Exporter.Write(SourceOf("a", pdf, codec), new ExportOptions(ExportFormat.Images, [2, 0]), dir.Path, CancellationToken.None);

        Assert.Equal(2, result.Files);
        Assert.Equal(new[] { "page1_Im1.png", "page3_Im1.png" }, Directory.GetFiles(dir.Path).Select(Path.GetFileName).Order());
    }

    [Fact]
    public void AFailedWriteLeavesNoTempFileAndAFileOfThatNameAloneWhenItWorks()
    {
        using var dir = new TempDir();
        Directory.CreateDirectory(dir.Path);
        string stray = dir.Sub("out.txt.tmp");
        File.WriteAllText(stray, "mine");

        Exporter.Write(SourceOf("a", Report(1)), new ExportOptions(ExportFormat.Text), dir.Sub("out.txt"), CancellationToken.None);
        Assert.Throws<DirectoryNotFoundException>(() =>
            Exporter.Write(SourceOf("a", Report(1)), new ExportOptions(ExportFormat.Text), dir.Sub("missing\\out.txt"), CancellationToken.None));

        Assert.Equal("mine", File.ReadAllText(stray));
        Assert.Equal(new[] { "out.txt", "out.txt.tmp" }, Directory.GetFiles(dir.Path).Select(Path.GetFileName).Order());
    }

    [Fact]
    public void AFolderIsNamedByItsLastPartOrByTheDriveForARoot()
    {
        Assert.Equal("pictures", ExportJob.Leaf(@"C:\Users\me\pictures"));
        Assert.Equal("pictures", ExportJob.Leaf(@"C:\Users\me\pictures\"));
        Assert.Equal(@"D:\", ExportJob.Leaf(@"D:\"));
    }

    [Fact]
    public void PagesAreDrawnFromACopyThatLaterEditsDoNotReach()
    {
        var snapshot = Exporter.Snapshot(SourceOf("a", Report(3)));

        Assert.NotNull(snapshot);
        using (snapshot)
        {
            Assert.Equal(3, snapshot.PageCount);
            Assert.NotNull(snapshot.Render(2, 72));
        }
    }}
