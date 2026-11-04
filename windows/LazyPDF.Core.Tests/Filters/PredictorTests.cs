using Xunit;

namespace LazyPDF.Core.Tests;

public class PredictorTests
{
    private static PdfDictionary Parms(int predictor, int colors, int bits, int columns) =>
        FilterFixtures.Dict($"<< /Predictor {predictor} /Colors {colors} /BitsPerComponent {bits} /Columns {columns} >>");

    private static int RowLength(int colors, int bits, int columns) => (colors * bits * columns + 7) / 8;

    /// <summary>The PNG filters applied the way an encoder does, row type cycling through 0 to 4.</summary>
    private static byte[] PngEncode(byte[] raw, int rowLength, int bpp, Func<int, int> typeOf)
    {
        int rows = raw.Length / rowLength;
        var output = new byte[rows * (rowLength + 1)];
        for (int y = 0; y < rows; y++)
        {
            int type = typeOf(y);
            output[y * (rowLength + 1)] = (byte)type;
            for (int i = 0; i < rowLength; i++)
            {
                int a = i >= bpp ? raw[y * rowLength + i - bpp] : 0;
                int b = y > 0 ? raw[(y - 1) * rowLength + i] : 0;
                int c = i >= bpp && y > 0 ? raw[(y - 1) * rowLength + i - bpp] : 0;
                int p = a + b - c;
                int pa = Math.Abs(p - a), pb = Math.Abs(p - b), pc = Math.Abs(p - c);
                int paeth = pa <= pb && pa <= pc ? a : pb <= pc ? b : c;
                int x = raw[y * rowLength + i];
                output[y * (rowLength + 1) + 1 + i] = (byte)(type switch
                {
                    0 => x,
                    1 => x - a,
                    2 => x - b,
                    3 => x - (a + b) / 2,
                    _ => x - paeth,
                });
            }
        }
        return output;
    }

    [Theory]
    [InlineData(1, 1, 37)]
    [InlineData(1, 2, 21)]
    [InlineData(1, 4, 13)]
    [InlineData(1, 8, 30)]
    [InlineData(1, 16, 9)]
    [InlineData(3, 1, 11)]
    [InlineData(3, 4, 7)]
    [InlineData(3, 8, 20)]
    [InlineData(3, 16, 5)]
    [InlineData(4, 8, 16)]
    [InlineData(4, 2, 9)]
    public void PngPredictorUndoesEveryRowFilter(int colors, int bits, int columns)
    {
        int rowLength = RowLength(colors, bits, columns);
        var raw = FilterFixtures.RandomBytes(rowLength * 11, colors * 100 + bits);
        var encoded = PngEncode(raw, rowLength, Math.Max(1, (colors * bits + 7) / 8), y => y % 5);
        Assert.Equal(raw, PdfFilters.Predict(encoded, Parms(15, colors, bits, columns)));
    }

    [Fact]
    public void PredictorOneAndAbsentLeaveDataAlone()
    {
        var data = new byte[] { 1, 2, 3 };
        Assert.Same(data, PdfFilters.Predict(data, null));
        Assert.Same(data, PdfFilters.Predict(data, FilterFixtures.Dict("<< /Predictor 1 >>")));
    }

    [Fact]
    public void LastPngRowCutShortIsKeptAsFarAsItGoes()
    {
        int rowLength = RowLength(3, 8, 10);
        var raw = FilterFixtures.RandomBytes(rowLength * 4, 5);
        var encoded = PngEncode(raw, rowLength, 3, y => 2);
        var cut = encoded[..^7];
        Assert.Equal(raw[..^7], PdfFilters.Predict(cut, Parms(12, 3, 8, 10)));
        Assert.Equal(raw[..^(rowLength - 1)], PdfFilters.Predict(encoded[..^(rowLength - 1)], Parms(12, 3, 8, 10)));
    }

    [Fact]
    public void UnknownPngRowFilterLeavesTheRowAsItIs()
    {
        var encoded = new byte[] { 9, 5, 6, 7 };
        Assert.Equal(new byte[] { 5, 6, 7 }, PdfFilters.Predict(encoded, Parms(15, 1, 8, 3)));
    }

    [Fact]
    public void ColumnsLargerThanTheDataDoNotAllocateTheirSize()
    {
        var encoded = new byte[] { 1, 5, 6, 7 };
        Assert.Equal(new byte[] { 5, 6, 12 }, PdfFilters.Predict(encoded, Parms(15, 1, 16, 1 << 30)));
    }

    [Theory]
    [InlineData(1, 1, 50)]
    [InlineData(1, 2, 19)]
    [InlineData(1, 4, 15)]
    [InlineData(1, 8, 20)]
    [InlineData(1, 16, 9)]
    [InlineData(3, 1, 13)]
    [InlineData(3, 2, 10)]
    [InlineData(3, 4, 9)]
    [InlineData(3, 8, 17)]
    [InlineData(4, 16, 6)]
    public void TiffPredictorUndoesHorizontalDifferencing(int colors, int bits, int columns)
    {
        int rowLength = RowLength(colors, bits, columns);
        var raw = FilterFixtures.RandomBytes(rowLength * 6, bits * 10 + colors);
        var encoded = (byte[])raw.Clone();
        for (int y = 0; y < 6; y++)
        {
            for (int j = columns * colors - 1; j >= colors; j--)
            {
                long diff = Get(raw, y * rowLength, j, bits) - Get(raw, y * rowLength, j - colors, bits);
                Set(encoded, y * rowLength, j, bits, diff);
            }
        }
        // Trailing pad bits of a row are not components and stay as they were.
        Assert.Equal(raw, PdfFilters.Predict(encoded, Parms(2, colors, bits, columns)));
    }

    private static long Get(byte[] data, int start, int index, int bits)
    {
        if (bits == 16) return data[start + index * 2] << 8 | data[start + index * 2 + 1];
        if (bits == 8) return data[start + index];
        int bit = index * bits;
        return data[start + bit / 8] >> (8 - bits - bit % 8) & ((1 << bits) - 1);
    }

    private static void Set(byte[] data, int start, int index, int bits, long value)
    {
        if (bits == 16)
        {
            data[start + index * 2] = (byte)(value >> 8);
            data[start + index * 2 + 1] = (byte)value;
        }
        else if (bits == 8)
        {
            data[start + index] = (byte)value;
        }
        else
        {
            int bit = index * bits, shift = 8 - bits - bit % 8, mask = (1 << bits) - 1;
            data[start + bit / 8] = (byte)(data[start + bit / 8] & ~(mask << shift) | ((int)value & mask) << shift);
        }
    }

    [Fact]
    public void BitsPerComponentOutsideTheSetIsDamaged()
    {
        var e = Assert.Throws<PdfReadException>(() => PdfFilters.Predict([1, 2, 3], Parms(15, 1, 3, 1)));
        Assert.Equal(PdfReadProblem.Damaged, e.Problem);
    }

    [Fact]
    public void PredictorsBetweenThreeAndNineAreUnsupported()
    {
        var e = Assert.Throws<PdfReadException>(() => PdfFilters.Predict([1, 2, 3], Parms(5, 1, 8, 1)));
        Assert.Equal(PdfReadProblem.Unsupported, e.Problem);
    }

    [Fact]
    public void PredictorRunsAfterFlateInAChain()
    {
        int rowLength = RowLength(3, 8, 8);
        var raw = FilterFixtures.RandomBytes(rowLength * 8, 12);
        var stored = PdfFilterEncoders.Flate(PngEncode(raw, rowLength, 3, y => 4));
        Assert.Equal(raw, PdfFilters.Decode(stored, FilterFixtures.Parse("/FlateDecode"), Parms(15, 3, 8, 8)));
    }

    [Theory]
    [InlineData(2, 1073741824, 16, 1)]
    [InlineData(12, 1073741823, 16, 1073741825)]
    public void ParametersThatOverflowAreDamagedNotArithmeticErrors(int predictor, int colors, int bits, int columns)
    {
        var e = Assert.Throws<PdfReadException>(() => PdfFilters.Predict([1, 2, 3, 4], Parms(predictor, colors, bits, columns)));
        Assert.Equal(PdfReadProblem.Damaged, e.Problem);
    }
}
