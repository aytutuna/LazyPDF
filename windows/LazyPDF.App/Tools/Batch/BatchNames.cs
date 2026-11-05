using System.Globalization;
using System.Text.RegularExpressions;

namespace LazyPDF.App.Tools.Batch;

internal static partial class BatchNames
{
    [GeneratedRegex(@"\{(name|n|date)(?::([^{}]*))?\}")]
    private static partial Regex Token();

    /// <summary>The file name for a result. A token with a format that does not fit stays as typed; characters Windows does not allow in a name become underscores.</summary>
    public static string Apply(string template, string name, int number, DateTimeOffset date)
    {
        string text = Token().Replace(template.Length == 0 ? "{name}" : template, m =>
        {
            string format = m.Groups[2].Value;
            try
            {
                return m.Groups[1].Value switch
                {
                    "name" => name,
                    "n" => number.ToString(format.Length == 0 ? "0" : format, CultureInfo.InvariantCulture),
                    _ => date.ToString(format.Length == 0 ? "yyyy-MM-dd" : format, CultureInfo.InvariantCulture),
                };
            }
            catch (FormatException)
            {
                return m.Value;
            }
        });
        foreach (char bad in Path.GetInvalidFileNameChars()) text = text.Replace(bad, '_');
        text = text.Trim().TrimEnd('.');
        if (text.Length == 0) text = name;
        return text.EndsWith(".pdf", StringComparison.OrdinalIgnoreCase) ? text : text + ".pdf";
    }
}
