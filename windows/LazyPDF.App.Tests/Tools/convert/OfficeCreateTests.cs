using System.Text;
using LazyPDF.App.Documents;
using LazyPDF.App.Services;
using LazyPDF.App.Tools.Create;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// Making a PDF from a Word, Excel or PowerPoint file in the create tool.
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

    private static byte[] Pptx(string title, bool hiddenSlide = false)
    {
        const string P = "http://schemas.openxmlformats.org/presentationml/2006/main";
        const string A = "http://schemas.openxmlformats.org/drawingml/2006/main";
        const string R = "http://schemas.openxmlformats.org/officeDocument/2006/relationships";
        const string Pkg = "http://schemas.openxmlformats.org/package/2006/relationships";
        const string Ml = "application/vnd.openxmlformats-officedocument.presentationml.";
        string Part(string root, string attributes, string inside) => $"<{root} xmlns:p=\"{P}\" xmlns:a=\"{A}\" xmlns:r=\"{R}\"{attributes}>{inside}</{root}>";
        string Rels(string type, string target) => $"<Relationships xmlns=\"{Pkg}\"><Relationship Id=\"rId1\" Type=\"{R}/{type}\" Target=\"{target}\"/></Relationships>";
        string shape = "<p:cSld><p:spTree><p:sp><p:nvSpPr><p:cNvPr id=\"2\" name=\"Title\"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>" +
            "<p:spPr><a:xfrm><a:off x=\"914400\" y=\"914400\"/><a:ext cx=\"4572000\" cy=\"914400\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></p:spPr>" +
            $"<p:txBody><a:bodyPr/><a:p><a:r><a:t>{title}</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld>";
        string theme = "<a:themeElements><a:clrScheme name=\"Office\"><a:dk1><a:srgbClr val=\"000000\"/></a:dk1><a:lt1><a:srgbClr val=\"FFFFFF\"/></a:lt1>" +
            "<a:dk2><a:srgbClr val=\"1F497D\"/></a:dk2><a:lt2><a:srgbClr val=\"EEECE1\"/></a:lt2><a:accent1><a:srgbClr val=\"4F81BD\"/></a:accent1><a:accent2><a:srgbClr val=\"C0504D\"/></a:accent2>" +
            "<a:accent3><a:srgbClr val=\"9BBB59\"/></a:accent3><a:accent4><a:srgbClr val=\"8064A2\"/></a:accent4><a:accent5><a:srgbClr val=\"4BACC6\"/></a:accent5><a:accent6><a:srgbClr val=\"F79646\"/></a:accent6>" +
            "<a:hlink><a:srgbClr val=\"0000FF\"/></a:hlink><a:folHlink><a:srgbClr val=\"800080\"/></a:folHlink></a:clrScheme>" +
            "<a:fontScheme name=\"Office\"><a:majorFont><a:latin typeface=\"Calibri\"/></a:majorFont><a:minorFont><a:latin typeface=\"Calibri\"/></a:minorFont></a:fontScheme></a:themeElements>";
        var slides = hiddenSlide ? new[] { (1, ""), (2, " show=\"0\"") } : new[] { (1, "") };
        var entries = new List<ExportZipEntry>();
        void Add(string path, string xml) => entries.Add(new ExportZipEntry(path, Encoding.UTF8.GetBytes(xml)));
        Add("[Content_Types].xml", "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"xml\" ContentType=\"application/xml\"/>" +
            $"<Override PartName=\"/ppt/presentation.xml\" ContentType=\"{Ml}presentation.main+xml\"/>" +
            string.Concat(slides.Select(s => $"<Override PartName=\"/ppt/slides/slide{s.Item1}.xml\" ContentType=\"{Ml}slide+xml\"/>")) +
            $"<Override PartName=\"/ppt/slideLayouts/slideLayout1.xml\" ContentType=\"{Ml}slideLayout+xml\"/>" +
            $"<Override PartName=\"/ppt/slideMasters/slideMaster1.xml\" ContentType=\"{Ml}slideMaster+xml\"/>" +
            "<Override PartName=\"/ppt/theme/theme1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.theme+xml\"/></Types>");
        Add("_rels/.rels", Rels("officeDocument", "ppt/presentation.xml"));
        Add("ppt/presentation.xml", Part("p:presentation", "",
            "<p:sldIdLst>" + string.Concat(slides.Select(s => $"<p:sldId id=\"{255 + s.Item1}\" r:id=\"rIdS{s.Item1}\"/>")) + "</p:sldIdLst><p:sldSz cx=\"9144000\" cy=\"6858000\"/>"));
        Add("ppt/_rels/presentation.xml.rels", $"<Relationships xmlns=\"{Pkg}\">" +
            string.Concat(slides.Select(s => $"<Relationship Id=\"rIdS{s.Item1}\" Type=\"{R}/slide\" Target=\"slides/slide{s.Item1}.xml\"/>")) + "</Relationships>");
        foreach (var (n, attributes) in slides)
        {
            Add($"ppt/slides/slide{n}.xml", Part("p:sld", attributes, shape));
            Add($"ppt/slides/_rels/slide{n}.xml.rels", Rels("slideLayout", "../slideLayouts/slideLayout1.xml"));
        }
        Add("ppt/slideLayouts/slideLayout1.xml", Part("p:sldLayout", "", "<p:cSld><p:spTree/></p:cSld>"));
        Add("ppt/slideLayouts/_rels/slideLayout1.xml.rels", Rels("slideMaster", "../slideMasters/slideMaster1.xml"));
        Add("ppt/slideMasters/slideMaster1.xml", Part("p:sldMaster", "", "<p:cSld><p:spTree/></p:cSld>"));
        Add("ppt/slideMasters/_rels/slideMaster1.xml.rels", Rels("theme", "../theme/theme1.xml"));
        Add("ppt/theme/theme1.xml", Part("a:theme", "", theme));
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
    public async Task APowerPointFileBecomesATabWithANoteThatNamesPowerPoint()
    {
        using var f = new ViewModelFixture();
        string file = f.Dir.File("deck.pptx", Pptx("Quarterly review"));

        await CreateJob.RunAsync(f.Vm, new FakeCodec(), new FakeFonts(), Request(file));

        Assert.Equal("Letter.pdf", f.Vm.ActiveDocument!.Title);
        Assert.False(f.Vm.Message!.IsError);
        Assert.Equal("Made without Office", f.Vm.Message.Title);
        Assert.Equal("Layout can differ from PowerPoint.", f.Vm.Message.Text);
        Assert.Contains("Quarterly review", PlainTextWriter.Make(ExportLayout.Analyze(PdfDocument.Open(PdfMaker.Make(Request(file), new FakeCodec(), new FakeFonts()).Bytes))));
    }

    [Fact]
    public async Task WhatAPresentationHadThatWasLeftOutIsListed()
    {
        using var f = new ViewModelFixture();

        await CreateJob.RunAsync(f.Vm, new FakeCodec(), new FakeFonts(), Request(f.Dir.File("deck.pptx", Pptx("One", hiddenSlide: true))));

        Assert.Equal("Layout can differ from PowerPoint. Left out: hidden slides.", f.Vm.Message!.Text);
    }

    [Fact]
    public async Task AFileThatIsNotAPowerPointPresentationIsAProblem()
    {
        using var f = new ViewModelFixture();

        await CreateJob.RunAsync(f.Vm, new FakeCodec(), new FakeFonts(), Request(f.Dir.File("a.pptx", Encoding.ASCII.GetBytes("not a zip at all"))));

        Assert.True(f.Vm.Message!.IsError);
        Assert.Equal("PowerPoint file cannot be read", f.Vm.Message.Title);
        Assert.Empty(f.Vm.Documents);
    }

    [Fact]
    public async Task APackageThatIsNotAPresentationIsNotSupported()
    {
        using var f = new ViewModelFixture();

        await CreateJob.RunAsync(f.Vm, new FakeCodec(), new FakeFonts(), Request(f.Dir.File("a.pptx", Docx(Paragraph("x")))));

        Assert.Equal("PowerPoint file is not supported", f.Vm.Message!.Title);
    }

    [Theory]
    [InlineData("old.doc")]
    [InlineData("old.XLS")]
    [InlineData("old.ppt")]
    public async Task AnOlderOfficeFileIsToldToBeSavedInTheNewFormat(string name)
    {
        using var f = new ViewModelFixture();
        byte[] ole = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1, .. new byte[600]];

        await CreateJob.RunAsync(f.Vm, new FakeCodec(), new FakeFonts(), Request(f.Dir.File(name, ole)));

        Assert.True(f.Vm.Message!.IsError);
        Assert.Equal("Older Office file is not supported", f.Vm.Message.Title);
        Assert.Equal("Save it as .docx, .xlsx or .pptx first.", f.Vm.Message.Text);
        Assert.Empty(f.Vm.Documents);
    }

    [Fact]
    public void OfficeFilesAreToldApartByTheirExtension()
    {
        Assert.Equal(OfficeApp.Word, FileKinds.OfficeAppOf(@"C:\Letter.DOCX"));
        Assert.Equal(OfficeApp.Excel, FileKinds.OfficeAppOf(@"C:\sales.xlsx"));
        Assert.Equal(OfficeApp.PowerPoint, FileKinds.OfficeAppOf(@"C:\deck.PPTX"));
        Assert.Null(FileKinds.OfficeAppOf(@"C:\old.xls"));
        Assert.True(FileKinds.IsOldOffice(@"C:\old.xls"));
        Assert.False(FileKinds.IsOldOffice(@"C:\new.xlsx"));
        Assert.Equal("Office files|*.docx;*.xlsx;*.pptx", FileKinds.OfficeFilter("Office files"));
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

        panel.UseOfficeFile(dir.File("deck.pptx", Pptx("x")));

        Assert.Equal("deck.pptx", panel.OfficeState.Text);
        Assert.Equal("deck.pdf", panel.Request()!.Title);
        return Task.CompletedTask;
    });
}
