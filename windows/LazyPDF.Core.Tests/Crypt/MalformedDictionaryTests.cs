using Xunit;

namespace LazyPDF.Core.Tests;

public class MalformedDictionaryTests
{
    private static readonly byte[] Id = SyntheticEncryption.Id;

    private static PdfReadException Fails(PdfDictionary dictionary) =>
        Assert.Throws<PdfReadException>(() => PdfSecurity.Open(dictionary, Id, ""));

    [Fact]
    public void OtherSecurityHandlerIsUnsupported()
    {
        var dictionary = SyntheticEncryption.Legacy(2, 3, 128, "", "o").Dictionary;
        dictionary["Filter"] = new PdfName("Adobe.PubSec");

        Assert.Equal(PdfReadProblem.Unsupported, Fails(dictionary).Problem);
    }

    [Fact]
    public void MissingFilterIsUnsupported()
    {
        var dictionary = SyntheticEncryption.Legacy(2, 3, 128, "", "o").Dictionary;
        dictionary["Filter"] = null;

        Assert.Equal(PdfReadProblem.Unsupported, Fails(dictionary).Problem);
    }

    [Theory]
    [InlineData(0, 2)]
    [InlineData(3, 3)]
    [InlineData(6, 7)]
    [InlineData(2, 6)]
    [InlineData(5, 4)]
    public void UnknownVersionOrRevisionIsUnsupported(int v, int r)
    {
        var dictionary = SyntheticEncryption.Legacy(2, 3, 128, "", "o").Dictionary;
        dictionary["V"] = new PdfNumber(v);
        dictionary["R"] = new PdfNumber(r);

        Assert.Equal(PdfReadProblem.Unsupported, Fails(dictionary).Problem);
    }

    [Fact]
    public void UnknownCryptFilterMethodIsUnsupported()
    {
        var dictionary = SyntheticEncryption.Legacy(4, 4, 128, "", "o", cfm: "AESV9").Dictionary;

        Assert.Equal(PdfReadProblem.Unsupported, Fails(dictionary).Problem);
    }

    [Fact]
    public void Aes256FilterOnR4IsUnsupported()
    {
        var dictionary = SyntheticEncryption.Legacy(4, 4, 128, "", "o", cfm: "AESV3").Dictionary;

        Assert.Equal(PdfReadProblem.Unsupported, Fails(dictionary).Problem);
    }

    [Fact]
    public void Rc4FilterOnR6IsUnsupported()
    {
        var dictionary = SyntheticEncryption.Modern(6, "", "o").Dictionary;
        ((PdfDictionary)((PdfDictionary)dictionary["CF"]!)["StdCF"]!)["CFM"] = new PdfName("V2");

        Assert.Equal(PdfReadProblem.Unsupported, Fails(dictionary).Problem);
    }

    [Fact]
    public void StreamFilterMissingFromCfIsDamaged()
    {
        var dictionary = SyntheticEncryption.Legacy(4, 4, 128, "", "o", cfm: "AESV2", stmF: "Nope").Dictionary;

        Assert.Equal(PdfReadProblem.Damaged, Fails(dictionary).Problem);
    }

    [Theory]
    [InlineData("O")]
    [InlineData("U")]
    public void MissingPasswordValueIsDamaged(string key)
    {
        var dictionary = SyntheticEncryption.Legacy(2, 3, 128, "", "o").Dictionary;
        dictionary[key] = null;

        Assert.Equal(PdfReadProblem.Damaged, Fails(dictionary).Problem);
    }

    [Theory]
    [InlineData("O")]
    [InlineData("U")]
    public void ShortPasswordValueIsDamaged(string key)
    {
        var dictionary = SyntheticEncryption.Legacy(2, 3, 128, "", "o").Dictionary;
        dictionary[key] = new PdfString(new byte[20], true);

        Assert.Equal(PdfReadProblem.Damaged, Fails(dictionary).Problem);
    }

    [Theory]
    [InlineData("O")]
    [InlineData("U")]
    [InlineData("OE")]
    [InlineData("UE")]
    public void ShortModernValueIsDamaged(string key)
    {
        var dictionary = SyntheticEncryption.Modern(6, "", "o").Dictionary;
        dictionary[key] = new PdfString(new byte[10], true);

        Assert.Equal(PdfReadProblem.Damaged, Fails(dictionary).Problem);
    }

    [Fact]
    public void EmptyIdJustFailsThePasswordCheck()
    {
        var dictionary = SyntheticEncryption.Legacy(2, 3, 128, "", "o").Dictionary;

        Assert.Null(PdfSecurity.Open(dictionary, [], ""));
    }

    [Fact]
    public void OversizedKeyLengthIsClamped()
    {
        var dictionary = SyntheticEncryption.Legacy(2, 3, 128, "", "o").Dictionary;
        dictionary["Length"] = new PdfNumber(100000);

        Assert.NotNull(PdfSecurity.Open(dictionary, Id, ""));
    }

    [Fact]
    public void PasswordValueOfTheWrongTypeIsDamaged()
    {
        var dictionary = SyntheticEncryption.Legacy(2, 3, 128, "", "o").Dictionary;
        dictionary["O"] = new PdfName("NotAString");

        Assert.Equal(PdfReadProblem.Damaged, Fails(dictionary).Problem);
    }
}
