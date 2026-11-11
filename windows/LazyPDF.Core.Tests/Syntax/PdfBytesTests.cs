using Xunit;

namespace LazyPDF.Core.Tests;

// Mirrored by Tests/LazyPDFKitTests/Syntax/PdfBytesTests.swift.
public class PdfBytesTests
{
    private static byte[] Sample(int length)
    {
        var bytes = new byte[length];
        uint state = 12345;
        for (int i = 0; i < length; i++)
        {
            state = state * 1664525 + 1013904223;
            bytes[i] = (byte)(state >> 24);
        }
        return bytes;
    }

    [Fact]
    public void ArrayBytesPastTheEndReadAsMinusOne()
    {
        var bytes = new PdfArrayBytes([7, 8, 9]);
        Assert.Equal(3, bytes.Length);
        Assert.Equal(8, bytes[1]);
        Assert.Equal(-1, bytes[3]);
        Assert.Equal(-1, bytes[-1]);
        Assert.Equal(-1, bytes[long.MaxValue]);
        Assert.Equal<byte[]>([8, 9], bytes.Read(1, 10));
        Assert.Empty(bytes.Read(3, 1));
        Assert.Empty(bytes.Read(-1, 1));
        Assert.Empty(bytes.Read(0, 0));
        Assert.Empty(bytes.Read(0, -4));
        Assert.Equal<byte[]>([7], bytes.Read(0, 1));
    }

    [Fact]
    public void StreamBytesReadAcrossBlocksLikeTheArray()
    {
        byte[] data = Sample(300_000);
        var array = new PdfArrayBytes(data);
        var stream = new PdfStreamBytes(new MemoryStream(data));
        Assert.Equal(array.Length, stream.Length);
        foreach (long at in new long[] { 0, 1, 65535, 65536, 65537, 131071, 299_999, 300_000, -1 })
        {
            Assert.Equal(array[at], stream[at]);
        }
        foreach (var (at, count) in new (long, int)[] { (0, 10), (65530, 20), (65536, 65536), (1000, 250_000), (299_990, 100), (400_000, 5) })
        {
            Assert.Equal(array.Read(at, count), stream.Read(at, count));
        }
        // More blocks than the cache keeps, then back to the first.
        for (long at = 0; at < data.Length; at += 70_000) Assert.Equal(array[at], stream[at]);
        Assert.Equal(array[5], stream[5]);
    }

    [Fact]
    public void LexerReadsFromAStreamAsFromAnArray()
    {
        byte[] data = TestPdf.Latin("%x\n<</A [1 2 (three)] /B 4 0 R>> stream\nabc");
        var fromArray = new PdfLexer(new PdfArrayBytes(data)).ReadObject();
        var stream = new PdfStreamBytes(new MemoryStream(data));
        var lexer = new PdfLexer(stream);
        var fromStream = lexer.ReadObject();
        Assert.Equal(((PdfStream)fromArray).Dictionary.ToString(), ((PdfStream)fromStream).Dictionary.ToString());
        Assert.Equal(((PdfStream)fromArray).DataOffset, ((PdfStream)fromStream).DataOffset);
    }

    [Fact]
    public void NonFiniteNumbersWriteZero()
    {
        foreach (double value in new[] { double.NaN, double.PositiveInfinity, double.NegativeInfinity })
            Assert.Equal("0", new PdfNumber(value).Text);
    }

    [Fact]
    public void LexerFarOutsideTheBytesReadsTheEnd()
    {
        foreach (long position in new long[] { long.MaxValue, long.MaxValue - 1, long.MinValue, -5, 3, 1000 })
        {
            var lexer = new PdfLexer(new PdfArrayBytes(TestPdf.Latin("abc")), position);
            Assert.Equal("", lexer.ReadKeyword());
            Assert.Null(lexer.TryReadUnsigned());
            Assert.Throws<PdfReadException>(() => lexer.ReadObject());
            Assert.Throws<PdfReadException>(() => lexer.ReadObjectHeader());
        }
    }

    [Fact]
    public void NameAboveLatin1IsWrittenAsItsUtf8Bytes()
    {
        Assert.Equal("/#C5#9E", new PdfName("Ş").ToString());
        Assert.Equal("/#C5#9E", PdfName.FromText("Ş").ToString());
        var read = (PdfName)new PdfLexer(new PdfArrayBytes(TestPdf.Latin("/#C5#9E"))).ReadObject();
        Assert.Equal("Ş", read.Text);
        var latin = (PdfName)new PdfLexer(new PdfArrayBytes(TestPdf.Latin("/#FC"))).ReadObject();
        Assert.Equal(latin.Value, latin.Text);
    }
}
