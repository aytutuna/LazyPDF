using System.Text;
using LazyPDF.Core;
using LazyPDF.Core.Office;
using Xunit;

using PigDocument = UglyToad.PdfPig.PdfDocument;

namespace LazyPDF.Core.Tests;

public class DocxReaderTests
{
    [Fact]
    public void DocxGoldenFile()
    {
        var output = new StringBuilder();
        foreach (var (name, package) in DocxSpec.Read(Golden.Input("office-docx", "docx-input.txt")))
        {
            output.Append("> ").Append(name).Append('\n').Append(DocxSpec.Dump(DocxReader.Read(package)));
        }
        Golden.Check("office-docx", "docx-output.txt", output.ToString());
    }

    [Fact]
    public void DocxTablesGoldenFile()
    {
        var output = new StringBuilder();
        foreach (var (name, package) in DocxSpec.Read(Golden.Input("office-docx", "tables-input.txt")))
        {
            output.Append("> ").Append(name).Append('\n').Append(DocxSpec.Dump(DocxReader.Read(package)));
        }
        Golden.Check("office-docx", "tables-output.txt", output.ToString());
    }

    [Fact]
    public void DocxImagesGoldenFile()
    {
        var output = new StringBuilder();
        foreach (var (name, package) in DocxSpec.Read(Golden.Input("office-docx", "images-input.txt")))
        {
            output.Append("> ").Append(name).Append('\n').Append(DocxSpec.Dump(DocxReader.Read(package)));
        }
        Golden.Check("office-docx", "images-output.txt", output.ToString());
    }

    private static byte[] Docx(string body, string? styles = null)
    {
        var parts = new Dictionary<string, StringBuilder> { ["document"] = new(body) };
        if (styles is not null) parts["styles"] = new(styles);
        return DocxSpec.Package(parts);
    }

    private static byte[] Zip(params (string Name, string Text)[] parts) =>
        ExportZip.Make([.. parts.Select(p => new ExportZipEntry(p.Name, Encoding.UTF8.GetBytes(p.Text)))]);

    private const string Types = "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/></Types>";
    private const string Rels = "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"r1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"/word/document.xml\"/></Relationships>";
    private const string W = "xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"";

    [Fact]
    public void ListLabelsStayShortForCraftedNumbering()
    {
        var parts = new Dictionary<string, StringBuilder>
        {
            ["numbering"] = new("<w:abstractNum w:abstractNumId=\"0\"><w:lvl w:ilvl=\"0\"><w:start w:val=\"99999999\"/><w:numFmt w:val=\"lowerLetter\"/><w:lvlText w:val=\"" + string.Concat(Enumerable.Repeat("%1", 500)) + "\"/></w:lvl></w:abstractNum><w:num w:numId=\"1\"><w:abstractNumId w:val=\"0\"/></w:num>"),
            ["document"] = new("<w:p><w:pPr><w:numPr><w:numId w:val=\"1\"/></w:numPr></w:pPr><w:r><w:t>x</w:t></w:r></w:p>"),
        };
        var document = DocxReader.Read(DocxSpec.Package(parts));
        var text = ((LayoutParagraph)document.Sections[0].Blocks[0]).Runs[0].Text;
        Assert.True(text.Length <= 64 + 2 + 1, text.Length.ToString());
        Assert.EndsWith("	x", text);
    }

    [Theory]
    [InlineData(1, "lowerLetter", "a")]
    [InlineData(27, "lowerLetter", "aa")]
    [InlineData(4, "upperRoman", "IV")]
    [InlineData(1994, "lowerRoman", "mcmxciv")]
    [InlineData(4000, "upperRoman", "4000")]
    [InlineData(7, "decimalZero", "07")]
    [InlineData(12, "decimalZero", "12")]
    [InlineData(5, "unknownFormat", "5")]
    public void NumberFormats(int value, string format, string expected) => Assert.Equal(expected, DocxNumbering.Format(value, format));

    [Fact]
    public void ReadsAMinimalPackageWithAnAbsoluteTarget()
    {
        var package = Zip(("[Content_Types].xml", Types), ("_rels/.rels", Rels), ("word/document.xml", $"<w:document {W}><w:body><w:p><w:r><w:t>hi</w:t></w:r></w:p></w:body></w:document>"));
        var document = DocxReader.Read(package);
        var run = Assert.Single(Assert.IsType<LayoutParagraph>(Assert.Single(document.Sections[0].Blocks)).Runs);
        Assert.Equal("hi", run.Text);
        Assert.Equal(10, run.Size);
        Assert.Equal("Times New Roman", run.Family);
    }

    [Fact]
    public void RefusesWhatIsNotAWordDocument()
    {
        Assert.Equal(PdfReadProblem.Damaged, Assert.Throws<PdfReadException>(() => DocxReader.Read(Zip(("a.txt", "x")))).Problem);
        Assert.Equal(PdfReadProblem.Damaged, Assert.Throws<PdfReadException>(() => DocxReader.Read(Zip(("[Content_Types].xml", Types)))).Problem);
        Assert.Equal(PdfReadProblem.Damaged, Assert.Throws<PdfReadException>(() => DocxReader.Read([1, 2, 3, 4, 5])).Problem);

        string sheet = Types.Replace("wordprocessingml.document", "spreadsheetml.sheet");
        var excel = Zip(("[Content_Types].xml", sheet), ("_rels/.rels", Rels), ("word/document.xml", $"<w:document {W}><w:body/></w:document>"));
        Assert.Equal(PdfReadProblem.Unsupported, Assert.Throws<PdfReadException>(() => DocxReader.Read(excel)).Problem);

        var strict = Zip(("[Content_Types].xml", Types), ("_rels/.rels", Rels), ("word/document.xml", "<w:document xmlns:w=\"http://purl.oclc.org/ooxml/wordprocessingml/main\"><w:body/></w:document>"));
        Assert.Equal(PdfReadProblem.Unsupported, Assert.Throws<PdfReadException>(() => DocxReader.Read(strict)).Problem);

        var old = new byte[] { 0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1, 0, 0 };
        Assert.Equal(PdfReadProblem.Unsupported, Assert.Throws<PdfReadException>(() => DocxReader.Read(old)).Problem);
    }

    [Fact]
    public void RefusesNestingPastTheXmlLimit()
    {
        string body = string.Concat(Enumerable.Repeat("<w:sdt><w:sdtContent>", 100)) + "<w:p/>" + string.Concat(Enumerable.Repeat("</w:sdtContent></w:sdt>", 100));
        Assert.Equal(PdfReadProblem.Unsupported, Assert.Throws<PdfReadException>(() => DocxReader.Read(Docx(body))).Problem);
    }

    [Fact]
    public void ControlsNestedWithinTheLimitAreReadAndLoopsInStylesEnd()
    {
        string body = string.Concat(Enumerable.Repeat("<w:sdt><w:sdtContent>", 40)) + "<w:p><w:r><w:t>deep</w:t></w:r></w:p>" + string.Concat(Enumerable.Repeat("</w:sdtContent></w:sdt>", 40));
        var document = DocxReader.Read(Docx(body));
        Assert.Equal("deep", Assert.IsType<LayoutParagraph>(Assert.Single(document.Sections[0].Blocks)).Runs[0].Text);
    }

    [Fact]
    public void ManyParagraphsAreReadAndCancellationStopsTheRead()
    {
        string body = string.Concat(Enumerable.Repeat("<w:p><w:r><w:t>x</w:t></w:r></w:p>", 5000));
        Assert.Equal(5000, DocxReader.Read(Docx(body)).Sections[0].Blocks.Count);
        using var cancel = new CancellationTokenSource();
        cancel.Cancel();
        Assert.ThrowsAny<OperationCanceledException>(() => DocxReader.Read(Docx(body), cancel.Token));
    }

    [Fact]
    public void NumbersAndColorsAreReadStrictly()
    {
        Assert.Equal(12, DocxReader.Number(" 12 "));
        Assert.Equal(-15, DocxReader.Number("-1.5e1"));
        Assert.Equal(0.5, DocxReader.Number(".5"));
        Assert.Equal(5, DocxReader.Number("5."));
        Assert.Equal(7, DocxReader.Number("+7"));
        foreach (string bad in new[] { "", "x", "-", ".", "1e", "1e+", "1 2", "0x10", "nan", "inf", "1e999", "1,5" }) Assert.Null(DocxReader.Number(bad));
        Assert.Null(DocxReader.Number(null));
        Assert.Equal(0x2F5496, DocxReader.Hex("2F5496"));
        foreach (string bad in new[] { "2F549", "2F54960", "+F5496", "GG0000", " 2F549" }) Assert.Null(DocxReader.Hex(bad));
    }

    [Fact]
    public void ConvertsToAPdfWithTheTextAndThePageBreaks()
    {
        string body =
            "<w:p><w:r><w:t>First page</w:t></w:r></w:p>" +
            "<w:p><w:r><w:br w:type=\"page\"/><w:t>Second page</w:t></w:r></w:p>" +
            "<w:p><w:pPr><w:sectPr><w:pgSz w:w=\"12240\" w:h=\"15840\"/></w:sectPr></w:pPr></w:p>" +
            "<w:p><w:r><w:t>Third page</w:t></w:r></w:p>" +
            "<w:tbl><w:tr><w:tc><w:p><w:r><w:t>cell</w:t></w:r></w:p></w:tc></w:tr></w:tbl>";
        var pdf = OfficeConverter.FromWord(Docx(body), OfficeLayoutSpec.Fonts());
        Assert.Equal(3, pdf.Pages);
        Assert.DoesNotContain(pdf.Skipped, s => s.Kind == "table");
        using var read = PigDocument.Open(pdf.Bytes);
        Assert.Equal(3, read.NumberOfPages);
        Assert.Equal("First page", read.GetPage(1).Text);
        Assert.Equal("Second page", read.GetPage(2).Text);
        Assert.Contains("Third page", read.GetPage(3).Text);
        Assert.Contains("cell", read.GetPage(3).Text);
    }

    [Fact]
    public void PageNumberFieldsInTheFooterShowThePageAndTheCount()
    {
        string footer = "<w:p><w:r><w:fldChar w:fldCharType=\"begin\"/></w:r><w:r><w:instrText>PAGE</w:instrText></w:r><w:r><w:fldChar w:fldCharType=\"separate\"/></w:r><w:r><w:t>1</w:t></w:r><w:r><w:fldChar w:fldCharType=\"end\"/></w:r><w:r><w:t>/</w:t></w:r><w:fldSimple w:instr=\"NUMPAGES\"><w:r><w:t>1</w:t></w:r></w:fldSimple></w:p>";
        var parts = new Dictionary<string, StringBuilder>
        {
            ["document"] = new("<w:p><w:r><w:t>a</w:t></w:r></w:p><w:p><w:r><w:br w:type=\"page\"/><w:t>b</w:t></w:r></w:p><w:sectPr><w:footerReference w:type=\"default\" r:id=\"rIdF\"/></w:sectPr>"),
            ["footer"] = new(footer),
        };
        var pdf = OfficeConverter.FromWord(DocxSpec.Package(parts), OfficeLayoutSpec.Fonts());
        using var read = PigDocument.Open(pdf.Bytes);
        Assert.Equal(2, read.NumberOfPages);
        Assert.Contains("1/2", read.GetPage(1).Text.Replace(" ", "").Replace("\n", ""));
        Assert.Contains("2/2", read.GetPage(2).Text.Replace(" ", "").Replace("\n", ""));
    }
}
