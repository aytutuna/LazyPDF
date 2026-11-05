using Xunit;

namespace LazyPDF.Core.Tests;

// Mirrored by Tests/LazyPDFKitTests/Annotations/AnnotationsGoldenTests.swift. Run with LAZYPDF_WRITE_GOLDEN=1 to write the
// output again; Swift only reads it.
public class AnnotationsGoldenTests
{
    [Fact]
    public void AnnotationsOutputIsTheGoldenFile()
    {
        Golden.Check("annotations", "annotations-output.txt", AnnotationsGolden.Run(Golden.Input("annotations", "annotations-input.txt")));
    }
}
