using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class OcrVisualOrderTests
{
    [Theory]
    [InlineData("hello")]
    [InlineData("")]
    [InlineData("12.5%")]
    [InlineData("ğüşİı")]
    public void LeftToRightTextIsUnchanged(string text) => Assert.Equal(text, OcrVisualOrder.Flip(text));

    [Theory]
    [InlineData("שלום", "םולש")]
    [InlineData("שלום123", "123םולש")]
    [InlineData("a3.14ב", "בa3.14")]
    [InlineData("(שלום)", "(םולש)")]
    [InlineData("שלום עולם", "םלוע םולש")]
    public void RightToLeftWordsAreReversedAndKeepTheirNumbers(string logical, string visual)
    {
        Assert.Equal(visual, OcrVisualOrder.Flip(logical));
        Assert.Equal(logical, OcrVisualOrder.Flip(visual));
    }

    [Theory]
    [InlineData("مرحبا بالعالم 2026")]
    [InlineData("בדיקה (1,000) [x] «y» <z>")]
    [InlineData("abc שלום def")]
    public void FlippingTwiceGivesTheTextBack(string text) => Assert.Equal(text, OcrVisualOrder.Flip(OcrVisualOrder.Flip(text)));
}
