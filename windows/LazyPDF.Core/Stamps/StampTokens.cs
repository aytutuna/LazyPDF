using System.Globalization;
using System.Text;

namespace LazyPDF.Core;

internal static class StampTokens
{
    public readonly record struct Values(int Page, int Pages, string Bates, HeaderFooterSpec Spec);

    /// <summary>Replaces the known {tokens} of a slot's text; an unknown one is left as typed.</summary>
    public static string Expand(string template, Values values)
    {
        if (!template.Contains('{')) return template;
        var result = new StringBuilder();
        for (int i = 0; i < template.Length; i++)
        {
            int end = template[i] == '{' ? template.IndexOf('}', i) : -1;
            if (end > i && Value(template[(i + 1)..end], values) is { } text)
            {
                result.Append(text);
                i = end;
            }
            else
            {
                result.Append(template[i]);
            }
        }
        return result.ToString();
    }

    private static string? Value(string token, Values v)
    {
        int colon = token.IndexOf(':');
        string name = colon < 0 ? token : token[..colon];
        string? argument = colon < 0 ? null : token[(colon + 1)..];
        var spec = v.Spec;
        switch (name)
        {
            case "page": return v.Page.ToString(CultureInfo.InvariantCulture);
            case "pages": return v.Pages.ToString(CultureInfo.InvariantCulture);
            case "file": return spec.FileName;
            case "bates": return spec.Bates is null ? null : v.Bates;
            case "date":
                try
                {
                    return spec.Date.ToString(string.IsNullOrEmpty(argument) ? spec.DateFormat : argument, spec.Culture);
                }
                catch (FormatException)
                {
                    return null;
                }
            default: return null;
        }
    }
}
