using System.Windows;
using LazyPDF.App.Tools.Measure;
using Xunit;

namespace LazyPDF.App.Tests;

// What the numbers of the measure tool come to, before any page or pointer is involved.
public sealed class MeasureMathTests
{
    [Fact]
    public void AScaleTurnsPointsIntoTheRealUnit()
    {
        var scale = new MeasureScale(1, LengthUnit.Inch, 10, LengthUnit.Foot);

        Assert.Equal(10d / 72, scale.PerPoint, 9);
        Assert.Equal("10 ft", scale.Length(72));
        Assert.Equal("100 ft²", scale.Area(72 * 72));
        Assert.Equal("1 in = 10 ft", scale.Ratio);
    }

    [Theory]
    [InlineData(1, LengthUnit.Inch, 10, LengthUnit.Foot)]
    [InlineData(1.5, LengthUnit.Millimetre, 2, LengthUnit.Metre)]
    [InlineData(2, LengthUnit.Centimetre, 0.25, LengthUnit.Kilometre)]
    [InlineData(1, LengthUnit.Inch, 3, LengthUnit.Mile)]
    public void ARatioReadsBackAsTheScaleThatWroteIt(double page, LengthUnit pageUnit, double real, LengthUnit realUnit)
    {
        var scale = new MeasureScale(page, pageUnit, real, realUnit);

        Assert.Equal(scale, MeasureScale.TryParse(scale.Ratio));
    }

    [Theory]
    [InlineData("garbage")]
    [InlineData("0 mm = 1 m")]
    [InlineData("-1 mm = 1 m")]
    [InlineData("1 mm = -2 m")]
    [InlineData("1 mm = 2 parsec")]
    [InlineData("1 mm = 2 m = 3 m")]
    public void OtherTextIsNotAScale(string text) => Assert.Null(MeasureScale.TryParse(text));

    [Fact]
    public void MillimetresOnThePageAreMillimetresInTheWorldByDefault()
    {
        Assert.Equal("25 mm", MeasureScale.Actual.Length(25 / 25.4 * 72));
    }

    [Theory]
    [InlineData(0, 1)]
    [InlineData(1, 0)]
    [InlineData(-2, 1)]
    [InlineData(double.NaN, 1)]
    public void AScaleNeedsPositiveNumbers(double page, double real) =>
        Assert.False(new MeasureScale(page, LengthUnit.Inch, real, LengthUnit.Metre).IsValid);

    [Fact]
    public void ALengthIsTheSumOfItsSegmentsAndAPerimeterCloses()
    {
        Point[] corners = [new(0, 0), new(30, 0), new(30, 40)];

        Assert.Equal(70, MeasureShape.Length(corners, closed: false), 9);
        Assert.Equal(120, MeasureShape.Length(corners, closed: true), 9);
    }

    [Fact]
    public void AnAreaIsTheSameWhicheverWayRound()
    {
        Point[] square = [new(0, 0), new(10, 0), new(10, 10), new(0, 10)];

        Assert.Equal(100, MeasureShape.Area(square), 9);
        Assert.Equal(100, MeasureShape.Area([.. square.Reverse()]), 9);
        Assert.Equal(0, MeasureShape.Area([new(0, 0), new(5, 5)]), 9);
    }

    [Fact]
    public void ShiftKeepsToMultiplesOfFortyFiveDegrees()
    {
        var flat = MeasureShape.Straighten(new Point(0, 0), new Point(10, 1));
        var slanted = MeasureShape.Straighten(new Point(5, 5), new Point(15, 16));

        Assert.Equal(0, flat.Y, 9);
        Assert.Equal(Math.Sqrt(101), flat.X, 9);
        Assert.Equal(slanted.X - 5, slanted.Y - 5, 9);
    }

    [Fact]
    public void SnappingTakesTheNearestPointWithinReach()
    {
        Point[] corners = [new(10, 10), new(12, 10), new(50, 50)];

        Assert.Equal(new Point(12, 10), MeasureShape.Nearest(corners, new Point(13, 10), 3));
        Assert.Null(MeasureShape.Nearest(corners, new Point(30, 30), 3));
    }

    [Fact]
    public void SnappingToALineTakesThePointAlongIt()
    {
        (Point, Point)[] lines = [(new Point(0, 0), new Point(10, 0))];

        Assert.Equal(new Point(4, 0), MeasureShape.NearestOnLines(lines, new Point(4, 2), 3));
        Assert.Equal(new Point(10, 0), MeasureShape.NearestOnLines(lines, new Point(12, 1), 3));
        Assert.Null(MeasureShape.NearestOnLines(lines, new Point(4, 5), 3));
    }

    [Fact]
    public void AMeasurementReadsInTheScaleAndSitsAtItsMiddle()
    {
        var scale = new MeasureScale(1, LengthUnit.Inch, 1, LengthUnit.Metre);
        var line = new MeasureItem(MeasureKind.Distance, 0, [new(0, 0), new(144, 0)]);
        var area = new MeasureItem(MeasureKind.Area, 0, [new(0, 0), new(72, 0), new(72, 72), new(0, 72)]);
        var outline = area with { Kind = MeasureKind.Perimeter };

        Assert.Equal("2 m", line.Value(scale));
        Assert.Equal("1 m²", area.Value(scale));
        Assert.Equal("4 m", outline.Value(scale));
        Assert.Equal(new Point(72, 0), line.Middle);
        Assert.Equal(new Point(36, 36), area.Middle);
    }

    [Fact]
    public void AnAngleReadsAsSeenOnThePage()
    {
        Assert.Equal(45, MeasureShape.Angle([new(0, 0), new(10, -10)], MeasureKind.Distance)!.Value, 9);
        Assert.Equal(135, MeasureShape.Angle([new(0, 0), new(10, 10)], MeasureKind.Distance)!.Value, 9);
        Assert.Equal(90, MeasureShape.Angle([new(0, 0), new(10, 0), new(10, 10)], MeasureKind.Perimeter)!.Value, 9);
        Assert.Equal(180, MeasureShape.Angle([new(0, 0), new(5, 0), new(10, 0)], MeasureKind.Area)!.Value, 9);
        Assert.Null(MeasureShape.Angle([new(0, 0), new(10, 0)], MeasureKind.Area));
        Assert.Null(MeasureShape.Angle([new(0, 0)], MeasureKind.Distance));
    }
}
