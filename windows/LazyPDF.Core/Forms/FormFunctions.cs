using System.Globalization;
using System.Text;

namespace LazyPDF.Core;

internal readonly record struct Formatted(string Text, double[]? Color);

/// <summary>
/// The AF functions Acrobat writes into form actions (the AForm.js of its JavaScript library), run in
/// C#: number, percent, date, time and special formats, the matching keystroke checks, ranges and the
/// simple calculations. Month and day names are English.
/// </summary>
internal static class FormFunctions
{
    private static readonly string[] DateFormats =
    [
        "m/d", "m/d/yy", "mm/dd/yy", "mm/yy", "d-mmm", "d-mmm-yy", "dd-mmm-yy", "yy-mm-dd", "mmm-yy", "mmmm-yy",
        "mmm d, yyyy", "mmmm d, yyyy", "m/d/yy h:MM tt", "m/d/yy HH:MM",
    ];

    private static readonly string[] TimeFormats = ["HH:MM", "h:MM tt", "HH:MM:ss", "h:MM:ss tt"];
    private static readonly string[] Months = CultureInfo.InvariantCulture.DateTimeFormat.MonthNames;
    private static readonly string[] Days = CultureInfo.InvariantCulture.DateTimeFormat.DayNames;

    public static bool IsFormat(FormCall call) => call.Name.EndsWith("_Format", StringComparison.Ordinal) || call.Name.EndsWith("_FormatEx", StringComparison.Ordinal);

    /// <summary>The value as the format function shows it; null when the call is not a format or the value does not fit it (the raw value is shown then).</summary>
    public static Formatted? Format(FormCall call, string value)
    {
        if (value.Length == 0) return null;
        switch (call.Name)
        {
            case "AFNumber_Format":
                return ParseNumber(value, (int)call.Number(1)) is { } n ? Number(n, (int)call.Number(0), (int)call.Number(1), (int)call.Number(2), call.Text(4), call.Flag(5, true), percent: false) : null;
            case "AFPercent_Format":
                return ParseNumber(value) is { } p && double.IsFinite(p * 100) ? Number(p * 100, (int)call.Number(0), (int)call.Number(1), 0, "", true, percent: true) : null;
            case "AFDate_Format" or "AFDate_FormatEx" or "AFTime_Format" or "AFTime_FormatEx":
                return ParseDate(value, DateFormat(call)) is { } d ? new Formatted(PrintDate(d, DateFormat(call)), null) : null;
            case "AFSpecial_Format":
                return Special((int)call.Number(0), value) is { } s ? new Formatted(s, null) : null;
            default:
                return null;
        }
    }

    /// <summary>The keystroke or range check of a call: null when the value passes, else what to tell the user.</summary>
    public static string? Check(FormCall call, string value)
    {
        if (value.Length == 0) return null;
        switch (call.Name)
        {
            case "AFNumber_Keystroke" or "AFPercent_Keystroke":
                return ParseNumber(value) is null ? FormText.BadNumber : null;
            case "AFDate_Keystroke" or "AFDate_KeystrokeEx" or "AFTime_Keystroke" or "AFTime_KeystrokeEx":
                return ParseDate(value) is null ? FormText.BadDate : null;
            case "AFSpecial_Keystroke":
                return Special((int)call.Number(0), value) is null ? FormText.BadFormat : null;
            case "AFSpecial_KeystrokeEx":
                return MatchesMask(call.Text(0), value) ? null : FormText.BadFormat;
            case "AFRange_Validate":
                return Range(call, value);
            default:
                return null;
        }
    }

    /// <summary>AFSimple_Calculate over the values of the fields; text that is not a number is skipped.</summary>
    public static string? Calculate(FormCall call, Func<string, IEnumerable<string?>> valuesOf)
    {
        if (call.Name != "AFSimple_Calculate") return null;
        string function = call.Text(0);
        IEnumerable<string> names = call.Args.Count < 2 ? [] : call.Args[1] switch
        {
            List<object?> list => list.OfType<string>(),
            string one => one.Split(',', StringSplitOptions.TrimEntries),
            _ => [],
        };
        var numbers = names.SelectMany(valuesOf).Select(v => v is null ? null : ParseNumber(v)).OfType<double>().ToList();
        double result = function switch
        {
            "SUM" => numbers.Sum(),
            "AVG" => numbers.Count > 0 ? numbers.Average() : 0,
            "PRD" => numbers.Count > 0 ? numbers.Aggregate(1.0, (a, b) => a * b) : 0,
            "MIN" => numbers.Count > 0 ? numbers.Min() : 0,
            "MAX" => numbers.Count > 0 ? numbers.Max() : 0,
            _ => double.NaN,
        };
        return double.IsFinite(result) ? NumberText(result) : null;
    }

    // Math.Round goes through value * 1e10, which moves a large whole number by a few units in the last place; from 2^43 on a
    // double has no digits beyond the tenth to round off.
    public static string NumberText(double value) => (Math.Abs(value) < 1e13 ? Math.Round(value, 10) : value).ToString("R", CultureInfo.InvariantCulture);

    // Under a style with a comma as the decimal mark a lone dot followed by three digits is a group mark.
    private static double? ParseNumber(string text, int separatorStyle)
    {
        string t = text.Trim();
        if (separatorStyle == 2 && !t.Contains(',') && t.Count(c => c == '.') >= 1)
        {
            var parts = t.Split('.');
            if (parts.Skip(1).All(x => x.Length == 3 && x.All(char.IsAsciiDigit))) t = t.Replace(".", "");
        }
        return ParseNumber(t);
    }

    /// <summary>A number from the text a person or an export wrote: either decimal mark, any grouping, a currency sign, a minus or parentheses.</summary>
    public static double? ParseNumber(string text)
    {
        text = text.Trim();
        int first = text.IndexOfAny(['0', '1', '2', '3', '4', '5', '6', '7', '8', '9', '.', ',']);
        int last = text.LastIndexOfAny(['0', '1', '2', '3', '4', '5', '6', '7', '8', '9', '.', ',']);
        if (first < 0) return null;
        if (first > 0 && char.IsLetter(text[first - 1]) || last + 1 < text.Length && char.IsLetter(text[last + 1])) return null;
        string inner = text[first..(last + 1)];
        if (inner.Any(c => !(char.IsAsciiDigit(c) || c is '.' or ',' or '\'' or ' '))) return null;
        bool negative = text.Contains('-') || text.StartsWith('(') && text.EndsWith(')');
        string s = inner.Replace("'", "").Replace(" ", "");
        int dot = s.LastIndexOf('.'), comma = s.LastIndexOf(',');
        if (dot >= 0 && comma >= 0) s = dot > comma ? s.Replace(",", "") : s.Replace(".", "").Replace(',', '.');
        else if (comma >= 0) s = s.Count(c => c == ',') == 1 && s.Length - comma - 1 != 3 ? s.Replace(',', '.') : s.Replace(",", "");
        else if (dot >= 0 && s.Count(c => c == '.') > 1) s = s.Replace(".", "");
        if (!double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out double value) || !double.IsFinite(value)) return null;
        return negative ? -Math.Abs(value) : value;
    }

    private static Formatted Number(double value, int decimals, int separators, int negative, string currency, bool prepend, bool percent)
    {
        decimals = Math.Clamp(decimals, 0, 15);
        bool isNegative = value < 0 && Math.Round(Math.Abs(value), decimals, MidpointRounding.AwayFromZero) != 0;
        string text = Math.Round(Math.Abs(value), decimals, MidpointRounding.AwayFromZero).ToString("F" + decimals, CultureInfo.InvariantCulture);
        string whole = decimals > 0 ? text[..text.IndexOf('.')] : text;
        string fraction = decimals > 0 ? text[(text.IndexOf('.') + 1)..] : "";
        (string group, string mark) = separators switch { 0 => (",", "."), 1 => ("", "."), 2 => (".", ","), 3 => ("", ","), _ => ("'", ".") };
        if (group.Length > 0)
        {
            var sb = new StringBuilder();
            for (int i = 0; i < whole.Length; i++)
            {
                if (i > 0 && (whole.Length - i) % 3 == 0) sb.Append(group);
                sb.Append(whole[i]);
            }
            whole = sb.ToString();
        }
        string body = decimals > 0 ? whole + mark + fraction : whole;
        if (percent) body += "%";
        else if (currency.Length > 0) body = prepend ? currency + body : body + currency;
        if (isNegative) body = negative >= 2 ? "(" + body + ")" : "-" + body;
        return new Formatted(body, isNegative && negative is 1 or 3 ? [1, 0, 0] : null);
    }

    private static string? Range(FormCall call, string value)
    {
        if (ParseNumber(value) is not { } n) return FormText.BadNumber;
        bool hasMin = call.Flag(0), hasMax = call.Flag(2);
        double min = call.Number(1), max = call.Number(3);
        if (hasMin && n < min || hasMax && n > max)
        {
            string low = NumberText(min), high = NumberText(max);
            return hasMin && hasMax ? FormText.OutOfRange(low, high) : hasMin ? FormText.AtLeast(low) : FormText.AtMost(high);
        }
        return null;
    }

    private static string DateFormat(FormCall call) => call.Name switch
    {
        "AFDate_Format" => DateFormats[Math.Clamp((int)call.Number(0), 0, DateFormats.Length - 1)],
        "AFTime_Format" => TimeFormats[Math.Clamp((int)call.Number(0), 0, TimeFormats.Length - 1)],
        _ => call.Text(0),
    };

    // A value in the field's own format is read by it first: 03/04/2024 under dd/mm/yyyy is the third of April.
    private static DateTime? ParseDate(string text, string format)
    {
        if (DateTime.TryParseExact(text.Trim(), NetPattern(format), CultureInfo.InvariantCulture, DateTimeStyles.AllowWhiteSpaces, out var own)) return own;
        return ParseDate(text);
    }

    private static string NetPattern(string format)
    {
        var sb = new StringBuilder();
        for (int i = 0; i < format.Length;)
        {
            char c = format[i];
            int run = 1;
            while (i + run < format.Length && format[i + run] == c) run++;
            sb.Append(c switch
            {
                'd' or 'H' or 'h' or 's' => new string(c, run),
                'm' => new string('M', run),
                'M' => new string('m', run),
                'y' => run >= 4 ? "yyyy" : "yy",
                't' => "tt",
                '/' or ':' or '-' or ' ' or ',' or '.' => new string(c, run),
                _ => "'" + new string(c, run) + "'",
            });
            i += run;
        }
        return sb.ToString();
    }

    private static DateTime? ParseDate(string text)
    {
        text = text.Trim();
        string[] patterns =
        [
            "M/d/yyyy", "M/d/yy", "M/d", "d-MMM-yy", "d-MMM-yyyy", "yyyy-MM-dd", "yy-MM-dd", "MMM-yy", "MMMM-yy", "MMM d, yyyy", "MMMM d, yyyy",
            "M/d/yy h:mm tt", "M/d/yy H:mm", "M/d/yyyy h:mm tt", "M/d/yyyy H:mm", "H:mm", "h:mm tt", "H:mm:ss", "h:mm:ss tt", "d.M.yyyy", "dd.MM.yyyy",
        ];
        if (DateTime.TryParseExact(text, patterns, CultureInfo.InvariantCulture, DateTimeStyles.AllowWhiteSpaces, out var exact)) return exact;
        return DateTime.TryParse(text, CultureInfo.InvariantCulture, DateTimeStyles.AllowWhiteSpaces, out var any) ? any : null;
    }

    // The letters of util.printd: d day, m month, y year, H 24-hour, h 12-hour, M minute, s second, t am/pm.
    private static string PrintDate(DateTime d, string format)
    {
        var sb = new StringBuilder();
        for (int i = 0; i < format.Length;)
        {
            char c = format[i];
            int run = 1;
            while (i + run < format.Length && format[i + run] == c) run++;
            string two(int v) => v.ToString("00", CultureInfo.InvariantCulture);
            string part = c switch
            {
                'd' => run >= 4 ? Days[(int)d.DayOfWeek] : run == 3 ? Days[(int)d.DayOfWeek][..3] : run == 2 ? two(d.Day) : d.Day.ToString(CultureInfo.InvariantCulture),
                'm' => run >= 4 ? Months[d.Month - 1] : run == 3 ? Months[d.Month - 1][..3] : run == 2 ? two(d.Month) : d.Month.ToString(CultureInfo.InvariantCulture),
                'y' => run >= 4 ? d.Year.ToString("0000", CultureInfo.InvariantCulture) : two(d.Year % 100),
                'H' => run >= 2 ? two(d.Hour) : d.Hour.ToString(CultureInfo.InvariantCulture),
                'h' => run >= 2 ? two(d.Hour % 12 == 0 ? 12 : d.Hour % 12) : (d.Hour % 12 == 0 ? 12 : d.Hour % 12).ToString(CultureInfo.InvariantCulture),
                'M' => run >= 2 ? two(d.Minute) : d.Minute.ToString(CultureInfo.InvariantCulture),
                's' => run >= 2 ? two(d.Second) : d.Second.ToString(CultureInfo.InvariantCulture),
                't' => d.Hour < 12 ? "am" : "pm",
                _ => new string(c, run),
            };
            sb.Append(part);
            i += run;
        }
        return sb.ToString();
    }

    private static string? Special(int kind, string value)
    {
        var digits = new string([.. value.Where(char.IsAsciiDigit)]);
        return kind switch
        {
            0 when digits.Length == 5 => digits,
            1 when digits.Length == 9 => digits[..5] + "-" + digits[5..],
            2 when digits.Length == 10 => $"({digits[..3]}) {digits[3..6]}-{digits[6..10]}",
            2 when digits.Length == 7 => $"{digits[..3]}-{digits[3..]}",
            3 when digits.Length == 9 => $"{digits[..3]}-{digits[3..5]}-{digits[5..]}",
            _ => null,
        };
    }

    private static bool MatchesMask(string mask, string value)
    {
        if (mask.Length != value.Length) return false;
        for (int i = 0; i < mask.Length; i++)
        {
            bool ok = mask[i] switch
            {
                '9' => char.IsAsciiDigit(value[i]),
                'A' => char.IsLetter(value[i]),
                'O' => char.IsLetterOrDigit(value[i]),
                'X' => true,
                _ => value[i] == mask[i],
            };
            if (!ok) return false;
        }
        return true;
    }
}
