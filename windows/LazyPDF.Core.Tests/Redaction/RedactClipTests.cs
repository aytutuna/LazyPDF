using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class RedactClipTests
{
    private const string Gradient = "/Shading <</Sh1 << /ShadingType 2 /ColorSpace /DeviceGray /Coords [0 0 600 0] /Function << /FunctionType 2 /Domain [0 1] /C0 [0] /C1 [1] /N 1 >> >> >>";
    private static readonly PdfRect Hole = new(200, 200, 300, 300);

    private static (RedactionResult Result, PdfDocument Output) Run(string content, string resources = "")
    {
        using var document = RedactionKit.Page(content, resources);
        var result = new PdfRedactor(document).Apply([RedactionMark.FromRect(0, Hole)]);
        return (result, RedactionKit.Open(result));
    }

    private static IEnumerable<(double X, double Y)> Points(PathInfo path) =>
        path.Segments.Where(s => s.Kind is PathSegmentKind.Move or PathSegmentKind.Line).Select(s => (s.X1, s.Y1));

    [Fact]
    public void ClipOutlineInsideTheMarkIsNotKept()
    {
        var (_, output) = Run("q 100 100 m 400 100 l 257.5 233.5 l h W n /Sh1 sh Q", Gradient);
        using (output)
        {
            Assert.DoesNotContain("257.5 233.5", RedactionKit.Latin(output));
            var clips = ContentTestPdf.Run(output).Paths.Where(p => p.Path.Clips).ToList();
            Assert.NotEmpty(clips);
            Assert.All(clips.SelectMany(c => Points(c.Path)), p => Assert.False(p.X > 200.01 && p.X < 299.99 && p.Y > 200.01 && p.Y < 299.99));
            Assert.Contains(clips, c => c.Path.Bounds.Left <= 100.01);
        }
    }

    [Fact]
    public void PathThatClipsAndFillsKeepsNoCoordinatesInsideTheMark()
    {
        var (result, output) = Run("q 1 0 0 rg 100 100 m 400 100 l 257.5 233.5 l h W f 0 g 10 10 20 20 re f Q");
        using (output)
        {
            string content = RedactionKit.Latin(output);
            Assert.DoesNotContain("257.5 233.5", content);
            Assert.Contains("W", content);
            Assert.Equal(1, result.Report.Paths);
        }
    }

    [Fact]
    public void ClipWhollyInsideTheMarkClipsToNothing()
    {
        var (_, output) = Run("q 230 210 m 270 210 l 257.5 233.5 l h W n 0 g 10 10 20 20 re f Q");
        using (output)
        {
            Assert.DoesNotContain("257.5 233.5", RedactionKit.Latin(output));
            var painted = ContentTestPdf.Run(output).Paths.Single(p => p.Path.Bounds.Left == 10);
            Assert.Equal(0, painted.State.Clip.Width, 0.001);
            Assert.Equal(0, painted.State.Clip.Height, 0.001);
        }
    }

    [Fact]
    public void ClipOutsideTheMarkIsLeftAlone()
    {
        var (_, output) = Run("q 100 400 m 400 400 l 257.5 533.5 l h W n /Sh1 sh Q", Gradient);
        using (output)
        {
            Assert.Contains("257.5 533.5", RedactionKit.Latin(output));
        }
    }
}
