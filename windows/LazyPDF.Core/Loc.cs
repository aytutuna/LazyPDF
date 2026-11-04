using System.Globalization;
using System.Resources;
using System.Text;

namespace LazyPDF.Core;

// From Lazy Scan's Loc.cs, without the languages Lazy PDF does not ship. The English text is the
// key and the fallback: with no entry in Strings.<language>.resx the English comes back unchanged.

public static class Loc
{
    private static readonly ResourceManager Resources = new("LazyPDF.Core.Strings", typeof(Loc).Assembly);

    // Stands in for the resource lookup in tests; flows with the async context, so parallel tests
    // do not see each other's table.
    private static readonly AsyncLocal<IReadOnlyDictionary<string, string>?> Override = new();

    internal static IReadOnlyDictionary<string, string>? Table
    {
        get => Override.Value;
        set => Override.Value = value;
    }

    /// <summary>
    /// The text for <paramref name="english"/> in the UI language, with {0}, {1}... filled from
    /// <paramref name="args"/>. A trailing |context (as in "Scan|noun") tells translators which
    /// word is meant and is never shown in English.
    /// </summary>
    public static string T(string english, params object?[] args) =>
        Format(Lookup(english) ?? StripContext(english), args);

    /// <summary>
    /// <paramref name="one"/> when <paramref name="n"/> is 1, else <paramref name="other"/>, in the UI
    /// language. {0} is n; <paramref name="args"/> follow from {1}. The catalog keys the translation by
    /// <paramref name="one"/>, and Turkish uses one form for every number.
    /// </summary>
    public static string Plural(int n, string one, string other, params object?[] args) =>
        Format(Lookup(one + "|plural") ?? StripContext(n == 1 ? one : other), [n, .. args]);

    private static string? Lookup(string key)
    {
        if (Override.Value is { } table) return table.GetValueOrDefault(key);
        return Resources.GetString(key);
    }

    private static string StripContext(string text)
    {
        var bar = text.LastIndexOf('|');
        return bar < 0 ? text : text[..bar];
    }

    // One pass, so a value that itself contains "{1}" is left alone. A placeholder with no
    // argument stays as written.
    private static string Format(string text, object?[] args)
    {
        if (args.Length == 0 || !text.Contains('{')) return text;
        var result = new StringBuilder();
        var i = 0;
        while (i < text.Length)
        {
            var open = text.IndexOf('{', i);
            if (open < 0) break;
            result.Append(text, i, open - i);
            var close = text.IndexOf('}', open + 1);
            if (close > open + 1
                && int.TryParse(text.AsSpan(open + 1, close - open - 1), NumberStyles.None, CultureInfo.InvariantCulture, out var index)
                && index < args.Length)
            {
                result.Append(Describe(args[index]));
                i = close + 1;
            }
            else
            {
                result.Append('{');
                i = open + 1;
            }
        }
        return result.Append(text, i, text.Length - i).ToString();
    }

    // Halves round to even before formatting, as in Lazy Scan.
    private static string Describe(object? arg) => arg switch
    {
        float f => Number(Math.Round((double)f, 3, MidpointRounding.ToEven)),
        double d => Number(Math.Round(d, 3, MidpointRounding.ToEven)),
        decimal m => Number(Math.Round(m, 3, MidpointRounding.ToEven)),
        sbyte or byte or short or ushort or int or uint or long or ulong or nint or nuint => Number(arg),
        _ => arg?.ToString() ?? "",
    };

    private static string Number(object value) =>
        ((IFormattable)value).ToString("#,##0.###", CultureInfo.CurrentCulture);
}
