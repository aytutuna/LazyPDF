using Xunit;

namespace LazyPDF.Core.Tests;

// Mirrored by Tests/LazyPDFKitTests/Document/DocumentGoldenTests.swift. Run with LAZYPDF_WRITE_GOLDEN=1 to write the
// output again; Swift only reads it.
public class DocumentGoldenTests
{
    [Fact]
    public void DocumentOutputIsTheGoldenFile()
    {
        Golden.Check("document", "document-output.txt", DocumentGolden.Run(Golden.Input("document", "document-input.txt")));
    }
}
