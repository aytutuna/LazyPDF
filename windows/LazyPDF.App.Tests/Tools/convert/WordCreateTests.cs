using System.Text;
using LazyPDF.App.Documents;
using LazyPDF.App.Tools.Create;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// Making a PDF from a Word file in the create tool.
[Collection("Application")]
public sealed class WordCreateTests
{
    private static readonly PdfPageSetup A4 = new();

    private static byte[] Docx(string body)
    {
        const string Rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument";
        const string Namespace = "xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"";
        var entries = new List<ExportZipEntry>
        {
            new("[Content_Types].xml", Encoding.UTF8.GetBytes(
                "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"xml\" ContentType=\"application/xml\"/>" +
                "<Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/></Types>")),
            new("_rels/.rels", Encoding.UTF8.GetBytes(
                $"<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"{Rel}\" Target=\"word/document.xml\"/></Relationships>")),
            new("word/document.xml", Encoding.UTF8.GetBytes($"<w:document {Namespace}><w:body>{body}</w:body></w:document>")),
        };
        return ExportZip.Make(entries);
    }

    private static string Paragraph(string text) => $"<w:p><w:r><w:t>{text}</w:t></w:r></w:p>";

    private static CreateRequest Request(string path) => new(CreateSource.Word, A4, "Letter.pdf", Files: [path]);

    [Fact]
    public async Task AWordFileBecomesATabWithANoteThatTheLayoutCanDiffer()
    {
        using var f = new ViewModelFixture();
        string file = f.Dir.File("letter.docx", Docx(Paragraph("Dear reader")));

        await CreateJob.RunAsync(f.Vm, new FakeCodec(), new FakeFonts(), Request(file));

        var tab = f.Vm.ActiveDocument!;
        Assert.Equal("Letter.pdf", tab.Title);
        Assert.True(tab.IsDirty);
        Assert.False(f.Vm.Message!.IsError);
        Assert.Equal("Made without Office", f.Vm.Message.Title);
        Assert.Equal("Layout can differ from Word.", f.Vm.Message.Text);
        Assert.Contains("Dear reader", PlainTextWriter.Make(ExportLayout.Analyze(PdfDocument.Open(PdfMaker.Make(Request(file), new FakeCodec(), new FakeFonts()).Bytes))));
    }

    [Fact]
    public async Task WhatTheConverterLeftOutIsListedSortedByKind()
    {
        using var f = new ViewModelFixture();
        string body = "<w:p><w:r><w:t>Text</w:t></w:r><w:r><w:footnoteReference w:id=\"2\"/></w:r><w:r><w:commentReference w:id=\"1\"/></w:r></w:p>";
        string file = f.Dir.File("notes.docx", Docx(body));

        await CreateJob.RunAsync(f.Vm, new FakeCodec(), new FakeFonts(), Request(file));

        Assert.Equal("Layout can differ from Word. Left out: comment marks, footnotes.", f.Vm.Message!.Text);
    }

    [Fact]
    public async Task AFileThatIsNotAWordDocumentIsAProblem()
    {
        using var f = new ViewModelFixture();

        await CreateJob.RunAsync(f.Vm, new FakeCodec(), new FakeFonts(), Request(f.Dir.File("a.docx", Encoding.ASCII.GetBytes("not a zip at all"))));

        Assert.True(f.Vm.Message!.IsError);
        Assert.Equal("Word file cannot be read", f.Vm.Message.Title);
        Assert.Empty(f.Vm.Documents);
    }

    [Fact]
    public async Task AnOldDocFileIsNotSupported()
    {
        using var f = new ViewModelFixture();
        byte[] ole = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1, .. new byte[600]];

        await CreateJob.RunAsync(f.Vm, new FakeCodec(), new FakeFonts(), Request(f.Dir.File("old.docx", ole)));

        Assert.Equal("Word file is not supported", f.Vm.Message!.Title);
        Assert.Empty(f.Vm.Documents);
    }

    [Fact]
    public async Task AMissingFileIsAProblemNotACrash()
    {
        using var f = new ViewModelFixture();

        await CreateJob.RunAsync(f.Vm, new FakeCodec(), new FakeFonts(), Request(Path.Combine(f.Dir.Path, "gone.docx")));

        Assert.Equal("Word file cannot be read", f.Vm.Message!.Title);
    }

    [Fact]
    public void ACancelStopsTheConversionBeforeTheFileIsRead()
    {
        using var f = new ViewModelFixture();
        string file = f.Dir.File("letter.docx", Docx(Paragraph("x")));
        using var cancelled = new CancellationTokenSource();
        cancelled.Cancel();

        Assert.Throws<OperationCanceledException>(() => PdfMaker.Make(Request(file), new FakeCodec(), new FakeFonts(), cancelled.Token));
    }

    [Fact]
    public Task ThePanelNeedsAFileAndHidesThePageSetup() => Sta.Run(() =>
    {
        using var dir = new TempDir();
        Directory.CreateDirectory(dir.Path);
        string file = dir.File("report.docx", Docx(Paragraph("x")));
        var panel = new CreatePanel();
        panel.SourceBox.SelectedIndex = (int)CreateSource.Word;

        Assert.False(panel.Action!.CanRun());
        Assert.Equal(System.Windows.Visibility.Visible, panel.WordOptions.Visibility);
        Assert.Equal(System.Windows.Visibility.Collapsed, panel.SetupOptions.Visibility);

        panel.UseWordFile(file);

        Assert.True(panel.Action.CanRun());
        Assert.Equal("report.docx", panel.WordState.Text);
        var request = panel.Request()!;
        Assert.Equal(CreateSource.Word, request.Source);
        Assert.Equal("report.pdf", request.Title);
        Assert.Equal([file], request.Files);
        return Task.CompletedTask;
    });
}
