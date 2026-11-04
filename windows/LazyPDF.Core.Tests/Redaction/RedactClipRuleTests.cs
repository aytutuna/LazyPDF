using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class RedactClipRuleTests
{
    private const string Gradient = "/Shading <</Sh1 << /ShadingType 2 /ColorSpace /DeviceGray /Coords [0 0 600 0] /Function << /FunctionType 2 /Domain [0 1] /C0 [0] /C1 [1] /N 1 >> >> >>";
    private static readonly PdfRect Hole = new(200, 200, 300, 300);

    private static (RedactionResult Result, PdfDocument Output) Run(string content, string resources = "", PdfRect? mark = null)
    {
        using var document = RedactionKit.Page(content, resources);
        var result = new PdfRedactor(document).Apply([RedactionMark.FromRect(0, mark ?? Hole)]);
        return (result, RedactionKit.Open(result));
    }

    [Fact]
    public void EvenOddClipKeepsItsRuleAndItsHole()
    {
        var (_, output) = Run("q 100 100 400 400 re 200 200 200 200 re W* n 0 g 0 0 600 800 re f Q", "", new PdfRect(120, 120, 150, 150));
        using (output)
        {
            string content = RedactionKit.Latin(output);
            Assert.Contains("W* n", content);
            Assert.DoesNotContain("W n", content);
        }
    }

    [Fact]
    public void NonzeroClipPaintedEvenOddKeepsTheNonzeroRule()
    {
        var (_, output) = Run("q 100 100 m 400 100 l 257.5 233.5 l h W f* Q");
        using (output)
        {
            string content = RedactionKit.Latin(output);
            Assert.DoesNotContain("W*", content);
        }
    }

    [Fact]
    public void AxialShadingUnderAMarkReachesTheDescriptionOfItsSequence()
    {
        var (_, output) = Run("/Figure <</MCID 0 /Alt (ZQXMCALT)>> BDC /Sh1 sh EMC", Gradient);
        using (output)
        {
            Assert.DoesNotContain("ZQXMCALT", RedactionKit.Latin(output));
        }
    }

    [Fact]
    public void RectangleClipsInsideAMarkAreNotKept()
    {
        var (_, output) = Run("q 210 210 2 20 re W n /Sh1 sh Q q 214 210 1 20 re W n /Sh1 sh Q", Gradient);
        using (output)
        {
            string content = RedactionKit.Latin(output);
            Assert.DoesNotContain("210 210 2 20 re", content);
            Assert.DoesNotContain("214 210 1 20 re", content);
        }
    }

    [Fact]
    public void RectangleClipAroundTheWholeMarkIsLeftAlone()
    {
        var (_, output) = Run("q 0 0 600 800 re W n /Sh1 sh Q", Gradient);
        using (output)
        {
            Assert.Contains("0 0 600 800 re", RedactionKit.Latin(output));
        }
    }
}
