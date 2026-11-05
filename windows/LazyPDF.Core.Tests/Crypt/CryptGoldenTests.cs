using Xunit;

namespace LazyPDF.Core.Tests;

// Mirrored by Tests/LazyPDFKitTests/Crypt/CryptGoldenTests.swift. Run with LAZYPDF_WRITE_GOLDEN=1 to write the
// outputs again; Swift only reads them. The certificates and sealed files are inputs: LAZYPDF_WRITE_FIXTURES=1 makes
// the ones that are missing.
public class CryptGoldenTests
{
    [Fact]
    public void CryptOutputIsTheGoldenFile()
    {
        if (Environment.GetEnvironmentVariable("LAZYPDF_WRITE_FIXTURES") == "1") CryptGolden.WriteSealedFiles();
        Golden.Check("crypt", "crypt-output.txt", CryptGolden.Run(Golden.Input("crypt", "crypt-input.txt")));
    }
}
