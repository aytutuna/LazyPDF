using System.Text;
using Xunit;

namespace LazyPDF.Core.Tests;

public class FunctionTests
{
    private static PdfFunction Parse(string dictionary, byte[]? data = null)
    {
        var streams = new FilterFixtures.Streams();
        PdfObject function = data is null ? FilterFixtures.Parse(dictionary) : streams.Add(dictionary, data);
        return PdfFunction.Parse(function, FilterFixtures.Resolve, streams.Decode);
    }

    private static PdfFunction Calculator(string program, string domain = "[0 1]", string range = "[0 1]") =>
        Parse($"<< /FunctionType 4 /Domain {domain} /Range {range} >>", Encoding.ASCII.GetBytes(program));

    private static double[] Eval(PdfFunction f, params double[] input)
    {
        var output = new double[f.Outputs];
        f.Evaluate(input, output);
        return output;
    }

    private static void Near(double expected, double actual, double tolerance = 1e-9) =>
        Assert.True(Math.Abs(expected - actual) <= tolerance, $"expected {expected}, got {actual}");

    [Fact]
    public void ExponentialInterpolatesBetweenTheEnds()
    {
        var f = Parse("<< /FunctionType 2 /Domain [0 1] /C0 [0 0] /C1 [1 0.5] /N 2 >>");
        Assert.Equal(1, f.Inputs);
        Assert.Equal(2, f.Outputs);
        var y = Eval(f, 0.5);
        Near(0.25, y[0]);
        Near(0.125, y[1]);
    }

    [Fact]
    public void ExponentialClipsToDomainAndRange()
    {
        var f = Parse("<< /FunctionType 2 /Domain [0 1] /Range [0 0.8] /N 1 >>");
        Near(0.8, Eval(f, 3)[0]);
        Near(0, Eval(f, -3)[0]);
    }

    [Fact]
    public void ExponentialWithUnequalEndsIsDamaged()
    {
        var e = Assert.Throws<PdfReadException>(() => Parse("<< /FunctionType 2 /Domain [0 1] /C0 [0] /C1 [1 1] /N 1 >>"));
        Assert.Equal(PdfReadProblem.Damaged, e.Problem);
    }

    private const string Stitched =
        "<< /FunctionType 3 /Domain [0 1] /Bounds [0.5] /Encode [0 1 0 1] /Functions [" +
        "<< /FunctionType 2 /Domain [0 1] /C0 [0] /C1 [1] /N 1 >> << /FunctionType 2 /Domain [0 1] /C0 [1] /C1 [0] /N 1 >>] >>";

    [Theory]
    [InlineData(0, 0)]
    [InlineData(0.25, 0.5)]
    [InlineData(0.5, 1)]
    [InlineData(0.75, 0.5)]
    [InlineData(1, 0)]
    public void StitchingPicksTheSubdomain(double x, double expected)
    {
        Near(expected, Eval(Parse(Stitched), x)[0]);
    }

    [Fact]
    public void StitchingEncodeCanRunBackwards()
    {
        var f = Parse("<< /FunctionType 3 /Domain [0 1] /Bounds [] /Encode [1 0] /Functions [<< /FunctionType 2 /Domain [0 1] /N 1 >>] >>");
        Near(0.75, Eval(f, 0.25)[0]);
    }

    [Fact]
    public void StitchingWithTheWrongBoundsCountIsDamaged()
    {
        var e = Assert.Throws<PdfReadException>(() =>
            Parse("<< /FunctionType 3 /Domain [0 1] /Bounds [0.2 0.4] /Encode [0 1 0 1] /Functions [<< /FunctionType 2 /Domain [0 1] /N 1 >> << /FunctionType 2 /Domain [0 1] /N 1 >>] >>"));
        Assert.Equal(PdfReadProblem.Damaged, e.Problem);
    }

    [Fact]
    public void StitchingDeeperThanTheLimitIsDamaged()
    {
        string f = "<< /FunctionType 2 /Domain [0 1] /N 1 >>";
        for (int i = 0; i < 12; i++)
            f = $"<< /FunctionType 3 /Domain [0 1] /Bounds [] /Encode [0 1] /Functions [{f}] >>";
        var e = Assert.Throws<PdfReadException>(() => Parse(f));
        Assert.Equal(PdfReadProblem.Damaged, e.Problem);
    }

    [Fact]
    public void SampledInterpolatesOneInput()
    {
        var f = Parse("<< /FunctionType 0 /Domain [0 1] /Range [0 1] /Size [3] /BitsPerSample 8 >>", [0, 255, 0]);
        Near(0, Eval(f, 0)[0]);
        Near(0.5, Eval(f, 0.25)[0], 1e-9);
        Near(1, Eval(f, 0.5)[0]);
        Near(0, Eval(f, 1)[0]);
    }

    [Fact]
    public void SampledInterpolatesTwoInputsWithTheFirstVaryingFastest()
    {
        var f = Parse("<< /FunctionType 0 /Domain [0 1 0 1] /Range [0 1] /Size [2 2] /BitsPerSample 8 >>", [0, 255, 255, 0]);
        Near(0, Eval(f, 0, 0)[0]);
        Near(1, Eval(f, 1, 0)[0]);
        Near(1, Eval(f, 0, 1)[0]);
        Near(0, Eval(f, 1, 1)[0]);
        Near(0.5, Eval(f, 0.5, 0.5)[0]);
        Near(0.75, Eval(f, 0.75, 0)[0]);
    }

    [Fact]
    public void SampledGivesSeveralOutputs()
    {
        var f = Parse("<< /FunctionType 0 /Domain [0 1] /Range [0 1 0 1] /Size [2] /BitsPerSample 8 >>", [0, 255, 255, 0]);
        Assert.Equal(2, f.Outputs);
        var y = Eval(f, 0);
        Near(0, y[0]);
        Near(1, y[1]);
        y = Eval(f, 1);
        Near(1, y[0]);
        Near(0, y[1]);
    }

    [Theory]
    [InlineData(1, new byte[] { 0x40 }, 0.0)]
    [InlineData(2, new byte[] { 0x34 }, 1.0 / 3)]
    [InlineData(4, new byte[] { 0x0F, 0x80 }, 8.0 / 15)]
    [InlineData(12, new byte[] { 0x00, 0x0F, 0xFF, 0x80, 0x00 }, 2048 / 4095.0)]
    [InlineData(16, new byte[] { 0, 0, 0xFF, 0xFF, 0x80, 0x00 }, 32768 / 65535.0)]
    [InlineData(24, new byte[] { 0, 0, 0, 0xFF, 0xFF, 0xFF, 0x80, 0, 0 }, 0.5)]
    [InlineData(32, new byte[] { 0, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF, 0x80, 0, 0, 0 }, 0.5)]
    public void SampledReadsEveryBitDepth(int bits, byte[] data, double lastSample)
    {
        // Three samples; the second is the maximum, the third as given.
        var f = Parse($"<< /FunctionType 0 /Domain [0 1] /Range [0 1] /Size [3] /BitsPerSample {bits} >>", data);
        Near(lastSample, Eval(f, 1)[0], 1e-6);
        Near(1, Eval(f, 0.5)[0], 1e-6);
    }

    [Fact]
    public void SampledDecodeAndEncodeAreApplied()
    {
        var f = Parse("<< /FunctionType 0 /Domain [0 1] /Range [0 1] /Decode [1 0] /Encode [1 0] /Size [2] /BitsPerSample 8 >>", [0, 255]);
        // Encode runs backwards, so x = 0 reads the last sample; Decode flips the result.
        Near(0, Eval(f, 0)[0]);
        Near(1, Eval(f, 1)[0]);
    }

    [Fact]
    public void SampledWithANanInputStaysInsideTheSamples()
    {
        // A NaN does not clamp, and its fraction is not 0, so the corner past the only sample is weighed.
        var f = Parse("<< /FunctionType 0 /Domain [0 1] /Range [0 1] /Size [1] /BitsPerSample 8 >>", [255]);
        Near(Eval(f, 0)[0], Eval(f, double.NaN)[0]);
    }

    [Fact]
    public void SampledWithFewerSamplesThanSizeIsDamaged()
    {
        var e = Assert.Throws<PdfReadException>(() =>
            Parse("<< /FunctionType 0 /Domain [0 1] /Range [0 1] /Size [100] /BitsPerSample 8 >>", [1, 2, 3]));
        Assert.Equal(PdfReadProblem.Damaged, e.Problem);
    }

    [Fact]
    public void SampledWithAHugeSizeIsDamagedNotAllocated()
    {
        var e = Assert.Throws<PdfReadException>(() =>
            Parse("<< /FunctionType 0 /Domain [0 1 0 1 0 1] /Range [0 1] /Size [2000000 2000000 2000000] /BitsPerSample 32 >>", [1, 2, 3]));
        Assert.Equal(PdfReadProblem.Damaged, e.Problem);
    }

    [Fact]
    public void CalculatorRunsArithmetic()
    {
        Near(0.25, Eval(Calculator("{ dup mul }"), 0.5)[0]);
        Near(3, Eval(Calculator("{ pop 7 2 idiv }", range: "[0 10]"), 0)[0]);
        Near(1, Eval(Calculator("{ pop 7 2 mod }", range: "[0 10]"), 0)[0]);
        Near(8, Eval(Calculator("{ pop 2 3 exp }", range: "[0 10]"), 0)[0]);
        Near(2, Eval(Calculator("{ pop 100 log }", range: "[0 10]"), 0)[0]);
        Near(3, Eval(Calculator("{ pop 2.5 round }", range: "[0 10]"), 0)[0]);
        Near(3, Eval(Calculator("{ pop 3.7 cvi }", range: "[0 10]"), 0)[0]);
        Near(2, Eval(Calculator("{ pop -2.5 truncate abs }", range: "[0 10]"), 0)[0]);
        Near(8, Eval(Calculator("{ pop 1 3 bitshift }", range: "[0 10]"), 0)[0]);
        Near(3, Eval(Calculator("{ pop 9 sqrt }", range: "[0 10]"), 0)[0]);
        Near(4, Eval(Calculator("{ pop 3.2 ceiling }", range: "[0 10]"), 0)[0]);
        Near(3, Eval(Calculator("{ pop 3.9 floor }", range: "[0 10]"), 0)[0]);
        Near(5, Eval(Calculator("{ pop 2 3 add }", range: "[0 10]"), 0)[0]);
        Near(6, Eval(Calculator("{ pop 2 3 mul }", range: "[0 10]"), 0)[0]);
        Near(2.5, Eval(Calculator("{ pop 5 2 div }", range: "[0 10]"), 0)[0]);
        Near(0, Eval(Calculator("{ pop 5 0 div }", range: "[0 10]"), 0)[0]);
    }

    [Fact]
    public void CalculatorTrigonometryIsInDegrees()
    {
        Near(1, Eval(Calculator("{ 360 mul sin }", range: "[-1 1]"), 0.25)[0], 1e-9);
        Near(-1, Eval(Calculator("{ 360 mul cos }", range: "[-1 1]"), 0.5)[0], 1e-9);
        Near(1, Eval(Calculator("{ pop 1 0 atan 90 div }"), 0)[0]);
        Near(0.5, Eval(Calculator("{ pop 0 -1 atan 360 div }"), 0)[0]);
    }

    [Fact]
    public void CalculatorStackOperators()
    {
        var domain = "[0 1 0 1 0 1]";
        var range = "[0 1 0 1 0 1]";
        Assert.Equal([0.3, 0.1, 0.2], Eval(Calculator("{ 3 1 roll }", domain, range), 0.1, 0.2, 0.3));
        Assert.Equal([0.2, 0.3, 0.1], Eval(Calculator("{ 3 -1 roll }", domain, range), 0.1, 0.2, 0.3));
    }

    [Fact]
    public void CalculatorIndexAndCopyGiveTheRightValues()
    {
        var two = "[0 1 0 1]";
        Assert.Equal([0.1, 0.2, 0.1], Eval(Calculator("{ 1 index }", two, "[0 1 0 1 0 1]"), 0.1, 0.2));
        Assert.Equal([0.1, 0.2, 0.1, 0.2], Eval(Calculator("{ 2 copy }", two, "[0 1 0 1 0 1 0 1]"), 0.1, 0.2));
        Assert.Equal([0.2, 0.1], Eval(Calculator("{ exch }", two, two), 0.1, 0.2));
    }

    [Fact]
    public void CalculatorBranches()
    {
        var f = Calculator("{ 0.5 gt { 1 } { 0 } ifelse }");
        Near(1, Eval(f, 0.7)[0]);
        Near(0, Eval(f, 0.2)[0]);
        var g = Calculator("{ dup 0.5 lt { pop 0 } if }");
        Near(0, Eval(g, 0.3)[0]);
        Near(0.8, Eval(g, 0.8)[0]);
    }

    [Fact]
    public void CalculatorBooleans()
    {
        var two = "[0 1 0 1]";
        var both = Calculator("{ 0.5 gt exch 0.5 gt and { 1 } { 0 } ifelse }", two);
        Near(1, Eval(both, 0.7, 0.9)[0]);
        Near(0, Eval(both, 0.7, 0.1)[0]);
        var either = Calculator("{ 0.5 gt exch 0.5 gt or { 1 } { 0 } ifelse }", two);
        Near(1, Eval(either, 0.7, 0.1)[0]);
        Near(0, Eval(either, 0.2, 0.1)[0]);
        var differ = Calculator("{ 0.5 gt exch 0.5 gt xor { 1 } { 0 } ifelse }", two);
        Near(1, Eval(differ, 0.7, 0.1)[0]);
        Near(0, Eval(differ, 0.7, 0.9)[0]);
        var negated = Calculator("{ 0.5 gt not { 1 } { 0 } ifelse }");
        Near(0, Eval(negated, 0.7)[0]);
        Near(1, Eval(negated, 0.2)[0]);
        Near(1, Eval(Calculator("{ pop true { 1 } { 0 } ifelse }"), 0)[0]);
        Near(0, Eval(Calculator("{ pop false { 1 } { 0 } ifelse }"), 0)[0]);
        Near(1, Eval(Calculator("{ pop 6 3 and 2 eq { 1 } { 0 } ifelse }"), 0)[0]);
        Near(1, Eval(Calculator("{ pop 4 1 or 5 eq { 1 } { 0 } ifelse }"), 0)[0]);
        Near(1, Eval(Calculator("{ pop 0 not -1 eq { 1 } { 0 } ifelse }"), 0)[0]);
        Near(1, Eval(Calculator("{ pop 1 2 ne 3 3 ge and 2 2 le and 1 2 lt and 3 2 gt and { 1 } { 0 } ifelse }"), 0)[0]);
    }

    [Fact]
    public void CalculatorIgnoresCommentsAndNewlines()
    {
        Near(0.5, Eval(Calculator("% tint\n{\n  0.5 % half\n  mul 2\r  mul }"), 0.5)[0], 1e-9);
        Near(0.2, Eval(Calculator("{ 0.5 mul 0.8 mul }"), 0.5)[0]);
    }

    [Fact]
    public void CalculatorClipsInputAndOutput()
    {
        var f = Calculator("{ 10 mul }");
        Near(1, Eval(f, 0.9)[0]);
        Near(1, Eval(f, 50)[0]);
    }

    [Theory]
    [InlineData("{ pop pop }")]
    [InlineData("{ foo }")]
    [InlineData("{ 1 2")]
    [InlineData("1 2 }")]
    [InlineData("{ 1 if }")]
    [InlineData("{ 5 index }")]
    [InlineData("{ 2 copy 5 copy }")]
    [InlineData("{ exch }")]
    [InlineData("{ add }")]
    public void CalculatorErrorsAreDamaged(string program)
    {
        var e = Assert.Throws<PdfReadException>(() => Eval(Calculator(program), 0.5));
        Assert.Equal(PdfReadProblem.Damaged, e.Problem);
    }

    [Fact]
    public void CalculatorStackIsLimited()
    {
        var program = "{ " + string.Concat(Enumerable.Repeat("dup ", 120)) + " }";
        var e = Assert.Throws<PdfReadException>(() => Eval(Calculator(program), 0.5));
        Assert.Equal(PdfReadProblem.Damaged, e.Problem);
    }

    [Fact]
    public void CalculatorNestingIsLimited()
    {
        var program = string.Concat(Enumerable.Repeat("{ ", 200)) + string.Concat(Enumerable.Repeat("} ", 200));
        var e = Assert.Throws<PdfReadException>(() => Calculator(program));
        Assert.Equal(PdfReadProblem.Damaged, e.Problem);
    }

    [Fact]
    public void CalculatorWithoutAStreamIsDamaged()
    {
        var e = Assert.Throws<PdfReadException>(() => Parse("<< /FunctionType 4 /Domain [0 1] /Range [0 1] >>"));
        Assert.Equal(PdfReadProblem.Damaged, e.Problem);
    }

    [Fact]
    public void AnArrayOfFunctionsBehavesAsOne()
    {
        var f = Parse("[<< /FunctionType 2 /Domain [0 1] /N 1 >> << /FunctionType 2 /Domain [0 1] /C0 [1] /C1 [0] /N 1 >>]");
        Assert.Equal(2, f.Outputs);
        var y = Eval(f, 0.25);
        Near(0.25, y[0]);
        Near(0.75, y[1]);
    }

    [Fact]
    public void UnknownTypeIsUnsupported()
    {
        var e = Assert.Throws<PdfReadException>(() => Parse("<< /FunctionType 1 /Domain [0 1] >>"));
        Assert.Equal(PdfReadProblem.Unsupported, e.Problem);
    }

    [Theory]
    [InlineData("<< /FunctionType 2 >>")]
    [InlineData("<< /FunctionType 2 /Domain [0] >>")]
    [InlineData("<< /FunctionType 2 /Domain [/a /b] >>")]
    [InlineData("42")]
    [InlineData("[]")]
    public void MalformedFunctionsAreDamaged(string text)
    {
        var e = Assert.Throws<PdfReadException>(() => Parse(text));
        Assert.Equal(PdfReadProblem.Damaged, e.Problem);
    }
}
