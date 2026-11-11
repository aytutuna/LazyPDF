using System.Globalization;
using System.Text;
using LazyPDF.App.Documents;
using LazyPDF.App.Services;
using LazyPDF.App.Tools;
using LazyPDF.App.Tools.Create;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// The create tool: what each source makes, and the new tab it opens.
public sealed class CreateToolTests
{
    private static readonly PdfPageSetup A4 = new();

    private static byte[] Png() => PngWriter.Encode(new PdfRgbaImage(8, 8, Enumerable.Repeat((byte)200, 8 * 8 * 4).ToArray()));

    private static PdfDocument Open(MadePdf made) => PdfDocument.Open(made.Bytes);

    [Fact]
    public void BlankPagesAreEmptyAndAsBigAsAsked()
    {
        var made = PdfMaker.Make(new(CreateSource.Blank, new PdfPageSetup(PdfPaper.Letter, PdfOrientation.Landscape), "Blank.pdf", Pages: 3), new FakeCodec(), new FakeFonts());

        var document = Open(made);
        Assert.Equal(3, made.Pages);
        Assert.Equal(3, document.Pages.Count);
        Assert.Equal((792, 612), (document.Pages[0].MediaBox.Width, document.Pages[0].MediaBox.Height));
        Assert.Equal("", PlainTextWriter.Make(ExportLayout.Analyze(document)).Replace("\f", "").Trim());
    }

    [Fact]
    public void PicturesBecomePagesInTheOrderGiven()
    {
        using var dir = new TempDir();
        string wide = dir.File("a.png", Png()), second = dir.File("b.png", Png());

        var made = PdfMaker.Make(new(CreateSource.Pictures, A4, "Pictures.pdf", Files: [second, wide]), new WicImageCodec(), new FakeFonts());

        Assert.Equal(2, made.Pages);
        Assert.Equal(0, made.Unreadable);
        Assert.Equal(2, Open(made).Pages.Count);
    }

    [Fact]
    public void APictureThatCannotBeReadIsCountedAndTheRestStay()
    {
        using var dir = new TempDir();
        string good = dir.File("a.png", Png()), bad = dir.File("b.png", []);

        var made = PdfMaker.Make(new(CreateSource.Pictures, A4, "Pictures.pdf", Files: [good, bad]), new FakeCodec(), new FakeFonts());

        Assert.Equal(1, made.Pages);
        Assert.Equal(1, made.Unreadable);
    }

    [Fact]
    public void ThePictureOnTheClipboardIsOnePage()
    {
        var made = PdfMaker.Make(new(CreateSource.Pictures, new PdfPageSetup(PdfPaper.Picture, Margin: 10), "Clipboard.pdf", Picture: Png()), new WicImageCodec(), new FakeFonts());

        var page = Open(made).Pages[0];
        Assert.Equal(1, made.Pages);
        Assert.Equal((26, 26), (page.MediaBox.Width, page.MediaBox.Height));
    }

    [Fact]
    public void TurkishTextKeepsItsLetters()
    {
        var made = PdfMaker.Make(new(CreateSource.Text, A4, "Text.pdf", Text: "Çalışma notları: ğ ş ı İ ö ü", FontSize: 14), new FakeCodec(), new SystemFontSource());

        Assert.Equal(0, made.Unreadable);
        Assert.Contains("Çalışma notları: ğ ş ı İ ö ü", PlainTextWriter.Make(ExportLayout.Analyze(Open(made))));
    }

    [Fact]
    public void ALongTextRunsOverToMorePages()
    {
        string text = string.Join("\n", Enumerable.Range(0, 200).Select(n => $"Line {n}"));

        var made = PdfMaker.Make(new(CreateSource.Text, A4, "Text.pdf", Text: text), new FakeCodec(), new FakeFonts());

        Assert.True(made.Pages > 2);
    }

    [Fact]
    public async Task TheResultOpensInANewTabThatNeedsAName()
    {
        using var f = new ViewModelFixture();

        await CreateJob.RunAsync(f.Vm, new FakeCodec(), new FakeFonts(), new(CreateSource.Text, A4, "Text.pdf", Text: "Hello"));

        var tab = f.Vm.ActiveDocument!;
        Assert.Equal("Text.pdf", tab.Title);
        Assert.True(AppViewModel.NeedsName(tab));
        Assert.True(tab.IsDirty);
        Assert.Null(f.Vm.Message);
    }

    [Fact]
    public async Task ACreatedDocumentLeavesTheOpenOneAlone()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenAsync(f.Pdf());
        var first = f.Vm.ActiveDocument!;
        int revision = first.Revision;

        await CreateJob.RunAsync(f.Vm, new FakeCodec(), new FakeFonts(), new(CreateSource.Blank, A4, "Blank.pdf", Pages: 2));

        Assert.Equal(2, f.Vm.Documents.Count());
        Assert.Equal(revision, first.Revision);
        Assert.Equal(2, f.Vm.ActiveDocument!.PageCount);
    }

    [Fact]
    public async Task TextNoFontCanDrawIsAProblem()
    {
        using var f = new ViewModelFixture();

        await CreateJob.RunAsync(f.Vm, new FakeCodec(), new FakeFonts(), new(CreateSource.Text, A4, "Text.pdf", Text: "ğ ş ı"));

        Assert.True(f.Vm.Message!.IsError);
        Assert.Equal("No font for this text", f.Vm.Message.Title);
        Assert.Empty(f.Vm.Documents);
    }

    [Fact]
    public async Task PicturesNoneOfWhichCanBeReadAreAProblem()
    {
        using var f = new ViewModelFixture();
        string empty = f.Dir.File("a.png", []);

        await CreateJob.RunAsync(f.Vm, new FakeCodec(), new FakeFonts(), new(CreateSource.Pictures, A4, "Pictures.pdf", Files: [empty]));

        Assert.True(f.Vm.Message!.IsError);
        Assert.Equal("No picture to use", f.Vm.Message.Title);
        Assert.Empty(f.Vm.Documents);
    }

    [Fact]
    public async Task AMarginTooWideForThePageIsAProblem()
    {
        using var f = new ViewModelFixture();

        await CreateJob.RunAsync(f.Vm, new FakeCodec(), new FakeFonts(), new(CreateSource.Text, new PdfPageSetup(Margin: 400), "Text.pdf", Text: "Hello"));

        Assert.Equal("Margin is too wide", f.Vm.Message!.Title);
    }

    [Fact]
    public async Task APictureLeftOutIsReportedAfterTheTabOpens()
    {
        using var f = new ViewModelFixture();
        string good = f.Dir.File("a.png", Png()), bad = f.Dir.File("b.png", []);

        await CreateJob.RunAsync(f.Vm, new FakeCodec(), new FakeFonts(), new(CreateSource.Pictures, A4, "Pictures.pdf", Files: [good, bad]));

        Assert.Single(f.Vm.Documents);
        Assert.False(f.Vm.Message!.IsError);
        Assert.Equal("1 picture could not be read.", f.Vm.Message.Text);
    }

    // A host whose Cancel was pressed before the work began.
    private sealed class CancelledHost : IToolHost
    {
        public int Opened { get; private set; }

        public async Task RunBusyAsync(string text, Func<CancellationToken, Task> work)
        {
            using var cancelled = new CancellationTokenSource();
            cancelled.Cancel();
            try
            {
                await work(cancelled.Token);
            }
            catch (OperationCanceledException)
            {
            }
        }

        public void ShowProblem(Problem problem) => throw new InvalidOperationException(problem.Title);

        public void ShowNotice(string title, string text, NoticeAction? action = null) => throw new InvalidOperationException(title);

        public void SetStatus(string sentence)
        {
        }

        public Task OpenAsync(string path) => Task.CompletedTask;

        public Task<bool> OpenNewAsync(byte[] pdf, string title)
        {
            Opened++;
            return Task.FromResult(true);
        }

        public Task ReloadAsync(DocumentTab tab) => Task.CompletedTask;
    }

    [Fact]
    public async Task ACancelledCreateOpensNothing()
    {
        var host = new CancelledHost();

        await CreateJob.RunAsync(host, new FakeCodec(), new FakeFonts(), new(CreateSource.Blank, A4, "Blank.pdf", Pages: 3));

        Assert.Equal(0, host.Opened);
    }

    [Fact]
    public void ACancelStopsTheReadingOfPictures()
    {
        using var dir = new TempDir();
        Directory.CreateDirectory(dir.Path);
        string file = dir.File("a.png", Png());
        using var cancelled = new CancellationTokenSource();
        cancelled.Cancel();

        Assert.Throws<OperationCanceledException>(() =>
            PdfMaker.Make(new(CreateSource.Pictures, A4, "Pictures.pdf", Files: [file]), new FakeCodec(), new FakeFonts(), cancelled.Token));
    }

    [Fact]
    public void TextInUtf8OrWithAByteOrderMarkReadsAsWritten()
    {
        string text = "Çalışma notları: ğ ş ı İ ö ü";

        Assert.Equal(text, TextFiles.Decode(new UTF8Encoding(false).GetBytes(text)));
        Assert.Equal(text, TextFiles.Decode([.. new UTF8Encoding(true).GetPreamble(), .. new UTF8Encoding(false).GetBytes(text)]));
        Assert.Equal(text, TextFiles.Decode([.. Encoding.Unicode.GetPreamble(), .. Encoding.Unicode.GetBytes(text)]));
        Assert.Equal(text, TextFiles.Decode([.. Encoding.BigEndianUnicode.GetPreamble(), .. Encoding.BigEndianUnicode.GetBytes(text)]));
    }

    [Fact]
    public void TextThatIsNotUtf8IsReadInThePcCodePage()
    {
        Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
        var legacy = Encoding.GetEncoding(CultureInfo.CurrentCulture.TextInfo.ANSICodePage);
        // 0xFE never occurs in UTF-8; in Windows-1254 it is ş.
        byte[] bytes = [0xFE, 0x20, 0xFD];

        Assert.Equal(legacy.GetString(bytes), TextFiles.Decode(bytes));
    }}
