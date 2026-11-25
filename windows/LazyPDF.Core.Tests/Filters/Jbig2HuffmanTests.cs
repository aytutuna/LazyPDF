using Xunit;

namespace LazyPDF.Core.Tests;

public class Jbig2HuffmanTests
{
    // The prefix codes of Tables B.1 to B.15 as printed in the standard, one list for each table in the order of its lines.
    private static readonly long[][] StandardCodes =
    [
        [0, 2, 6, 7],
        [0, 2, 6, 14, 30, 62, 63],
        [254, 0, 2, 6, 14, 30, 255, 126, 62],
        [0, 2, 6, 14, 30, 31],
        [126, 0, 2, 6, 14, 30, 127, 62],
        [28, 8, 9, 10, 29, 30, 11, 0, 2, 3, 12, 13, 62, 63],
        [8, 0, 9, 26, 27, 10, 11, 28, 29, 12, 1, 2, 3, 30, 31],
        [252, 508, 253, 509, 124, 10, 0, 26, 58, 4, 59, 11, 12, 27, 28, 60, 125, 61, 510, 511, 1],
        [252, 508, 253, 509, 124, 10, 2, 3, 26, 58, 4, 59, 11, 12, 27, 28, 60, 125, 61, 510, 511, 0],
        [122, 252, 123, 24, 0, 25, 54, 124, 253, 1, 26, 55, 56, 57, 58, 59, 60, 125, 254, 255, 2],
        [0, 2, 12, 13, 28, 29, 60, 122, 123, 124, 125, 126, 127],
        [0, 2, 6, 28, 29, 60, 122, 123, 124, 125, 126, 254, 255],
        [0, 4, 12, 28, 13, 5, 58, 59, 60, 61, 62, 126, 127],
        [4, 5, 0, 6, 7],
        [124, 60, 28, 12, 4, 0, 5, 13, 29, 61, 125, 126, 127],
    ];

    [Fact]
    public void AssignedCodesAreThoseOfTheStandardTables()
    {
        for (int number = 1; number <= 15; number++)
        {
            Assert.Equal(StandardCodes[number - 1], Jbig2Huffman.Standard(number).Codes);
        }
    }
}
