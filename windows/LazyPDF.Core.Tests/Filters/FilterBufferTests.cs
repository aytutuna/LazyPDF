using Xunit;

namespace LazyPDF.Core.Tests;

public class FilterBufferTests
{
    [Fact]
    public void FillsUpToTheCapAndRefusesTheNextByte()
    {
        var buffer = new FilterBuffer(1000);
        for (int i = 0; i < 1000; i++) buffer.Add((byte)i);
        Assert.Equal(1000, buffer.Count);
        Assert.Equal("A stream expands past the size limit.", Assert.Throws<PdfReadException>(() => buffer.Add(1)).Message);
        Assert.Equal(1000, buffer.Count);
    }

    [Fact]
    public void RunsThatCrossTheCapAreRefusedWhole()
    {
        var buffer = new FilterBuffer(1000);
        buffer.Add(new byte[600]);
        Assert.Throws<PdfReadException>(() => buffer.Add(new byte[401]));
        Assert.Equal(600, buffer.Count);
        buffer.Add(new byte[400]);
        Assert.Equal(1000, buffer.Count);
        Assert.Equal(1000, buffer.ToArray().Length);
    }
}
