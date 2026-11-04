using System.Text;
using Xunit;

namespace LazyPDF.Core.Tests;

public class EditSessionCertificateTests : IDisposable
{
    private readonly string _folder = Directory.CreateTempSubdirectory("lazypdf-cert").FullName;

    public void Dispose() => Directory.Delete(_folder, recursive: true);

    [Fact]
    public void RecipientEditsAndSavesAnEncryptedFile()
    {
        string path = Path.Combine(_folder, "sealed.pdf");
        File.WriteAllBytes(path, PublicKeyFiles.Seal(PublicKeyFiles.Alice));
        var session = PdfEditSession.Open(path, PublicKeyFiles.Alice);

        session.Document.Info!["Title"] = new PdfString(Encoding.Latin1.GetBytes("Edited"), isHex: false);
        Assert.True(session.Commit("title"));
        Assert.True(session.Undo());
        Assert.True(session.Redo());
        session.Save(path);

        using var again = PdfDocument.Open(path, PublicKeyFiles.Alice);
        Assert.True(again.Security!.IsPublicKey);
        Assert.Equal("Edited", SaveFixtures.Title(again));
    }

    [Fact]
    public void CompactSaveKeepsTheRecipients()
    {
        string path = Path.Combine(_folder, "compact.pdf");
        var session = PdfEditSession.Open(PublicKeyFiles.Seal(PublicKeyFiles.Alice), PublicKeyFiles.Alice);

        session.SaveCompact(path);

        using var again = PdfDocument.Open(path, PublicKeyFiles.Alice);
        Assert.True(again.Security!.IsPublicKey);
    }

    [Fact]
    public void SaverReadsBackWithTheCertificate()
    {
        string path = Path.Combine(_folder, "saver.pdf");
        byte[] sealedFile = PublicKeyFiles.Seal(PublicKeyFiles.Alice);

        Assert.Throws<PdfReadException>(() => PdfFileSaver.Save(path, sealedFile));
        PdfFileSaver.Save(path, sealedFile, PublicKeyFiles.Alice);

        Assert.Equal(sealedFile, File.ReadAllBytes(path));
    }
}
