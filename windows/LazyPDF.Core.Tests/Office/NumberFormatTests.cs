using System.Globalization;
using System.Text;
using LazyPDF.Core.Office;
using Xunit;

namespace LazyPDF.Core.Tests;

// Reads Tests/Fixtures/golden/office-xlsx/numfmt.txt; mirrored by Tests/LazyPDFKitTests/Office/NumberFormatTests.swift.
public class NumberFormatTests
{
    [Fact]
    public void NumberFormatTable()
    {
        var failures = new StringBuilder();
        bool date1904 = false;
        int checks = 0;
        foreach (string line in Golden.Input("office-xlsx", "numfmt.txt").Split('\n'))
        {
            if (line.Length == 0 || line[0] == '#') continue;
            if (line[0] == '!')
            {
                date1904 = line == "!1904";
                continue;
            }
            checks++;
            string[] cells = line.Split('\t');
            var format = NumberFormat.Parse(cells[1]);
            var result = cells[0].StartsWith('\'')
                ? format.FormatText(cells[0][1..])
                : format.Format(double.Parse(cells[0], CultureInfo.InvariantCulture), date1904);
            string actual = result.Text + (result.Color is { } c ? "\t" + c.ToString("x6", CultureInfo.InvariantCulture) : "");
            string expected = cells[2] + (cells.Length > 3 ? "\t" + cells[3] : "");
            if (actual != expected) failures.Append($"{cells[0]} | {cells[1]} | expected [{expected}] got [{actual}]\n");
        }
        Assert.Equal("", failures.ToString());
        Assert.True(checks > 120);
    }

    [Fact]
    public void BuiltInFormatsCoverTheKnownIds()
    {
        for (int id = 0; id <= 49; id++)
        {
            string? code = NumberFormat.BuiltInCode(id);
            if (id is >= 23 and <= 36) Assert.Null(code);
            else Assert.NotNull(code);
        }
        Assert.Null(NumberFormat.BuiltInCode(50));
        Assert.Equal("1/2/2020", NumberFormat.Parse(NumberFormat.BuiltInCode(14)!).Format(43832, false).Text);
        Assert.Equal("1,234.50", NumberFormat.Parse(NumberFormat.BuiltInCode(4)!).Format(1234.5, false).Text);
    }

    [Fact]
    public void OddCodesDoNotThrow()
    {
        foreach (string code in new[] { "", ";;;;;", "[", "\"", "\\", "_", "*", "[>", "0.0.0", "E+", "0E+", "?/", "/?", "[$", "[Red", "0;0;0;0;0", "#,#,#", ",", "0,", "[h", "yyyy.000000", "General General" })
        {
            var format = NumberFormat.Parse(code);
            foreach (double v in new[] { 0, 1, -1, 0.5, 1e300, -1e-300, 45000.5 }) format.Format(v, false);
            format.FormatText("text");
        }
    }
}
