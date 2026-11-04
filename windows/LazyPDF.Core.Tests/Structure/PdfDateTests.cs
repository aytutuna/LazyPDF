using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class PdfDateTests
{
    [Fact]
    public void ParsesFullDateWithZone()
    {
        var date = PdfDate.Parse("D:20261019213005+03'00'");
        Assert.Equal(new DateTimeOffset(2026, 10, 19, 21, 30, 5, TimeSpan.FromHours(3)), date);
    }

    [Theory]
    [InlineData("D:2026", 2026, 1, 1, 0)]
    [InlineData("D:202603", 2026, 3, 1, 0)]
    [InlineData("D:20260315", 2026, 3, 15, 0)]
    [InlineData("D:2026031512", 2026, 3, 15, 12)]
    [InlineData("20260315120000Z", 2026, 3, 15, 12)]
    [InlineData("D:20260315120000Z00'00'", 2026, 3, 15, 12)]
    [InlineData("  D:20260315120000  ", 2026, 3, 15, 12)]
    public void ShortenedFormsFillTheRest(string text, int year, int month, int day, int hour)
    {
        var date = PdfDate.Parse(text);
        Assert.Equal(new DateTimeOffset(year, month, day, hour, 0, 0, TimeSpan.Zero), date);
    }

    [Fact]
    public void NegativeAndHalfHourZones()
    {
        Assert.Equal(TimeSpan.FromHours(-5), PdfDate.Parse("D:20260101000000-05'00'")!.Value.Offset);
        Assert.Equal(new TimeSpan(5, 30, 0), PdfDate.Parse("D:20260101000000+05'30'")!.Value.Offset);
        Assert.Equal(new TimeSpan(5, 30, 0), PdfDate.Parse("D:20260101000000+0530")!.Value.Offset);
        Assert.Equal(TimeSpan.FromHours(2), PdfDate.Parse("D:20260101000000+02")!.Value.Offset);
    }

    [Theory]
    [InlineData("")]
    [InlineData("D:")]
    [InlineData("yesterday")]
    [InlineData("D:20261301")]
    [InlineData("D:20260230")]
    [InlineData("D:2026010125")]
    [InlineData("D:20260101000000+25'00'")]
    [InlineData("D:00000101")]
    public void NonsenseIsNull(string text)
    {
        Assert.Null(PdfDate.Parse(text));
    }

    [Fact]
    public void LeapSecondIsClamped()
    {
        Assert.Equal(59, PdfDate.Parse("D:20161231235960Z")!.Value.Second);
    }

    [Fact]
    public void FormatsBothWays()
    {
        var date = new DateTimeOffset(2026, 10, 19, 21, 30, 5, new TimeSpan(-3, -30, 0));
        Assert.Equal("D:20261019213005-03'30'", PdfDate.Format(date));
        Assert.Equal("2026-10-19T21:30:05-03:30", PdfDate.FormatXmp(date));
        Assert.Equal(date, PdfDate.Parse(PdfDate.Format(date)));
        Assert.Equal(date, PdfDate.ParseXmp(PdfDate.FormatXmp(date)));
    }

    [Fact]
    public void XmpDatesMayBeShort()
    {
        Assert.Equal(new DateTimeOffset(2026, 3, 1, 0, 0, 0, TimeSpan.Zero), PdfDate.ParseXmp("2026-03-01"));
        Assert.Null(PdfDate.ParseXmp("soon"));
        Assert.Null(PdfDate.ParseXmp(null));
    }
}
