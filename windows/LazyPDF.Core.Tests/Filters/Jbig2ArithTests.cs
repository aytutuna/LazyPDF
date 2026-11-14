using Xunit;

namespace LazyPDF.Core.Tests;

public class Jbig2ArithTests
{
    // The test sequence of T.88 H.2: 256 decisions under one context, and what the MQ encoder makes of them.
    private static readonly byte[] Decisions =
        Convert.FromHexString("00020051000000C00352872AAAAAAAAA82C02000FCD79EF6BF7FED904F46A3BF");

    private static readonly byte[] Coded =
        Convert.FromHexString("84C73BFCE1A143040220000041 0DBB86F4317FFF88FF37471ADB6ADFFFAC".Replace(" ", ""));

    private static int Bit(byte[] bytes, int i) => bytes[i / 8] >> (7 - i % 8) & 1;

    [Fact]
    public void EncoderMakesTheStandardsCodedBytes()
    {
        var e = new ArithEncoder();
        var context = new byte[1];
        for (int i = 0; i < 256; i++) e.Bit(context, 0, Bit(Decisions, i));
        Assert.Equal(Coded, e.Finish());
    }

    [Fact]
    public void DecoderReadsTheStandardsCodedBytes()
    {
        var arith = new Jbig2Arith(Coded, 0, Coded.Length);
        var context = new byte[1];
        for (int i = 0; i < 256; i++) Assert.Equal(Bit(Decisions, i), arith.Bit(context, 0));
    }
}
