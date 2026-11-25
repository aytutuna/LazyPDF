using Xunit;

namespace LazyPDF.Core.Tests;

// Mirrored by Tests/LazyPDFKitTests/Accessibility/AccessibilityGoldenTests.swift. Run with LAZYPDF_WRITE_GOLDEN=1 to write the
// output again; Swift only reads it.
public class AccessibilityGoldenTests
{
    [Fact]
    public void AccessibilityOutputIsTheGoldenFile()
    {
        Golden.Check("accessibility", "accessibility-output.txt", AccessibilityGolden.Run(Golden.Input("accessibility", "accessibility-input.txt")));
    }
}
