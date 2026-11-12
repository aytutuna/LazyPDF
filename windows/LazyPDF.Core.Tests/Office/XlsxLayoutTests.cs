using System.Globalization;
using System.Text;
using LazyPDF.Core;
using LazyPDF.Core.Office;
using Xunit;

using PigDocument = UglyToad.PdfPig.PdfDocument;

namespace LazyPDF.Core.Tests;

public class XlsxLayoutTests
{
    private static readonly DateTime Now = new(2026, 3, 15, 14, 5, 0);

    private static string Num(double value) => (Math.Round(value * 100, MidpointRounding.AwayFromZero) / 100 + 0.0).ToString("0.00", CultureInfo.InvariantCulture);

    private static LayoutResult Layout(byte[] package, XlsxLimits? limits = null)
    {
        var fonts = OfficeLayoutSpec.Fonts();
        return XlsxLayout.Run(XlsxReader.Read(package, limits), new LayoutFonts(fonts), Now, "Book1.xlsx");
    }

    private static string Dump(LayoutResult layout)
    {
        var output = new StringBuilder();
        for (int i = 0; i < layout.Pages.Count; i++)
        {
            var page = layout.Pages[i];
            output.Append($"page {i + 1} {Num(page.Width)} {Num(page.Height)}\n");
            foreach (var box in page.Boxes)
            {
                switch (box)
                {
                    case PlacedText t:
                        output.Append($"text {Num(t.X)} {Num(t.Baseline)} {t.Family}/{t.Style} {Num(t.Size)} {t.Color:x6} +{Num(t.SpaceExtra)} \"{OfficeLayoutSpec.Escape(t.Text)}\"\n");
                        break;
                    case PlacedRect r:
                        output.Append($"rect {Num(r.X)} {Num(r.Y)} {Num(r.Width)} {Num(r.Height)} {r.Color:x6}\n");
                        break;
                }
            }
        }
        foreach (var s in layout.Skipped) output.Append($"skipped {s.Kind} {s.Count}\n");
        return output.ToString();
    }

    [Fact]
    public void LayoutGoldenFile()
    {
        var output = new StringBuilder();
        foreach (var (name, package) in XlsxSpec.Read(Golden.Input("office-xlsx", "xlsx-layout-input.txt")))
        {
            output.Append("> ").Append(name).Append('\n').Append(Dump(Layout(package)));
        }
        Golden.Check("office-xlsx", "xlsx-layout-output.txt", output.ToString());
    }

    private const string OneSheet = "<sheets><sheet name=\"S\" sheetId=\"1\" r:id=\"rId1\"/></sheets>";

    private static byte[] Book(string sheet, string? workbook = null) =>
        XlsxSpec.Package(new Dictionary<string, StringBuilder> { ["workbook"] = new(workbook ?? OneSheet), ["sheet1"] = new(sheet) });

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

    [Fact]
    public void ABookWithNothingInItHasNothingToPrint()
    {
        Assert.Equal(PdfReadProblem.Unsupported, Problem(() => Layout(Book("<sheetData><row r=\"1\"/></sheetData>"))));
    }

    [Fact]
    public void MarginsThatLeaveNoRoomAreRefused()
    {
        string sheet = "<sheetData><row r=\"1\"><c r=\"A1\"><v>1</v></c></row></sheetData><pageMargins left=\"5\" right=\"5\" top=\"1\" bottom=\"1\" header=\"0\" footer=\"0\"/>";
        Assert.Equal(PdfReadProblem.Unsupported, Problem(() => Layout(Book(sheet))));
    }

    [Fact]
    public void ABigPrintAreaStopsAtThePageLimit()
    {
        string sheet = "<sheetData><row r=\"1\"><c r=\"A1\"><v>1</v></c></row></sheetData>";
        string book = "<sheets><sheet name=\"S\" sheetId=\"1\" r:id=\"rId1\"/></sheets><definedNames><definedName name=\"_xlnm.Print_Area\" localSheetId=\"0\">S!$A$1:$XFD$1048576</definedName></definedNames>";
        Assert.Equal(PdfReadProblem.Unsupported, Problem(() => Layout(Book(sheet, book))));
    }

    [Fact]
    public void ACellFarDownTheSheetPrintsOnItsOwnPageWithoutTheBlankOnes()
    {
        var layout = Layout(Book("<sheetData><row r=\"900000\"><c r=\"A900000\"><v>7</v></c></row></sheetData>"));
        Assert.Single(layout.Pages);
        Assert.Contains(layout.Pages[0].Boxes, b => b is PlacedText { Text: "7" });
    }

    [Fact]
    public void FitToPageNeverUsesMorePagesThanAsked()
    {
        var rows = string.Concat(Enumerable.Range(1, 300).Select(r => $"<row r=\"{r}\">" + string.Concat(Enumerable.Range(0, 30).Select(c => $"<c r=\"{(char)('A' + c % 26)}{(c >= 26 ? "A" : "")}{r}\"><v>{r}</v></c>")) + "</row>"));
        string sheet = $"<sheetPr><pageSetUpPr fitToPage=\"1\"/></sheetPr><sheetData>{rows}</sheetData><pageSetup fitToWidth=\"2\" fitToHeight=\"3\"/>";
        Assert.True(Layout(Book(sheet)).Pages.Count <= 6);
    }

    [Fact]
    public void TheConverterWritesAPdfWithTheCellText()
    {
        var parts = new Dictionary<string, StringBuilder>
        {
            ["workbook"] = new(OneSheet),
            ["strings"] = new("<si><t>Hello sheet</t></si>"),
            ["sheet1"] = new("<sheetData><row r=\"1\"><c r=\"A1\" t=\"s\"><v>0</v></c></row></sheetData>"),
        };
        var pdf = OfficeConverter.FromExcel(XlsxSpec.Package(parts), OfficeLayoutSpec.Fonts(), "Book1.xlsx");
        Assert.Equal(1, pdf.Pages);
        using var read = PigDocument.Open(pdf.Bytes);
        Assert.Contains("Hello sheet", read.GetPage(1).Text);
    }
}
