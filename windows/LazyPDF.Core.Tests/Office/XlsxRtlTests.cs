using System.Text;
using LazyPDF.Core.Office;
using Xunit;

namespace LazyPDF.Core.Tests;

public class XlsxRtlTests
{
    [Fact]
    public void RightToLeftSheetGoldenFile()
    {
        var output = new StringBuilder();
        foreach (var (name, package) in XlsxSpec.Read(Golden.Input("office-xlsx", "rtl-input.txt")))
        {
            var layout = XlsxLayout.Run(XlsxReader.Read(package), new LayoutFonts(OfficeRtlTests.ScriptFonts()), new DateTime(2026, 3, 15, 14, 5, 0), "Book1.xlsx");
            output.Append("> ").Append(name).Append('\n').Append(XlsxLayoutTests.Dump(layout));
        }
        Golden.Check("office-xlsx", "rtl-output.txt", output.ToString());
    }
}
