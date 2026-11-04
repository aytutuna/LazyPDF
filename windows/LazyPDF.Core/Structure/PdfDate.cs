using System.Globalization;

namespace LazyPDF.Core;

// Formatting after Lazy Scan's PdfA.cs (PdfDate, XmpDate, Offset).

/// <summary>PDF dates (ISO 32000-1 7.9.4), "D:20261019213005+03'00'", and the XMP form of the same.</summary>
public static class PdfDate
{
    /// <summary>Reads a PDF date; every part after the year may be missing. A date without a zone counts as UTC. Null when it is not a date.</summary>
    public static DateTimeOffset? Parse(string? text)
    {
        if (text is null) return null;
        string s = text.Trim();
        if (s.StartsWith("D:", StringComparison.Ordinal)) s = s[2..];
        int at = 0;
        int Take(int digits, int fallback)
        {
            if (at + digits > s.Length) return fallback;
            for (int i = 0; i < digits; i++)
            {
                if (!char.IsAsciiDigit(s[at + i])) return fallback;
            }
            int value = int.Parse(s.AsSpan(at, digits), CultureInfo.InvariantCulture);
            at += digits;
            return value;
        }

        int year = Take(4, -1);
        int month = Take(2, 1), day = Take(2, 1), hour = Take(2, 0), minute = Take(2, 0), second = Take(2, 0);
        if (year < 1 || month is < 1 or > 12 || hour > 23 || minute > 59 || second > 60) return null;
        if (day < 1 || day > DateTime.DaysInMonth(year, month)) return null;

        var offset = TimeSpan.Zero;
        if (at < s.Length && s[at] is '+' or '-')
        {
            int sign = s[at++] == '-' ? -1 : 1;
            int zoneHours = Take(2, 0);
            if (at < s.Length && s[at] == '\'') at++;
            int zoneMinutes = Take(2, 0);
            if (zoneHours > 23 || zoneMinutes > 59) return null;
            offset = sign * new TimeSpan(zoneHours, zoneMinutes, 0);
        }
        if (offset.Duration() > TimeSpan.FromHours(14)) return null;
        return new DateTimeOffset(year, month, day, hour, minute, Math.Min(second, 59), offset);
    }

    /// <summary>"D:20261019213005+03'00'".</summary>
    public static string Format(DateTimeOffset date) =>
        "D:" + date.ToString("yyyyMMddHHmmss", CultureInfo.InvariantCulture) + Offset(date.Offset, "'") + "'";

    /// <summary>"2026-10-19T21:30:05+03:00".</summary>
    public static string FormatXmp(DateTimeOffset date) =>
        date.ToString("yyyy-MM-dd'T'HH:mm:ss", CultureInfo.InvariantCulture) + Offset(date.Offset, ":");

    /// <summary>Reads an XMP date; a date without a zone counts as UTC.</summary>
    public static DateTimeOffset? ParseXmp(string? text) =>
        DateTimeOffset.TryParse(text, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var date) ? date : null;

    private static string Offset(TimeSpan offset, string separator)
    {
        char sign = offset < TimeSpan.Zero ? '-' : '+';
        var magnitude = offset.Duration();
        return sign + magnitude.Hours.ToString("D2", CultureInfo.InvariantCulture) + separator
               + magnitude.Minutes.ToString("D2", CultureInfo.InvariantCulture);
    }
}
