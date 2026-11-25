using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

// What OrdinalIgnoreCase treats as one letter: the invariant upper case, with the Turkish letters and the long s left apart.
public class RedactCaseFoldTests
{
    private static bool Found(string needle, string title)
    {
        using var document = RedactionKit.Page("BT ET");
        document.Trailer["Info"] = document.Add(new PdfDictionary { ["Title"] = PdfText.ToObject(title) });
        return RedactionMetadata.Scan(document, [needle], false).Any(f => f.Where == "The document information");
    }

    [Theory]
    [InlineData("i", "I", true)]
    [InlineData("secret", "SECRET", true)]
    [InlineData("ı", "I", false)]
    [InlineData("ı", "i", false)]
    [InlineData("İ", "i", false)]
    [InlineData("İ", "I", false)]
    [InlineData("İ", "İ", true)]
    [InlineData("ı", "ı", true)]
    [InlineData("ſ", "s", false)]
    [InlineData("ſ", "S", false)]
    [InlineData("s", "ſ", false)]
    [InlineData("K", "k", false)]
    [InlineData("ᾀ", "ᾈ", true)]
    [InlineData("𐐨", "𐐀", true)]
    public void LettersAreTheSameOnlyWhenOrdinalIgnoreCaseSaysSo(string needle, string title, bool same)
    {
        Assert.Equal(same, string.Equals(needle, title, StringComparison.OrdinalIgnoreCase));
        Assert.Equal(same, Found(needle, "about " + title));
    }
}
