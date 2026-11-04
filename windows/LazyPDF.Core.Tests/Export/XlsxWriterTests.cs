using System.Xml.Linq;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class XlsxWriterTests
{
    private static readonly XNamespace S = "http://schemas.openxmlformats.org/spreadsheetml/2006/main";
    private static readonly XNamespace Rel = "http://schemas.openxmlformats.org/package/2006/relationships";

    private static XDocument Part(byte[] package, string name) => XDocument.Parse(ExportKit.Unzip(package, name));

    [Fact]
    public void EachTableIsASheetAndNumbersAreNumbers()
    {
        var package = XlsxWriter.Make(ExportLayout.Analyze(ExportKit.Report()));
        var sheets = Part(package, "xl/workbook.xml").Descendants(S + "sheet").Select(s => (string)s.Attribute("name")!).ToList();
        Assert.Equal(["Table 1 (p1)", "Table 1 (p2)", "Table 1 (p3)"], sheets);

        var cells = Part(package, "xl/worksheets/sheet1.xml").Descendants(S + "c").ToDictionary(c => (string)c.Attribute("r")!);
        Assert.Equal("Item", cells["A1"].Descendants(S + "t").Single().Value);
        Assert.Equal("inlineStr", (string)cells["A1"].Attribute("t")!);
        Assert.Equal("1250.5", cells["B2"].Element(S + "v")!.Value);
        Assert.Null(cells["B2"].Attribute("t"));
    }

    [Fact]
    public void ThePackageIsConsistent()
    {
        var package = XlsxWriter.Make(ExportLayout.Analyze(ExportKit.Report()));
        var entries = ExportKit.Entries(package);
        foreach (var rel in Part(package, "xl/_rels/workbook.xml.rels").Descendants(Rel + "Relationship"))
            Assert.Contains("xl/" + (string)rel.Attribute("Target")!, entries);
        var types = Part(package, "[Content_Types].xml").ToString();
        for (int i = 1; i <= 3; i++) Assert.Contains($"/xl/worksheets/sheet{i}.xml", types);
        Assert.All(entries.Where(e => e.EndsWith(".xml") || e.EndsWith(".rels")), e => Part(package, e));
    }

    [Fact]
    public void WithoutTablesEachPageIsASheetOfRowsAndColumns()
    {
        var content = "BT /F1 11 Tf 72 700 Td (Name) Tj ET BT /F1 11 Tf 300 700 Td (Total) Tj ET\n"
            + "BT /F1 11 Tf 72 684 Td (Rent) Tj ET BT /F1 11 Tf 300 684 Td (950) Tj ET";
        var package = XlsxWriter.Make(ExportLayout.Analyze(ExportKit.Open(content)));
        var sheet = Part(package, "xl/worksheets/sheet1.xml");
        Assert.Equal("Page 1", (string)Part(package, "xl/workbook.xml").Descendants(S + "sheet").Single().Attribute("name")!);
        var cells = sheet.Descendants(S + "c").ToDictionary(c => (string)c.Attribute("r")!);
        Assert.Equal(["A1", "A2", "B1", "B2"], cells.Keys.Order());
        Assert.Equal("950", cells["B2"].Element(S + "v")!.Value);
        Assert.Equal("Rent", cells["A2"].Value);
    }

    [Fact]
    public void AnEmptyDocumentHasOneEmptySheet()
    {
        var package = XlsxWriter.Make(new ExportDocument(null, [], 11));
        Assert.Equal("Sheet1", (string)Part(package, "xl/workbook.xml").Descendants(S + "sheet").Single().Attribute("name")!);
        Assert.Empty(Part(package, "xl/worksheets/sheet1.xml").Descendants(S + "c"));
    }

    [Fact]
    public void TurkishTextAndLineBreaksInCellsSurvive()
    {
        var table = new ExportTable(new DisplayRect(0, 0, 10, 10), [["Şehir", "İlçe"], ["Ağrı", "Doğubayazıt\nMerkez"]], null, false);
        var document = new ExportDocument(null, [new ExportPage(0, 612, 792, [table], [], [])], 11);
        var cells = Part(XlsxWriter.Make(document), "xl/worksheets/sheet1.xml").Descendants(S + "c").ToDictionary(c => (string)c.Attribute("r")!, c => c.Value);
        Assert.Equal(["Şehir", "İlçe", "Ağrı", "Doğubayazıt\nMerkez"], cells.Values);
    }

    [Fact]
    public void TextThatLooksLikeACodeStaysText()
    {
        var table = new ExportTable(new DisplayRect(0, 0, 10, 10), [["007", "=SUM(A1)"], ["12", "1e5"]], null, false);
        var document = new ExportDocument(null, [new ExportPage(0, 612, 792, [table], [], [])], 11);
        var cells = Part(XlsxWriter.Make(document), "xl/worksheets/sheet1.xml").Descendants(S + "c").ToDictionary(c => (string)c.Attribute("r")!);
        Assert.Equal("inlineStr", (string)cells["A1"].Attribute("t")!);
        Assert.Equal("inlineStr", (string)cells["B1"].Attribute("t")!);
        Assert.Null(cells["A2"].Attribute("t"));
        Assert.Equal("inlineStr", (string)cells["B2"].Attribute("t")!);
    }

    [Theory]
    [InlineData("42", 42)]
    [InlineData("-7", -7)]
    [InlineData("0", 0)]
    [InlineData("0.5", 0.5)]
    [InlineData("3.14", 3.14)]
    [InlineData("12,5", 12.5)]
    [InlineData("1,23", 1.23)]
    [InlineData("1,234", 1234)]
    [InlineData("1,234.56", 1234.56)]
    [InlineData("1.234,56", 1234.56)]
    [InlineData("1.234.567", 1234567)]
    [InlineData("1,234,567", 1234567)]
    [InlineData("-1.234,5", -1234.5)]
    [InlineData(" 8 ", 8)]
    public void NumbersAreRecognised(string text, double expected)
    {
        Assert.True(XlsxWriter.TryNumber(text, out double value));
        Assert.Equal(expected, value, 9);
    }

    [Theory]
    [InlineData("")]
    [InlineData("abc")]
    [InlineData("007")]
    [InlineData("1.2.3")]
    [InlineData("12,34,56")]
    [InlineData("1e5")]
    [InlineData("12%")]
    [InlineData("$5")]
    [InlineData("-")]
    [InlineData("1,")]
    [InlineData("12345678901234567")]
    [InlineData("1.234,56,7")]
    public void OtherTextIsNotANumber(string text)
    {
        Assert.False(XlsxWriter.TryNumber(text, out _));
    }
}
