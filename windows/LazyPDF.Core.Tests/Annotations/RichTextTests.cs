using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class RichTextTests
{
    private const string Open = "<body xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:xfa=\"http://www.xfa.org/schema/xfa-data/1.0/\" xfa:APIVersion=\"Acrobat:11.0.0\" style=\"font-size:11pt;font-family:Arial;color:#000000\">";

    [Fact]
    public void PlainTextKeepsParagraphsOnLines()
    {
        Assert.Equal("one\ntwo", PdfRichText.ToPlain(Open + "<p dir=\"ltr\"><span>one</span></p><p>two</p></body>"));
        Assert.Equal("a\nb", PdfRichText.ToPlain(Open + "<p>a<br/>b</p></body>"));
        Assert.Equal("a b c", PdfRichText.ToPlain(Open + "<p>a  \n  b <b>c</b></p></body>"));
    }

    [Fact]
    public void IndentationBetweenBlocksIsNotText()
    {
        Assert.Equal("one\ntwo", PdfRichText.ToPlain("<body xmlns=\"http://www.w3.org/1999/xhtml\">\n  <p>one</p>\n  <p>two</p>\n</body>"));
    }

    [Fact]
    public void EntitiesAndTurkishLettersAreText()
    {
        Assert.Equal("a & b < ş", PdfRichText.ToPlain("<body xmlns=\"http://www.w3.org/1999/xhtml\"><p>a &amp; b &lt; &#351;</p></body>"));
    }

    [Theory]
    [InlineData("")]
    [InlineData("<body><p>unclosed")]
    [InlineData("<!DOCTYPE b [<!ENTITY x \"y\">]><body>&x;</body>")]
    public void BrokenMarkupGivesNoText(string xhtml)
    {
        Assert.Equal("", PdfRichText.ToPlain(xhtml));
    }

    [Fact]
    public void TextWithoutMarkupIsItself()
    {
        Assert.Equal("just words", PdfRichText.ToPlain("just words"));
    }

    [Fact]
    public void HugeInputIsRefused()
    {
        Assert.Equal("", PdfRichText.ToPlain("<body>" + new string('x', 300_000) + "</body>"));
    }

    [Fact]
    public void DeepNestingDoesNotOverflow()
    {
        string deep = string.Concat(Enumerable.Repeat("<span>", 5000)) + "x" + string.Concat(Enumerable.Repeat("</span>", 5000));
        Assert.Equal("x", PdfRichText.ToPlain("<body>" + deep + "</body>"));
    }

    [Fact]
    public void ALeadingXmlDeclarationIsAllowed()
    {
        Assert.Equal("hello", PdfRichText.ToPlain("<?xml version=\"1.0\"?><body xmlns=\"http://www.w3.org/1999/xhtml\"><p>hello</p></body>"));
        Assert.Equal("", PdfRichText.ToPlain(" <?xml version=\"1.0\"?><p>late</p>"));
        Assert.Equal("", PdfRichText.ToPlain("<?xml?><p>bad</p>"));
    }
}
