using System.Text;
using LazyPDF.App.Documents;
using LazyPDF.App.Services;
using LazyPDF.App.Tools.Create;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// Making a PDF from a Word or Excel file in the create tool.
[Collection("Application")]
public sealed class OfficeCreateTests
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

    private static byte[] Xlsx(string sheet)
    {
        const string Main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main";
        const string Rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships";
        const string Pkg = "http://schemas.openxmlformats.org/package/2006/relationships";
        const string Sheet = "application/vnd.openxmlformats-officedocument.spreadsheetml.";
        var entries = new List<ExportZipEntry>
        {
            new("[Content_Types].xml", Encoding.UTF8.GetBytes(
                "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"xml\" ContentType=\"application/xml\"/>" +
                $"<Override PartName=\"/xl/workbook.xml\" ContentType=\"{Sheet}sheet.main+xml\"/>" +
                $"<Override PartName=\"/xl/worksheets/sheet1.xml\" ContentType=\"{Sheet}worksheet+xml\"/>" +
                $"<Override PartName=\"/xl/worksheets/sheet2.xml\" ContentType=\"{Sheet}worksheet+xml\"/></Types>")),
            new("_rels/.rels", Encoding.UTF8.GetBytes(
                $"<Relationships xmlns=\"{Pkg}\"><Relationship Id=\"rId1\" Type=\"{Rel}/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>")),
            new("xl/workbook.xml", Encoding.UTF8.GetBytes(
                $"<workbook xmlns=\"{Main}\" xmlns:r=\"{Rel}\"><sheets><sheet name=\"S\" sheetId=\"1\" r:id=\"rId1\"/><sheet name=\"H\" sheetId=\"2\" state=\"hidden\" r:id=\"rId2\"/></sheets></workbook>")),
            new("xl/_rels/workbook.xml.rels", Encoding.UTF8.GetBytes(
                $"<Relationships xmlns=\"{Pkg}\"><Relationship Id=\"rId1\" Type=\"{Rel}/worksheet\" Target=\"worksheets/sheet1.xml\"/>" +
                $"<Relationship Id=\"rId2\" Type=\"{Rel}/worksheet\" Target=\"worksheets/sheet2.xml\"/></Relationships>")),
            new("xl/worksheets/sheet1.xml", Encoding.UTF8.GetBytes($"<worksheet xmlns=\"{Main}\">{sheet}</worksheet>")),
            new("xl/worksheets/sheet2.xml", Encoding.UTF8.GetBytes($"<worksheet xmlns=\"{Main}\"><sheetData/></worksheet>")),
        };
        return ExportZip.Make(entries);
    }

    private static string Cell(string text) => $"<sheetData><row r=\"1\"><c r=\"A1\" t=\"inlineStr\"><is><t>{text}</t></is></c></row></sheetData>";

    private static string Paragraph(string text) => $"<w:p><w:r><w:t>{text}</w:t></w:r></w:p>";

    private static CreateRequest Request(string path) => new(CreateSource.Office, A4, "Letter.pdf", Files: [path]);

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
    public async Task AnExcelFileBecomesATabWithANoteThatNamesExcel()
    {
        using var f = new ViewModelFixture();
        string file = f.Dir.File("sales.xlsx", Xlsx(Cell("Quarterly sales")));

        await CreateJob.RunAsync(f.Vm, new FakeCodec(), new FakeFonts(), Request(file));

        Assert.Equal("Letter.pdf", f.Vm.ActiveDocument!.Title);
        Assert.False(f.Vm.Message!.IsError);
        Assert.Equal("Made without Office", f.Vm.Message.Title);
        Assert.Equal("Layout can differ from Excel. Left out: hidden sheets.", f.Vm.Message.Text);
        Assert.Contains("Quarterly sales", PlainTextWriter.Make(ExportLayout.Analyze(PdfDocument.Open(PdfMaker.Make(Request(file), new FakeCodec(), new FakeFonts()).Bytes))));
    }

    [Fact]
    public async Task WhatAWorkbookHadThatWasLeftOutIsListedSortedByKind()
    {
        using var f = new ViewModelFixture();
        string sheet = "<sheetData><row r=\"1\"><c r=\"A1\" t=\"inlineStr\"><is><t>Total</t></is></c><c r=\"B1\"><f>1+1</f></c></row></sheetData><conditionalFormatting sqref=\"A1\"><cfRule type=\"cellIs\" priority=\"1\"/></conditionalFormatting>";
        string file = f.Dir.File("sales.xlsx", Xlsx(sheet));

        await CreateJob.RunAsync(f.Vm, new FakeCodec(), new FakeFonts(), Request(file));

        Assert.Equal("Layout can differ from Excel. Left out: conditional formatting, formulas without a saved result (shown empty), hidden sheets.", f.Vm.Message!.Text);
    }

    [Fact]
    public async Task AFileThatIsNotAnExcelWorkbookIsAProblem()
    {
        using var f = new ViewModelFixture();

        await CreateJob.RunAsync(f.Vm, new FakeCodec(), new FakeFonts(), Request(f.Dir.File("a.xlsx", Encoding.ASCII.GetBytes("not a zip at all"))));

        Assert.True(f.Vm.Message!.IsError);
        Assert.Equal("Excel file cannot be read", f.Vm.Message.Title);
        Assert.Empty(f.Vm.Documents);
    }

    [Fact]
    public async Task AnOldXlsFileIsNotSupported()
    {
        using var f = new ViewModelFixture();
        byte[] ole = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1, .. new byte[600]];

        await CreateJob.RunAsync(f.Vm, new FakeCodec(), new FakeFonts(), Request(f.Dir.File("old.xlsx", ole)));

        Assert.Equal("Excel file is not supported", f.Vm.Message!.Title);
        Assert.Empty(f.Vm.Documents);
    }

    [Fact]
    public async Task AWorkbookWithNothingToPrintIsNotSupported()
    {
        using var f = new ViewModelFixture();

        await CreateJob.RunAsync(f.Vm, new FakeCodec(), new FakeFonts(), Request(f.Dir.File("empty.xlsx", Xlsx("<sheetData/>"))));

        Assert.Equal("Excel file is not supported", f.Vm.Message!.Title);
    }

    [Fact]
    public void OfficeFilesAreToldApartByTheirExtension()
    {
        Assert.Equal(OfficeApp.Word, FileKinds.OfficeAppOf(@"C:\Letter.DOCX"));
        Assert.Equal(OfficeApp.Excel, FileKinds.OfficeAppOf(@"C:\sales.xlsx"));
        Assert.Null(FileKinds.OfficeAppOf(@"C:\old.xls"));
        Assert.Equal("Office files|*.docx;*.xlsx", FileKinds.OfficeFilter("Office files"));
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
        panel.SourceBox.SelectedIndex = (int)CreateSource.Office;

        Assert.False(panel.Action!.CanRun());
        Assert.Equal(System.Windows.Visibility.Visible, panel.OfficeOptions.Visibility);
        Assert.Equal(System.Windows.Visibility.Collapsed, panel.SetupOptions.Visibility);

        panel.UseOfficeFile(file);

        Assert.True(panel.Action.CanRun());
        Assert.Equal("report.docx", panel.OfficeState.Text);
        var request = panel.Request()!;
        Assert.Equal(CreateSource.Office, request.Source);
        Assert.Equal("report.pdf", request.Title);
        Assert.Equal([file], request.Files);

        string book = dir.File("sales.xlsx", Xlsx(Cell("x")));
        panel.UseOfficeFile(book);

        Assert.Equal("sales.xlsx", panel.OfficeState.Text);
        Assert.Equal("sales.pdf", panel.Request()!.Title);
        return Task.CompletedTask;
    });
}
