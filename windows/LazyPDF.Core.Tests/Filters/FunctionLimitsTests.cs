using System.Text;
using Xunit;

namespace LazyPDF.Core.Tests;

public class FunctionLimitsTests
{
    private static PdfFunction Parse(string dictionary, byte[]? data = null)
    {
        var streams = new FilterFixtures.Streams();
        PdfObject function = data is null ? FilterFixtures.Parse(dictionary) : streams.Add(dictionary, data);
        return PdfFunction.Parse(function, FilterFixtures.Resolve, streams.Decode);
    }

    private static double[] Eval(PdfFunction f, params double[] input)
    {
        var output = new double[f.Outputs];
        f.Evaluate(input, output);
        return output;
    }

    [Fact]
    public void TintTransformWithAHugeRangeIsRefusedBeforeItAllocates()
    {
        var range = new StringBuilder("[");
        for (int i = 0; i < 1_000_000; i++) range.Append("0 1 ");
        range.Append(']');
        var streams = new FilterFixtures.Streams();
        var tint = streams.Add($"<< /FunctionType 4 /Domain [0 1] /Range {range} >>", Encoding.ASCII.GetBytes("{ }"));
        var image = FilterFixtures.Dict("<< /Width 1 /Height 1 /BitsPerComponent 8 >>");
        image["ColorSpace"] = new PdfArray([new PdfName("Separation"), new PdfName("X"), new PdfName("DeviceGray"), tint]);
        Assert.Throws<PdfReadException>(() => PdfImageSamples.ToRgba(image, [128], FilterFixtures.Resolve, streams.Decode));
    }

    [Fact]
    public async Task FunctionsThatManyOthersShareAreParsedOnce()
    {
        // Each level lists the next 256 times; parsed afresh every time that is 256 to the 8th power calls.
        var table = new Dictionary<int, PdfObject>();
        string bounds = string.Join(" ", Enumerable.Range(1, 255));
        string encode = string.Join(" ", Enumerable.Repeat("0 1", 256));
        for (int level = 1; level <= 7; level++)
        {
            string kids = string.Join(" ", Enumerable.Repeat($"{level + 1} 0 R", 256));
            table[level] = FilterFixtures.Parse($"<< /FunctionType 3 /Domain [0 1] /Bounds [{bounds}] /Encode [{encode}] /Functions [{kids}] >>");
        }
        table[8] = FilterFixtures.Parse("<< /FunctionType 2 /Domain [0 1] /N 1 >>");
        PdfObject? Resolve(PdfObject? v) => v is PdfReference r ? table.GetValueOrDefault(r.Number) : v;

        var task = Task.Run(() => PdfFunction.Parse(new PdfReference(1, 0), Resolve, _ => []));
        Assert.Same(task, await Task.WhenAny(task, Task.Delay(TimeSpan.FromSeconds(10))));
        Assert.Equal(0.5, Eval(await task, 0.5)[0], 9);
    }

    [Fact]
    public void ReversedDomainOrRangeIsDamagedNotAnArgumentError()
    {
        Assert.Equal(PdfReadProblem.Damaged,
            Assert.Throws<PdfReadException>(() => Parse("<< /FunctionType 2 /Domain [1 0] /N 1 >>")).Problem);
        Assert.Equal(PdfReadProblem.Damaged,
            Assert.Throws<PdfReadException>(() => Parse("<< /FunctionType 2 /Domain [0 1] /Range [1 0] /N 1 >>")).Problem);
    }

    [Fact]
    public void LabWithAReversedRangeKeepsTheDefaultRange()
    {
        var image = FilterFixtures.Dict("<< /Width 1 /Height 1 /BitsPerComponent 8 /ColorSpace [/Lab << /WhitePoint [0.95 1 1.09] /Range [100 -100 0 1] >>] >>");
        var rgba = PdfImageSamples.ToRgba(image, [128, 140, 120], FilterFixtures.Resolve, _ => []);
        Assert.Equal(4, rgba.Rgba.Length);
    }

    [Fact]
    public void SampleCountThatWrapsALongIsDamaged()
    {
        var e = Assert.Throws<PdfReadException>(() => Parse(
            "<< /FunctionType 0 /Domain [0 1 0 1 0 1] /Range [0 1] /Size [65536 131072 1073741824] /BitsPerSample 1 >>", [0xFF]));
        Assert.Equal(PdfReadProblem.Damaged, e.Problem);
    }

    [Fact]
    public void ADimensionOfOneSampleIsCountedOnce()
    {
        var f = Parse("<< /FunctionType 0 /Domain [0 1] /Range [0 1] /Size [1] /BitsPerSample 8 >>", [0x40]);
        Assert.Equal(0x40 / 255.0, Eval(f, 0.5)[0], 9);
    }

    [Theory]
    [InlineData("{ pop -1e300 -1 idiv }")]
    [InlineData("{ pop -1e300 -1 mod }")]
    public void CalculatorDivisionByMinusOneDoesNotOverflow(string program)
    {
        var f = Parse("<< /FunctionType 4 /Domain [0 1] /Range [-1e30 1e30] >>", Encoding.ASCII.GetBytes(program));
        Eval(f, 0.5);
    }
}
