using System.Globalization;

namespace LazyPDF.App.Tools.Measure;

public enum LengthUnit
{
    Millimetre,
    Centimetre,
    Metre,
    Kilometre,
    Inch,
    Foot,
    Yard,
    Mile,
}

public static class LengthUnits
{
    public const double PointInMetres = 0.0254 / 72;

    public static double Metres(this LengthUnit unit) => unit switch
    {
        LengthUnit.Millimetre => 0.001,
        LengthUnit.Centimetre => 0.01,
        LengthUnit.Metre => 1,
        LengthUnit.Kilometre => 1000,
        LengthUnit.Inch => 0.0254,
        LengthUnit.Foot => 0.3048,
        LengthUnit.Yard => 0.9144,
        _ => 1609.344,
    };

    public static string Symbol(this LengthUnit unit) => unit switch
    {
        LengthUnit.Millimetre => "mm",
        LengthUnit.Centimetre => "cm",
        LengthUnit.Metre => "m",
        LengthUnit.Kilometre => "km",
        LengthUnit.Inch => "in",
        LengthUnit.Foot => "ft",
        LengthUnit.Yard => "yd",
        _ => "mi",
    };
}

/// <summary>"<paramref name="Page"/> of <paramref name="PageUnit"/> on the page stand for <paramref name="Real"/> of <paramref name="RealUnit"/>", as a map scale is written.</summary>
public sealed record MeasureScale(double Page, LengthUnit PageUnit, double Real, LengthUnit RealUnit)
{
    public static MeasureScale Actual { get; } = new(1, LengthUnit.Millimetre, 1, LengthUnit.Millimetre);

    public bool IsValid => double.IsFinite(Page) && double.IsFinite(Real) && Page > 0 && Real > 0;

    /// <summary>How many real units one point of the page stands for.</summary>
    public double PerPoint => Real / (Page * PageUnit.Metres() / LengthUnits.PointInMetres);

    public string Length(double points) => Number(points * PerPoint) + " " + RealUnit.Symbol();

    public string Area(double squarePoints) => Number(squarePoints * PerPoint * PerPoint) + " " + RealUnit.Symbol() + "²";

    public string Ratio => string.Create(CultureInfo.InvariantCulture, $"{Page:0.####} {PageUnit.Symbol()} = {Real:0.####} {RealUnit.Symbol()}");

    private static string Number(double value) => value.ToString(value >= 100 ? "#,0" : "#,0.##", CultureInfo.CurrentCulture);
}
