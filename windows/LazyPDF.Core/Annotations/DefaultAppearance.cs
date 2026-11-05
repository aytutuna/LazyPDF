using System.Globalization;

namespace LazyPDF.Core;

/// <summary>The /DA string of a free text annotation (ISO 32000-1 12.7.3.3): font name and size, and a fill colour.</summary>
internal static class DefaultAppearance
{
    private static readonly Dictionary<string, (string Family, bool Bold, bool Italic)> Fonts = new()
    {
        ["Helv"] = ("Helvetica", false, false), ["HeBo"] = ("Helvetica", true, false), ["HeOb"] = ("Helvetica", false, true), ["HeBO"] = ("Helvetica", true, true),
        ["TiRo"] = ("Times New Roman", false, false), ["TiBo"] = ("Times New Roman", true, false), ["TiIt"] = ("Times New Roman", false, true), ["TiBI"] = ("Times New Roman", true, true),
        ["Cour"] = ("Courier New", false, false), ["CoBo"] = ("Courier New", true, false), ["CoOb"] = ("Courier New", false, true), ["CoBO"] = ("Courier New", true, true),
    };

    public static bool IsStandard(string font) => Fonts.ContainsKey(font);

    public static (string? Font, double? Size, double[]? Color) Parse(string? da)
    {
        if (string.IsNullOrWhiteSpace(da)) return (null, null, null);
        string? font = null;
        double? size = null;
        double[]? color = null;
        var operands = new List<string>();
        foreach (string token in da.Split([' ', '\t', '\r', '\n'], StringSplitOptions.RemoveEmptyEntries))
        {
            switch (token)
            {
                case "Tf" when operands.Count >= 2:
                    font = operands[^2].TrimStart('/');
                    size = Number(operands[^1]);
                    operands.Clear();
                    break;
                case "g" or "rg" or "k":
                {
                    int count = token == "g" ? 1 : token == "rg" ? 3 : 4;
                    if (operands.Count >= count)
                    {
                        var values = operands.TakeLast(count).Select(Number).ToArray();
                        if (values.All(v => v.HasValue)) color = [.. values.Select(v => v!.Value)];
                    }
                    operands.Clear();
                    break;
                }
                default:
                    operands.Add(token);
                    if (operands.Count > 16) operands.RemoveAt(0);
                    break;
            }
        }
        return (font, size, color);
    }

    /// <summary>The format a DA font name stands for; names outside the standard set keep the format as it is.</summary>
    public static TextFormat FormatOf(string font, TextFormat current) =>
        Fonts.TryGetValue(font, out var known) ? current with { Family = known.Family, Bold = known.Bold, Italic = known.Italic } : current;

    public static string Build(TextFormat format)
    {
        string name = format.Family switch
        {
            var f when f.StartsWith("Times", StringComparison.OrdinalIgnoreCase) => format.Bold ? (format.Italic ? "TiBI" : "TiBo") : format.Italic ? "TiIt" : "TiRo",
            var f when f.StartsWith("Courier", StringComparison.OrdinalIgnoreCase) => format.Bold ? (format.Italic ? "CoBO" : "CoBo") : format.Italic ? "CoOb" : "Cour",
            _ => format.Bold ? (format.Italic ? "HeBO" : "HeBo") : format.Italic ? "HeOb" : "Helv",
        };
        var color = string.Join(' ', format.Color.Select(n => new PdfNumber(n).Text));
        string op = format.Color.Length switch { 1 => "g", 4 => "k", _ => "rg" };
        return $"/{name} {new PdfNumber(format.Size).Text} Tf {color} {op}";
    }

    /// <summary>The /DS CSS the text was set with, which keeps the family and style a /DA name cannot say.</summary>
    public static string BuildStyle(TextFormat format, int alignment)
    {
        string align = alignment switch { 1 => "center", 2 => "right", _ => "left" };
        var rgb = format.Color.Length == 3 ? format.Color : format.Color.Length == 1 ? [format.Color[0], format.Color[0], format.Color[0]] : [0, 0, 0];
        string hex = "#" + string.Concat(rgb.Select(v => ((int)Math.Round(Math.Clamp(v, 0, 1) * 255)).ToString("X2", CultureInfo.InvariantCulture)));
        string size = format.Size.ToString("0.##", CultureInfo.InvariantCulture);
        return $"font-family: {format.Family}; font-size: {size}pt; font-weight: {(format.Bold ? "bold" : "normal")}; " +
               $"font-style: {(format.Italic ? "italic" : "normal")}; text-align: {align}; color: {hex}";
    }

    private static double? Number(string text) =>
        double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out double v) && double.IsFinite(v) ? v : null;
}
