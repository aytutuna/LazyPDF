using System.Text;
using LazyPDF.Core;
using LazyPDF.Core.Office;
using Xunit;

namespace LazyPDF.Core.Tests;

public class XlsxReaderTests
{
    [Fact]
    public void XlsxGoldenFile()
    {
        var output = new StringBuilder();
        foreach (var (name, package) in XlsxSpec.Read(Golden.Input("office-xlsx", "xlsx-input.txt")))
        {
            output.Append("> ").Append(name).Append('\n').Append(XlsxSpec.Dump(XlsxReader.Read(package)));
        }
        Golden.Check("office-xlsx", "xlsx-output.txt", output.ToString());
    }

    private const string OneSheet = "<sheets><sheet name=\"S\" sheetId=\"1\" r:id=\"rId1\"/></sheets>";

    private static byte[] Book(string sheetData, string? strings = null, string? styles = null, string? workbook = null, string? extra = null)
    {
        var parts = new Dictionary<string, StringBuilder>
        {
            ["workbook"] = new(workbook ?? OneSheet),
            ["sheet1"] = new(sheetData),
        };
        if (strings is not null) parts["strings"] = new(strings);
        if (styles is not null) parts["styles"] = new(styles);
        if (extra is not null) parts["sheet2"] = new(extra);
        return XlsxSpec.Package(parts);
    }

    private static PdfReadProblem? Problem(Action work)
    {
        try
        {
            work();
            return null;
        }
        catch (PdfReadException e)
        {
            return e.Problem;
        }
    }

    private static string Cells(int count) =>
        "<sheetData><row r=\"1\">" + string.Concat(Enumerable.Range(1, count).Select(i => $"<c r=\"{ColumnName(i)}1\"><v>1</v></c>")) + "</row></sheetData>";

    private static string ColumnName(int column)
    {
        var letters = new StringBuilder();
        for (int c = column; c > 0; c = (c - 1) / 26) letters.Insert(0, (char)('A' + (c - 1) % 26));
        return letters.ToString();
    }

    [Fact]
    public void MoreCellsThanTheLimitAreRefused()
    {
        var limits = new XlsxLimits(MaxCells: 3);
        XlsxReader.Read(Book(Cells(3)), limits);
        Assert.Equal(PdfReadProblem.Unsupported, Problem(() => XlsxReader.Read(Book(Cells(4)), limits)));
    }

    [Fact]
    public void BlankCellsWithNothingToDrawAreNotCounted()
    {
        var limits = new XlsxLimits(MaxCells: 1);
        var sheet = "<sheetData><row r=\"1\"><c r=\"A1\"/><c r=\"B1\"/><c r=\"C1\"><v>1</v></c><c r=\"D1\"/></row></sheetData>";
        Assert.Single(XlsxReader.Read(Book(sheet), limits).Sheets[0].Rows[0].Cells);
    }

    [Fact]
    public void MoreSheetsThanTheLimitAreRefused()
    {
        string two = "<sheets><sheet name=\"A\" sheetId=\"1\" r:id=\"rId1\"/><sheet name=\"B\" sheetId=\"2\" r:id=\"rId2\"/></sheets>";
        var package = Book("<sheetData/>", workbook: two, extra: "<sheetData/>");
        Assert.Equal(2, XlsxReader.Read(package).Sheets.Count);
        Assert.Equal(PdfReadProblem.Unsupported, Problem(() => XlsxReader.Read(package, new XlsxLimits(MaxSheets: 1))));
    }

    [Fact]
    public void MoreMergedRangesThanTheLimitAreRefused()
    {
        string sheet = "<sheetData/><mergeCells><mergeCell ref=\"A1:B1\"/><mergeCell ref=\"A2:B2\"/></mergeCells>";
        Assert.Equal(PdfReadProblem.Unsupported, Problem(() => XlsxReader.Read(Book(sheet), new XlsxLimits(MaxMergedRanges: 1))));
        Assert.Equal(2, XlsxReader.Read(Book(sheet), new XlsxLimits(MaxMergedRanges: 2)).Sheets[0].Merges.Count);
    }

    [Fact]
    public void MoreSharedStringsThanTheLimitAreRefused()
    {
        var package = Book("<sheetData/>", strings: "<si><t>a</t></si><si><t>b</t></si>");
        Assert.Equal(PdfReadProblem.Unsupported, Problem(() => XlsxReader.Read(package, new XlsxLimits(MaxSharedStrings: 1))));
    }

    [Fact]
    public void MoreStylesAndFormatsThanTheLimitAreRefused()
    {
        var styles = Book("<sheetData/>", styles: "<cellXfs><xf/><xf/></cellXfs>");
        Assert.Equal(PdfReadProblem.Unsupported, Problem(() => XlsxReader.Read(styles, new XlsxLimits(MaxStyles: 1))));
        var formats = Book("<sheetData/>", styles: "<numFmts><numFmt numFmtId=\"164\" formatCode=\"0\"/><numFmt numFmtId=\"165\" formatCode=\"0\"/></numFmts>");
        Assert.Equal(PdfReadProblem.Unsupported, Problem(() => XlsxReader.Read(formats, new XlsxLimits(MaxNumberFormats: 1))));
    }

    [Fact]
    public void LongTextIsCutAndNotedWithoutSplittingAPair()
    {
        string sheet = "<sheetData><row r=\"1\"><c r=\"A1\" t=\"inlineStr\"><is><t>abcdefgh</t></is></c><c r=\"B1\" t=\"inlineStr\"><is><t>ab\U0001F600cd</t></is></c><c r=\"C1\" t=\"str\"><v>abcdefgh</v></c></row></sheetData>";
        var workbook = XlsxReader.Read(Book(sheet), new XlsxLimits(MaxTextLength: 3));
        var cells = workbook.Sheets[0].Rows[0].Cells;
        Assert.Equal(["abc", "ab", "abc"], cells.Select(c => c.Text));
        Assert.Equal([new SkippedFeature("long-text", 3)], workbook.Skipped);
    }

    [Fact]
    public void TooMuchTextInAllIsRefused()
    {
        string sheet = "<sheetData><row r=\"1\"><c r=\"A1\" t=\"inlineStr\"><is><t>abcd</t></is></c><c r=\"B1\" t=\"inlineStr\"><is><t>abcd</t></is></c></row></sheetData>";
        Assert.Equal(PdfReadProblem.Unsupported, Problem(() => XlsxReader.Read(Book(sheet), new XlsxLimits(MaxTotalText: 7))));
        XlsxReader.Read(Book(sheet), new XlsxLimits(MaxTotalText: 8));
    }

    [Fact]
    public void ARowOutsideTheSheetIsDamage()
    {
        Assert.Equal(PdfReadProblem.Damaged, Problem(() => XlsxReader.Read(Book("<sheetData><row r=\"1048577\"/></sheetData>"))));
        Assert.Equal(PdfReadProblem.Damaged, Problem(() => XlsxReader.Read(Book("<sheetData><row r=\"0\"/></sheetData>"))));
        XlsxReader.Read(Book("<sheetData><row r=\"1048576\"><c r=\"XFD1048576\"><v>1</v></c></row></sheetData>"));
    }

    [Fact]
    public void ANumberFormatLongerThanTheLimitFallsBackToGeneral()
    {
        string code = new('0', 300);
        var package = Book("<sheetData><row r=\"1\"><c r=\"A1\" s=\"1\"><v>5</v></c></row></sheetData>",
            styles: $"<numFmts><numFmt numFmtId=\"164\" formatCode=\"{code}\"/></numFmts><cellXfs><xf/><xf numFmtId=\"164\"/></cellXfs>");
        Assert.Equal("5", XlsxReader.Read(package).Sheets[0].Rows[0].Cells[0].Text);
    }

    [Fact]
    public void FilesThatAreNotXlsxAreTurnedAway()
    {
        var ole = new byte[] { 0xD0, 0xCF, 0x11, 0xE0, 0, 0, 0, 0 };
        Assert.Equal(PdfReadProblem.Unsupported, Problem(() => XlsxReader.Read(ole)));
        var word = DocxSpec.Package(new Dictionary<string, StringBuilder> { ["document"] = new("<w:p/>") });
        Assert.Equal(PdfReadProblem.Unsupported, Problem(() => XlsxReader.Read(word)));
        Assert.NotNull(Record.Exception(() => XlsxReader.Read([1, 2, 3, 4, 5])));
    }

    [Fact]
    public void AWorksheetWithTheWrongRootIsDamage()
    {
        var package = XlsxSpec.Package(new Dictionary<string, StringBuilder>
        {
            ["workbook"] = new(OneSheet),
            ["part xl/worksheets/sheet1.xml"] = new("<other xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"/>"),
            ["relationships"] = new("<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet1.xml\"/>"),
        });
        Assert.Equal(PdfReadProblem.Damaged, Problem(() => XlsxReader.Read(package)));
    }

    [Fact]
    public void ACancelledReadStops()
    {
        using var cancelled = new CancellationTokenSource();
        cancelled.Cancel();
        Assert.Throws<OperationCanceledException>(() => XlsxReader.Read(Book("<sheetData><row r=\"1\"/></sheetData>"), null, cancelled.Token));
    }

    [Fact]
    public void ColumnLookupsFollowTheRuns()
    {
        var sheet = XlsxReader.Read(Book("<cols><col min=\"2\" max=\"3\" width=\"20\" hidden=\"1\"/></cols><sheetData/>")).Sheets[0];
        Assert.Equal(sheet.DefaultColumnWidth, sheet.WidthOf(1));
        Assert.NotEqual(sheet.DefaultColumnWidth, sheet.WidthOf(3));
        Assert.True(sheet.IsColumnHidden(2));
        Assert.False(sheet.IsColumnHidden(4));
    }
}
