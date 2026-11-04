using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class LexerToleranceTests
{
    private static PdfObject Read(string text, bool allowStream = true) =>
        new PdfLexer(new PdfArrayBytes(TestPdf.Latin(text))).ReadObject(allowStream);

    [Theory]
    [InlineData("--5", "-5")]
    [InlineData("1.2.3", "1.2")]
    [InlineData("5-3", "5")]
    [InlineData("-", "0")]
    [InlineData(".", "0")]
    [InlineData("+.5", "+.5")]
    [InlineData("12", "12")]
    public void MalformedNumbersReadAsTheirFirstValidPart(string token, string expected)
    {
        var array = Assert.IsType<PdfArray>(Read($"[{token}]"));
        var number = Assert.IsType<PdfNumber>(Assert.Single(array.Items));
        Assert.Equal(expected, number.Text);
    }

    [Fact]
    public void ArrayAndDictionaryNeverClosedStopAtEndobj()
    {
        var array = Assert.IsType<PdfArray>(Read("[1 2 3\nendobj\n"));
        Assert.Equal(3, array.Items.Count);
        var dictionary = Assert.IsType<PdfDictionary>(Read("<</A 1 /B [2\nendobj\n"));
        Assert.Equal(2, dictionary.Count);
        Assert.Throws<PdfReadException>(() => Read("<</A 1 /B "));
        Assert.Throws<PdfReadException>(() => Read("[1 2"));
    }

    [Fact]
    public void JunkWhereAKeyShouldBeIsReadPast()
    {
        var dictionary = Assert.IsType<PdfDictionary>(Read("<</A 1 (junk) 2 3 /B 4>>"));
        Assert.Equal(["A", "B"], dictionary.Entries.Select(e => e.Key).ToArray());
        Assert.Equal("4", ((PdfNumber)dictionary["B"]!).Text);
    }

    [Fact]
    public void StrayCharactersInAHexStringAreIgnored()
    {
        var text = Assert.IsType<PdfString>(Read("<41 4x2 zz 43>"));
        Assert.Equal("ABC", TestPdf.Text(text.Bytes));
    }

    [Fact]
    public void SpacesAfterTheStreamKeywordAreNotData()
    {
        var pdf = TestPdf.WithPages(1);
        pdf.Write("30 0 obj\n<</Length 5>>\nstream  \r\nhello\nendstream\nendobj\n");
        var document = PdfDocument.Open(pdf.FinishWithoutXref());
        Assert.Equal("hello", TestPdf.Text(document.RawData(document.Resolve<PdfStream>(new PdfReference(30, 0))!)));
    }
}
