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
[Collection("Application")]
public sealed class CreateToolTests
{
    private static readonly PdfPageSetup A4 = new();

    private static byte[] Png() => PngWriter.Encode(new PdfRgbaImage(8, 8, Enumerable.Repeat((byte)200, 8 * 8 * 4).ToArray()));

    private static PdfDocument Open(MadePdf made) => PdfDocument.Open(made.Bytes);

    [Fact]
    public Task APictureDroppedOnTheTextBoxIsListed() => Sta.Run(() =>
    {
        var panel = new CreatePanel();
        var e = BatchDropTests.Drop(panel.TypedText, @"C:\x\a.png");
        panel.TypedText.RaiseEvent(e);

        Assert.True(e.Handled);
        Assert.Single(panel.PictureList.Items);
        return Task.CompletedTask;
    });

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
    public void ABlankPageTakesTheSizeAskedAndTheOrientation()
    {
        var a3 = PdfMaker.Make(new(CreateSource.Blank, new PdfPageSetup(PdfPaper.A4, PdfOrientation.Landscape), "Blank.pdf", Pages: 2, Width: 841.89, Height: 1190.551), new FakeCodec(), new FakeFonts());
        var custom = PdfMaker.Make(new(CreateSource.Blank, A4, "Blank.pdf", Width: 100 * 72 / 25.4, Height: 150 * 72 / 25.4), new FakeCodec(), new FakeFonts());

        var page = Open(a3).Pages[1];
        Assert.Equal((1190.55, 841.89), (Math.Round(page.MediaBox.Width, 2), Math.Round(page.MediaBox.Height, 2)));
        page = Open(custom).Pages[0];
        Assert.Equal((283.46, 425.2), (Math.Round(page.MediaBox.Width, 2), Math.Round(page.MediaBox.Height, 2)));
    }

    [Theory]
    [InlineData(PdfOrientation.Landscape, 254, 143, 254, 143)]
    [InlineData(PdfOrientation.Landscape, 143, 254, 254, 143)]
    [InlineData(PdfOrientation.Portrait, 297, 210, 210, 297)]
    [InlineData(PdfOrientation.Portrait, 210, 297, 210, 297)]
    [InlineData(PdfOrientation.Auto, 297, 210, 297, 210)]
    public void ACustomSizeFollowsTheOrientationPicked(PdfOrientation orientation, double w, double h, double wide, double tall)
    {
        const double Mm = 72 / 25.4;
        var made = PdfMaker.Make(new(CreateSource.Blank, new PdfPageSetup(PdfPaper.A4, orientation), "Blank.pdf", Width: w * Mm, Height: h * Mm), new FakeCodec(), new FakeFonts());

        var page = Open(made).Pages[0];
        Assert.Equal((Math.Round(wide * Mm, 2), Math.Round(tall * Mm, 2)), (Math.Round(page.MediaBox.Width, 2), Math.Round(page.MediaBox.Height, 2)));
    }

    [Fact]
    public Task TheBlankPaperListHoldsMoreSizesAndACustomOne() => Sta.Run(() =>
    {
        var panel = new CreatePanel();
        panel.SourceBox.SelectedIndex = (int)CreateSource.Blank;
        panel.PaperBox.SelectedIndex = panel.PaperBox.Items.Count - 1;
        panel.CustomWidth.Text = "100";
        panel.CustomHeight.Text = "150";

        var request = panel.Request()!;
        Assert.Contains("A3", panel.PaperBox.Items.Cast<string>());
        Assert.Equal((283.46, 425.2), (Math.Round(request.Width!.Value, 2), Math.Round(request.Height!.Value, 2)));

        panel.CustomWidth.Text = "2";
        Assert.False(panel.Action!.CanRun());

        panel.SourceBox.SelectedIndex = (int)CreateSource.Text;
        Assert.DoesNotContain("A3", panel.PaperBox.Items.Cast<string>());
        return Task.CompletedTask;
    });

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
    public void TheFamilyAskedForIsTheOneEmbedded()
    {
        var made = PdfMaker.Make(new(CreateSource.Text, A4, "Text.pdf", Text: "Hello", Family: "Courier New"), new FakeCodec(), new SystemFontSource());

        var document = Open(made);
        var fonts = document.Dict(document.Pages[0].Resources, "Font")!;
        Assert.Contains(fonts.Entries, f => document.Name(document.Resolve(f.Value) as PdfDictionary, "BaseFont")!.Contains("Courier"));
    }

    [Fact]
    public Task TheFontListHoldsOnlyInstalledFamiliesAndTheRequestCarriesTheChoice() => Sta.Run(() =>
    {
        var installed = System.Windows.Media.Fonts.SystemFontFamilies.SelectMany(f => f.FamilyNames.Values).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var panel = new CreatePanel();
        panel.SourceBox.SelectedIndex = (int)CreateSource.Text;

        var families = panel.FontBox.Items.Cast<string>().ToList();
        Assert.All(families, family => Assert.Contains(family, installed));
        Assert.Equal(families[0], panel.Request()!.Family);
        panel.FontBox.SelectedIndex = families.Count - 1;
        Assert.Equal(families[^1], panel.Request()!.Family);
        return Task.CompletedTask;
    });

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
    public async Task PicturesTooLargeToDecodeAreSaidToBeLeftOut()
    {
        using var f = new ViewModelFixture();
        using var dir = new TempDir();
        string file = dir.File("a.tif", [1]);

        await CreateJob.RunAsync(f.Vm, new BigFrameCodec(), new FakeFonts(), new(CreateSource.Pictures, A4, "Pictures.pdf", Files: [file]));

        Assert.Equal("Some left out", f.Vm.Message!.Title);
        Assert.Equal("2 pictures were too large and were left out.", f.Vm.Message.Text);
    }

    private sealed class BigFrameCodec : IImageCodec
    {
        public PdfRgbaImage? Decode(byte[] data, string codec) => null;

        public IReadOnlyList<PdfRgbaImage>? DecodeFile(byte[] file) =>
            [new PdfRgbaImage(4, 4, new byte[64]), new PdfRgbaImage(40000, 40000, []), new PdfRgbaImage(50000, 50000, [])];

        public byte[] EncodeJpeg(PdfRgbaImage image, int quality) => [];
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
    public void ACancelStopsTheEngineOnPicturesTextAndBlankPages()
    {
        using var cancelled = new CancellationTokenSource();
        cancelled.Cancel();

        Assert.Throws<OperationCanceledException>(() =>
            PdfMaker.Make(new(CreateSource.Pictures, A4, "Pictures.pdf", Picture: Png()), new FakeCodec(), new FakeFonts(), cancelled.Token));
        Assert.Throws<OperationCanceledException>(() =>
            PdfMaker.Make(new(CreateSource.Text, A4, "Text.pdf", Text: "HelloWorld"), new FakeCodec(), new FakeFonts(), cancelled.Token));
        Assert.Throws<OperationCanceledException>(() =>
            PdfMaker.Make(new(CreateSource.Blank, A4, "Blank.pdf", Pages: 3), new FakeCodec(), new FakeFonts(), cancelled.Token));
    }

    [Fact]
    public Task ATextFileOverWhatTheBoxTakesIsKeptAsideAndUsed() => Sta.Run(async () =>
    {
        using var dir = new TempDir();
        Directory.CreateDirectory(dir.Path);
        string file = dir.File("long.txt", Encoding.ASCII.GetBytes(new string('a', 2 << 20)));
        var panel = new CreatePanel();
        panel.SourceBox.SelectedIndex = (int)CreateSource.Text;

        await panel.LoadTextFileAsync(file);

        Assert.Equal(2 << 20, panel.Request()!.Text.Length);
        Assert.Equal(System.Windows.Visibility.Collapsed, panel.TypedText.Visibility);
        Assert.Equal(System.Windows.Visibility.Visible, panel.LongTextRow.Visibility);
        Assert.Contains("long.txt", panel.LongTextNote.Text);
        Assert.True(panel.Action!.CanRun());
    });

    [Fact]
    public Task TheTypedTextComesBackFromTheNoteOrOnPickingAnotherSource() => Sta.Run(async () =>
    {
        using var dir = new TempDir();
        Directory.CreateDirectory(dir.Path);
        string big = dir.File("long.txt", Encoding.ASCII.GetBytes(new string('a', 2 << 20)));
        string small = dir.File("short.txt", "hello"u8.ToArray());
        var panel = new CreatePanel();
        panel.SourceBox.SelectedIndex = (int)CreateSource.Text;

        await panel.LoadTextFileAsync(big);
        panel.LongTextRow.Children.OfType<System.Windows.Controls.Button>().Single().RaiseEvent(new(System.Windows.Controls.Primitives.ButtonBase.ClickEvent));
        Assert.Equal(System.Windows.Visibility.Visible, panel.TypedText.Visibility);
        Assert.Equal(System.Windows.Visibility.Collapsed, panel.LongTextRow.Visibility);
        Assert.False(panel.Action!.CanRun());

        await panel.LoadTextFileAsync(big);
        panel.SourceBox.SelectedIndex = (int)CreateSource.Blank;
        panel.SourceBox.SelectedIndex = (int)CreateSource.Text;
        Assert.Equal("", panel.Request()!.Text);

        await panel.LoadTextFileAsync(big);
        await panel.LoadTextFileAsync(small);
        Assert.Equal("hello", panel.Request()!.Text);
        Assert.Equal(System.Windows.Visibility.Visible, panel.TypedText.Visibility);
    });

    [Fact]
    public Task ATextFileOver20MbIsRefused() => Sta.Run(async () =>
    {
        using var dir = new TempDir();
        Directory.CreateDirectory(dir.Path);
        string file = dir.File("huge.txt", new byte[21 << 20]);
        var panel = new CreatePanel();
        panel.SourceBox.SelectedIndex = (int)CreateSource.Text;

        await panel.LoadTextFileAsync(file);

        Assert.Equal(Loc.T("That file is too big. Pick a text file under 20 MB."), panel.Reason.Text);
        Assert.False(panel.Action!.CanRun());
    });

    [Fact]
    public Task TheTextFileFilterListsTheCommonExtensions() => Sta.Run(() =>
    {
        Assert.Contains("*.csv", TextFiles.Filter);
        Assert.Contains("*.md", TextFiles.Filter);
        return Task.CompletedTask;
    });

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
