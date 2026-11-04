namespace LazyPDF.Core;

public enum RedactionKind
{
    Email,
    Phone,
    UsSocialSecurity,
    TurkishId,
    Iban,
    PaymentCard,
    Date,
    Pattern,
    Word,
}

/// <summary>A hit of a finder: the mark it proposes and the text it found, for a list the user goes through before applying.</summary>
public sealed record RedactionMatch(RedactionMark Mark, string Text, RedactionKind Kind);

/// <summary>Finds what to redact by its shape, through <see cref="TextSearch"/>. Nothing is marked or removed.</summary>
public static class RedactionFinder
{
    private const string Months =
        "Ocak|Şubat|Mart|Nisan|Mayıs|Haziran|Temmuz|Ağustos|Eylül|Ekim|Kasım|Aralık|January|February|March|April|May|June|July|August|September|October|November|December";

    private sealed record Shape(string Pattern, bool MatchCase, Func<string, bool>? Check = null, int Shortest = 0);

    private static readonly Dictionary<RedactionKind, Shape> Shapes = new()
    {
        [RedactionKind.Email] = new(@"[\p{L}\p{N}._%+\-]+@[\p{L}\p{N}\-]+(?:\.[\p{L}\p{N}\-]+)*\.\p{L}{2,}", false),
        [RedactionKind.Phone] = new(@"(?<![\p{N}])(?:\+\d{1,3}[ .\-]?)?(?:\(\d{2,4}\)[ .\-]?)?\d{2,4}(?:[ .\-]\d{2,4}){1,4}(?![\p{N}])", false, IsPhone),
        [RedactionKind.UsSocialSecurity] = new(@"(?<!\d)\d{3}[- ]\d{2}[- ]\d{4}(?!\d)", false, IsSocialSecurity),
        [RedactionKind.TurkishId] = new(@"(?<!\d)[1-9]\d{10}(?!\d)", false, IsTurkishId),
        [RedactionKind.Iban] = new(@"(?<![A-Za-z0-9])[A-Z]{2}\d{2}(?: ?[A-Z0-9]{4}){2,7}(?: ?[A-Z0-9]{1,4})?(?![A-Za-z0-9])", true, IsIban, 15),
        [RedactionKind.PaymentCard] = new(@"(?<!\d)(?:\d[ -]?){12,18}\d(?!\d)", false, IsCard),
        [RedactionKind.Date] = new(@"(?<!\d)(?:\d{4}[-/.]\d{1,2}[-/.]\d{1,2}|\d{1,2}[-/.]\d{1,2}[-/.]\d{4}|\d{1,2}\s+(?:" + Months + @")\s+\d{4}|(?:" + Months + @")\s+\d{1,2},?\s+\d{4})(?!\d)", false, IsDate),
    };

    public static IReadOnlyList<RedactionMatch> Find(PdfDocument document, RedactionKind kind) => Find(new TextCache(document), kind);

    /// <summary>Everything of one built-in kind in the document. <see cref="RedactionKind.Pattern"/> and <see cref="RedactionKind.Word"/> have their own methods.</summary>
    public static IReadOnlyList<RedactionMatch> Find(TextCache cache, RedactionKind kind, CancellationToken cancel = default)
    {
        if (!Shapes.TryGetValue(kind, out var shape)) throw new ArgumentOutOfRangeException(nameof(kind));
        var found = new List<RedactionMatch>();
        foreach (var hit in TextSearch.Find(cache, shape.Pattern, new TextSearchOptions(MatchCase: shape.MatchCase, Regex: true), cancel: cancel))
        {
            if (shape.Check is null || shape.Check(hit.Text)) found.Add(new RedactionMatch(RedactionMark.FromMatch(hit), hit.Text, kind));
            else if (Narrow(cache.Get(hit.Page), hit, shape) is { } inner) found.Add(new RedactionMatch(RedactionMark.FromMatch(inner), inner.Text, kind));
        }
        return found;
    }

    /// <summary>Every hit of a regular expression (see <see cref="TextSearch"/> for how it reads the page). A bad pattern is an <see cref="ArgumentException"/>.</summary>
    public static IReadOnlyList<RedactionMatch> FindRegex(TextCache cache, string pattern, bool matchCase = false, CancellationToken cancel = default) =>
        [.. TextSearch.Find(cache, pattern, new TextSearchOptions(MatchCase: matchCase, Regex: true), cancel: cancel)
            .Select(h => new RedactionMatch(RedactionMark.FromMatch(h), h.Text, RedactionKind.Pattern))];

    public static IReadOnlyList<RedactionMatch> FindWords(TextCache cache, IEnumerable<string> words, bool wholeWord = true, bool matchCase = false, CancellationToken cancel = default)
    {
        var options = new TextSearchOptions(MatchCase: matchCase, WholeWord: wholeWord);
        return [.. words.Where(w => w.Length > 0).Distinct().SelectMany(w => TextSearch.Find(cache, w, options, cancel: cancel))
            .OrderBy(h => h.Page).ThenBy(h => h.Range.Start)
            .Select(h => new RedactionMatch(RedactionMark.FromMatch(h), h.Text, RedactionKind.Word))];
    }

    // An IBAN followed by an upper case word reads as a longer one; it is cut back to the longest
    // part, ending where a word ends, that passes its check.
    private static SearchMatch? Narrow(TextPage page, SearchMatch hit, Shape shape)
    {
        for (int end = hit.Range.End - 1; end - hit.Range.Start >= shape.Shortest && shape.Shortest > 0; end--)
        {
            if (!page.Chars[end].IsSpace) continue;
            var range = new TextRange(hit.Range.Start, end);
            string text = page.GetText(range);
            if (shape.Check!(text)) return new SearchMatch(hit.Page, range, text, page.Quads(range));
        }
        return null;
    }

    private static string Digits(string text) => string.Concat(text.Where(char.IsAsciiDigit));

    private static bool IsPhone(string text)
    {
        int digits = Digits(text).Length;
        return digits is >= 9 and <= 15;
    }

    private static bool IsSocialSecurity(string text)
    {
        string d = Digits(text);
        int area = int.Parse(d[..3]);
        return d.Length == 9 && area is not (0 or 666) && area < 900 && d[3..5] != "00" && d[5..] != "0000";
    }

    // 10th digit: ((odd digits sum * 7) - even digits sum) mod 10; 11th: sum of the first ten mod 10.
    private static bool IsTurkishId(string text)
    {
        if (text.Length != 11 || !text.All(char.IsAsciiDigit) || text[0] == '0') return false;
        int[] d = [.. text.Select(c => c - '0')];
        int odd = d[0] + d[2] + d[4] + d[6] + d[8], even = d[1] + d[3] + d[5] + d[7];
        return ((odd * 7 - even) % 10 + 10) % 10 == d[9] && d[..10].Sum() % 10 == d[10];
    }

    // ISO 13616: move the first four characters to the end, letters become 10 to 35, the number mod 97 is 1.
    private static bool IsIban(string text)
    {
        string s = text.Replace(" ", "");
        if (s.Length is < 15 or > 34 || !s.All(char.IsAsciiLetterOrDigit)) return false;
        int remainder = 0;
        foreach (char c in s[4..] + s[..4])
        {
            int value = char.IsAsciiDigit(c) ? c - '0' : char.ToUpperInvariant(c) - 'A' + 10;
            remainder = (value > 9 ? remainder * 100 + value : remainder * 10 + value) % 97;
        }
        return remainder == 1;
    }

    private static bool IsCard(string text)
    {
        string d = Digits(text);
        if (d.Length is < 13 or > 19) return false;
        int sum = 0;
        for (int i = 0; i < d.Length; i++)
        {
            int n = d[d.Length - 1 - i] - '0';
            if (i % 2 == 1 && (n *= 2) > 9) n -= 9;
            sum += n;
        }
        return sum % 10 == 0;
    }

    private static bool IsDate(string text)
    {
        var parts = text.Split(['-', '/', '.'], StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length != 3 || !parts.All(p => p.All(char.IsAsciiDigit))) return true;
        int[] n = [.. parts.Select(int.Parse)];
        if (parts[0].Length == 4) return n[1] is >= 1 and <= 12 && n[2] is >= 1 and <= 31;
        return (n[0] is >= 1 and <= 12 && n[1] is >= 1 and <= 31) || (n[0] is >= 1 and <= 31 && n[1] is >= 1 and <= 12);
    }
}
