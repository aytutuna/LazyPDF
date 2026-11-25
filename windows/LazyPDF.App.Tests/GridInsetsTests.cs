using Xunit;

namespace LazyPDF.App.Tests;

public sealed class GridInsetsTests
{
    [Theory]
    [InlineData(10, 7, 5)]
    [InlineData(10, 6, 5)]
    [InlineData(11, 6, 6)]
    [InlineData(11, 4, 4)]
    [InlineData(3, 6, 3)]
    [InlineData(9, 1, 1)]
    [InlineData(0, 5, 1)]
    public void TheLastRowIsNeverASingleTile(int count, int columns, int expected) =>
        Assert.Equal(expected, GridInsets.Balanced(count, columns));
}
