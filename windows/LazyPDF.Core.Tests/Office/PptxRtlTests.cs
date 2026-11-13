using System.Text;
using LazyPDF.Core.Office;
using Xunit;

namespace LazyPDF.Core.Tests;

public class PptxRtlTests
{
    [Fact]
    public void RightToLeftSlideGoldenFile()
    {
        var output = new StringBuilder();
        foreach (var (name, package) in PptxSpec.Read(Golden.Input("office-pptx", "rtl-input.txt")))
        {
            var layout = PptxLayout.Run(PptxReader.Read(package), new LayoutFonts(OfficeRtlTests.ScriptFonts()));
            output.Append("> ").Append(name).Append('\n').Append(PptxSpec.Dump(layout));
        }
        Golden.Check("office-pptx", "rtl-output.txt", output.ToString());
    }
}
