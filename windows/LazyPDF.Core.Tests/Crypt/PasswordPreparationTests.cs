using System.Text;
using Xunit;

namespace LazyPDF.Core.Tests;

public class PasswordPreparationTests
{
    [Fact]
    public void AsciiStaysAsItIs()
    {
        Assert.Equal("Pass word 1"u8.ToArray(), PdfPasswords.Prepare("Pass word 1"));
    }

    [Fact]
    public void SpacesMapToSpaceAndSoftHyphensVanish()
    {
        Assert.Equal("a b c"u8.ToArray(), PdfPasswords.Prepare("a b　c"));
        Assert.Equal("abc"u8.ToArray(), PdfPasswords.Prepare("a­b‍c️"));
    }

    [Fact]
    public void CompatibilityCharactersAreNormalized()
    {
        Assert.Equal("fi1"u8.ToArray(), PdfPasswords.Prepare("ﬁ①"));
    }

    [Fact]
    public void PrepareComposesAndDecomposeDecomposes()
    {
        Assert.Equal([0xC3, 0xA9], PdfPasswords.Prepare("é"));
        Assert.Equal([0x65, 0xCC, 0x81], PdfPasswords.Decompose("é"));
    }

    [Fact]
    public void LongPasswordsAreCutAt127Bytes()
    {
        string text = new string('a', 200);

        Assert.Equal(127, PdfPasswords.Prepare(text).Length);
        Assert.Equal(127, PdfPasswords.Decompose(text).Length);
        Assert.Equal(127, PdfPasswords.Prepare(new string('é', 100)).Length);
    }

    [Fact]
    public void LegacyUsesLatin1ThenFallsBackToUtf8()
    {
        Assert.Equal([0x63, 0xE9], PdfPasswords.Legacy("cé"));
        Assert.Equal(Encoding.UTF8.GetBytes("中"), PdfPasswords.Legacy("中"));
        Assert.Empty(PdfPasswords.Legacy(""));
    }
}
