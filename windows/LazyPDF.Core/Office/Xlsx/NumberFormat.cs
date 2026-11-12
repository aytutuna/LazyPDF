using System.Globalization;
using System.Text;

namespace LazyPDF.Core.Office;

/// <summary>A cell value as text, and the colour the format asked for (0xRRGGBB), if any.</summary>
internal readonly record struct FormatResult(string Text, int? Color);

/// <summary>
/// An Excel number format code, parsed once and applied to values with the invariant (en-US) separators and names. Digits come
/// from the shortest decimal form of the double cut to 15 significant digits, as Excel does, and are rounded as decimal text, so
/// the C# and Swift engines print the same characters. Locale tags are read and dropped; only a currency symbol in [$...] is kept.
/// </summary>
internal sealed class NumberFormat
{
    private enum Kind { Literal, Digit, Point, Group, Percent, Exp, Slash, At, General, Field, Elapsed, AmPm, SubSecond }

    private sealed record Token(Kind Kind, string Text = "", char Ch = ' ', int Count = 0);

    private readonly record struct Condition(string Op, double Value)
    {
        public bool Test(double v) => Op switch
        {
            "<" => v < Value, "<=" => v <= Value, ">" => v > Value, ">=" => v >= Value, "=" => v == Value, _ => v != Value,
        };
    }

    private sealed class Section
    {
        public List<Token> Tokens { get; } = [];
        public int? Color;
        public Condition? Cond;
        public bool IsDate;
        public bool HasAt;
    }

    private const string Hashes = "########";
    private static readonly string[] Months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];
    private static readonly string[] Days = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];

    private static readonly Dictionary<string, int> Colors = new()
    {
        ["black"] = 0x000000, ["blue"] = 0x0000FF, ["cyan"] = 0x00FFFF, ["green"] = 0x00FF00,
        ["magenta"] = 0xFF00FF, ["red"] = 0xFF0000, ["white"] = 0xFFFFFF, ["yellow"] = 0xFFFF00,
    };

    private static readonly int[] IndexedColors = [0x000000, 0xFFFFFF, 0xFF0000, 0x00FF00, 0x0000FF, 0xFFFF00, 0xFF00FF, 0x00FFFF];

    private static readonly Dictionary<int, string> BuiltIn = new()
    {
        [0] = "General", [1] = "0", [2] = "0.00", [3] = "#,##0", [4] = "#,##0.00",
        [5] = "\"$\"#,##0_);(\"$\"#,##0)", [6] = "\"$\"#,##0_);[Red](\"$\"#,##0)",
        [7] = "\"$\"#,##0.00_);(\"$\"#,##0.00)", [8] = "\"$\"#,##0.00_);[Red](\"$\"#,##0.00)",
        [9] = "0%", [10] = "0.00%", [11] = "0.00E+00", [12] = "# ?/?", [13] = "# ??/??",
        [14] = "m/d/yyyy", [15] = "d-mmm-yy", [16] = "d-mmm", [17] = "mmm-yy",
        [18] = "h:mm AM/PM", [19] = "h:mm:ss AM/PM", [20] = "h:mm", [21] = "h:mm:ss", [22] = "m/d/yyyy h:mm",
        [37] = "#,##0_);(#,##0)", [38] = "#,##0_);[Red](#,##0)", [39] = "#,##0.00_);(#,##0.00)", [40] = "#,##0.00_);[Red](#,##0.00)",
        [41] = "_(* #,##0_);_(* \\(#,##0\\);_(* \"-\"_);_(@_)",
        [42] = "_(\"$\"* #,##0_);_(\"$\"* \\(#,##0\\);_(\"$\"* \"-\"_);_(@_)",
        [43] = "_(* #,##0.00_);_(* \\(#,##0.00\\);_(* \"-\"??_);_(@_)",
        [44] = "_(\"$\"* #,##0.00_);_(\"$\"* \\(#,##0.00\\);_(\"$\"* \"-\"??_);_(@_)",
        [45] = "mm:ss", [46] = "[h]:mm:ss", [47] = "mm:ss.0", [48] = "##0.0E+0", [49] = "@",
    };

    public static readonly NumberFormat General = Parse("General");

    private readonly List<Section> _sections = [];

    /// <summary>The code of a built-in format id (0 to 49); null for the ids that depend on the locale and for ids past 49.</summary>
    public static string? BuiltInCode(int id) => BuiltIn.GetValueOrDefault(id);

    public static NumberFormat Parse(string code)
    {
        var format = new NumberFormat();
        foreach (string part in Split(code)) format._sections.Add(ParseSection(part));
        return format;
    }

    private static char Fold(char c) => c is >= 'A' and <= 'Z' ? (char)(c + 32) : c;

    private static string Lower(string s)
    {
        var o = new StringBuilder(s.Length);
        foreach (char c in s) o.Append(Fold(c));
        return o.ToString();
    }

    private static List<string> Split(string code)
    {
        var parts = new List<string>();
        var current = new StringBuilder();
        bool quoted = false, bracket = false;
        for (int i = 0; i < code.Length; i++)
        {
            char c = code[i];
            if (quoted) quoted = c != '"';
            else if (bracket) bracket = c != ']';
            else if (c == '"') quoted = true;
            else if (c == '[') bracket = true;
            else if ((c == '\\' || c == '_' || c == '*') && i + 1 < code.Length)
            {
                current.Append(c).Append(code[++i]);
                continue;
            }
            else if (c == ';')
            {
                parts.Add(current.ToString());
                current.Clear();
                continue;
            }
            current.Append(c);
        }
        parts.Add(current.ToString());
        if (parts.Count > 4) parts.RemoveRange(4, parts.Count - 4);
        return parts;
    }

    private static bool IsElapsed(string content)
    {
        string l = Lower(content);
        return l is "h" or "hh" or "m" or "mm" or "s" or "ss";
    }

    private static bool IsDateSection(string s)
    {
        for (int i = 0; i < s.Length; i++)
        {
            char c = s[i];
            if (c == '"')
            {
                int end = s.IndexOf('"', i + 1);
                i = end < 0 ? s.Length : end;
            }
            else if (c == '[')
            {
                int end = s.IndexOf(']', i + 1);
                if (end < 0) return false;
                if (IsElapsed(s[(i + 1)..end])) return true;
                i = end;
            }
            else if (c is '\\' or '_' or '*') i++;
            else if (Lower(s.Substring(i, Math.Min(7, s.Length - i))) == "general") i += 6;
            else if (c is 'y' or 'Y' or 'd' or 'D' or 'h' or 'H' or 's' or 'S' or 'm' or 'M') return true;
        }
        return false;
    }

    private static Section ParseSection(string s)
    {
        var section = new Section { IsDate = IsDateSection(s) };
        var tokens = section.Tokens;
        bool pointSeen = false;
        int i = 0;
        while (i < s.Length)
        {
            char c = s[i];
            if (c == '"')
            {
                int end = s.IndexOf('"', i + 1);
                if (end < 0) end = s.Length;
                tokens.Add(new Token(Kind.Literal, s[(i + 1)..Math.Min(end, s.Length)]));
                i = end + 1;
            }
            else if (c == '\\')
            {
                if (i + 1 < s.Length) tokens.Add(new Token(Kind.Literal, s[i + 1].ToString()));
                i += 2;
            }
            else if (c == '_')
            {
                tokens.Add(new Token(Kind.Literal, " "));
                i += 2;
            }
            else if (c == '*')
            {
                i += 2;
            }
            else if (c == '[')
            {
                int end = s.IndexOf(']', i + 1);
                if (end < 0)
                {
                    tokens.Add(new Token(Kind.Literal, "["));
                    i++;
                    continue;
                }
                Bracket(section, s[(i + 1)..end]);
                i = end + 1;
            }
            else if (section.IsDate) i = DateToken(section, s, i);
            else i = NumberToken(section, s, i, ref pointSeen);
        }
        return section;
    }

    private static void Bracket(Section section, string content)
    {
        if (content.Length == 0) return;
        char first = content[0];
        if (first is '<' or '>' or '=')
        {
            int n = content.Length > 1 && (content[1] == '=' || (first == '<' && content[1] == '>')) ? 2 : 1;
            if (Number(content[n..]) is { } value) section.Cond = new Condition(content[..n], value);
            return;
        }
        string l = Lower(content);
        if (Colors.TryGetValue(l, out int rgb)) section.Color = rgb;
        else if (l.StartsWith("color", StringComparison.Ordinal) && int.TryParse(l[5..], NumberStyles.None, CultureInfo.InvariantCulture, out int n) && n is >= 1 and <= 8) section.Color = IndexedColors[n - 1];
        else if (first == '$')
        {
            int dash = content.IndexOf('-');
            string symbol = dash < 0 ? content[1..] : content[1..dash];
            if (symbol.Length > 0) section.Tokens.Add(new Token(Kind.Literal, symbol));
        }
        else if (IsElapsed(content)) section.Tokens.Add(new Token(Kind.Elapsed, Ch: l[0], Count: l.Length));
    }

    private static int Run(string s, int i)
    {
        int j = i;
        while (j < s.Length && Fold(s[j]) == Fold(s[i])) j++;
        return j - i;
    }

    private static int DateToken(Section section, string s, int i)
    {
        char c = s[i];
        char l = Fold(c);
        var tokens = section.Tokens;
        if (l is 'y' or 'm' or 'd' or 'h' or 's')
        {
            int n = Run(s, i);
            tokens.Add(new Token(Kind.Field, Ch: l, Count: n));
            return i + n;
        }
        if (l == 'a')
        {
            if (i + 5 <= s.Length && Lower(s.Substring(i, 5)) == "am/pm")
            {
                tokens.Add(new Token(Kind.AmPm, s.Substring(i, 5)));
                return i + 5;
            }
            if (i + 3 <= s.Length && Lower(s.Substring(i, 3)) == "a/p")
            {
                tokens.Add(new Token(Kind.AmPm, s.Substring(i, 3)));
                return i + 3;
            }
        }
        if (c == '.' && tokens.Count > 0 && tokens[^1] is { Ch: 's', Kind: Kind.Field or Kind.Elapsed } && i + 1 < s.Length && s[i + 1] == '0')
        {
            int n = 1;
            while (i + 1 + n < s.Length && s[i + 1 + n] == '0') n++;
            tokens.Add(new Token(Kind.SubSecond, Count: Math.Min(n, 3)));
            return i + 1 + n;
        }
        tokens.Add(new Token(Kind.Literal, c.ToString()));
        return i + 1;
    }

    private static int NumberToken(Section section, string s, int i, ref bool pointSeen)
    {
        char c = s[i];
        var tokens = section.Tokens;
        switch (c)
        {
            case '0' or '#' or '?':
                tokens.Add(new Token(Kind.Digit, Ch: c));
                return i + 1;
            case '.' when !pointSeen && !tokens.Any(t => t.Kind == Kind.Exp):
                pointSeen = true;
                tokens.Add(new Token(Kind.Point));
                return i + 1;
            case ',':
                tokens.Add(new Token(Kind.Group));
                return i + 1;
            case '%':
                tokens.Add(new Token(Kind.Percent));
                return i + 1;
            case 'E' or 'e' when i + 1 < s.Length && s[i + 1] is '+' or '-':
                tokens.Add(new Token(Kind.Exp, Ch: s[i + 1]));
                return i + 2;
            case '/':
                tokens.Add(new Token(Kind.Slash));
                return i + 1;
            case '@':
                section.HasAt = true;
                tokens.Add(new Token(Kind.At));
                return i + 1;
        }
        if ((c == 'G' || c == 'g') && i + 7 <= s.Length && Lower(s.Substring(i, 7)) == "general")
        {
            tokens.Add(new Token(Kind.General));
            return i + 7;
        }
        tokens.Add(new Token(Kind.Literal, c.ToString()));
        return i + 1;
    }

    private static double? Number(string text)
    {
        if (text.Length == 0 || text.Any(c => !(c is >= '0' and <= '9' or '+' or '-' or '.' or 'e' or 'E'))) return null;
        return double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out double v) && double.IsFinite(v) ? v : null;
    }

    // Applying a format

    public FormatResult Format(double v, bool date1904)
    {
        int numeric = Math.Min(_sections.Count, 3);
        if (_sections.Count < 4 && _sections[^1].HasAt) numeric = Math.Max(_sections.Count - 1, 1);
        int at = numeric - 1;
        for (int i = 0; i < numeric; i++)
        {
            if (Matches(i, numeric, v)) { at = i; break; }
        }
        var section = _sections[at];
        if (section.Tokens.Count == 0) return new FormatResult("", section.Color);
        bool negative = v < 0;
        bool dropMinus = negative && at == 1 && section.Cond is null;
        if (section.IsDate) return new FormatResult(Date(section, v, date1904), section.Color);
        string text = Digits(section, Math.Abs(v));
        return new FormatResult(negative && !dropMinus ? "-" + text : text, section.Color);
    }

    private bool Matches(int i, int numeric, double v)
    {
        var s = _sections[i];
        if (s.Cond is { } c) return c.Test(v);
        if (numeric == 1) return true;
        if (i == 0) return numeric == 2 && _sections[1].Cond is null ? v >= 0 : v > 0;
        if (i == 1) return numeric == 2 || v < 0;
        return true;
    }

    /// <summary>A text value through the text section, if the format has one; else the text as it is.</summary>
    public FormatResult FormatText(string text)
    {
        Section? section = _sections.LastOrDefault(s => s.HasAt) ?? (_sections.Count == 4 ? _sections[3] : null);
        if (section is null) return new FormatResult(text, null);
        var shown = section.Tokens.Where(t => t.Kind is Kind.At or Kind.Literal).ToList();
        if (shown.Count == 1 && shown[0].Kind == Kind.At) return new FormatResult(text, section.Color);
        var o = new StringBuilder();
        foreach (var t in section.Tokens)
        {
            if (t.Kind == Kind.At) o.Append(text);
            else if (t.Kind == Kind.Literal) o.Append(t.Text);
        }
        return new FormatResult(o.ToString(), section.Color);
    }

    // Decimal digits

    private sealed class Dec
    {
        /// <summary>No leading or trailing zeros; empty is zero.</summary>
        public string Digits = "";
        /// <summary>The value is 0.Digits times ten to the Point.</summary>
        public int Point;

        public static Dec From(double v)
        {
            string s = Math.Abs(v).ToString("R", CultureInfo.InvariantCulture);
            int exp = 0;
            int e = s.IndexOfAny(['E', 'e']);
            if (e >= 0)
            {
                exp = int.Parse(s[(e + 1)..], CultureInfo.InvariantCulture);
                s = s[..e];
            }
            int dot = s.IndexOf('.');
            string digits = dot < 0 ? s : s[..dot] + s[(dot + 1)..];
            int point = (dot < 0 ? s.Length : dot) + exp;
            int lead = 0;
            while (lead < digits.Length && digits[lead] == '0') lead++;
            digits = digits[lead..].TrimEnd('0');
            var d = new Dec { Digits = digits, Point = digits.Length == 0 ? 0 : point - lead };
            d.RoundAt(15);
            return d;
        }

        public void RoundAt(int cut)
        {
            if (cut >= Digits.Length) return;
            if (cut < 0)
            {
                Digits = "";
                Point = 0;
                return;
            }
            var kept = Digits[..cut].ToCharArray();
            if (Digits[cut] >= '5')
            {
                int i = cut - 1;
                while (i >= 0 && kept[i] == '9') kept[i--] = '0';
                if (i >= 0) kept[i]++;
                else
                {
                    Digits = ("1" + new string(kept)).TrimEnd('0');
                    Point++;
                    return;
                }
            }
            Digits = new string(kept).TrimEnd('0');
            if (Digits.Length == 0) Point = 0;
        }

        public string IntDigits => Point <= 0 ? "" : Digits.Length >= Point ? Digits[..Point] : Digits.PadRight(Point, '0');

        public string Fraction(int count)
        {
            var o = new StringBuilder();
            for (int j = 0; j < count; j++)
            {
                int at = Point + j;
                o.Append(at >= 0 && at < Digits.Length ? Digits[at] : '0');
            }
            return o.ToString();
        }
    }

    /// <summary>Excel's General for a number: up to 11 significant digits, then E notation.</summary>
    public static string GeneralText(double v)
    {
        if (v == 0) return "0";
        string sign = v < 0 ? "-" : "";
        var d = Dec.From(v);
        d.RoundAt(11);
        int e = d.Point - 1;
        if (e >= 11 || e < -4)
        {
            d = Dec.From(v);
            d.RoundAt(6);
            e = d.Point - 1;
            string mantissa = d.Digits.Length > 1 ? d.Digits[..1] + "." + d.Digits[1..] : d.Digits;
            return sign + mantissa + "E" + (e < 0 ? "-" : "+") + Math.Abs(e).ToString("00", CultureInfo.InvariantCulture);
        }
        string plain = d.Point <= 0 ? "0." + new string('0', -d.Point) + d.Digits
            : d.Digits.Length <= d.Point ? d.Digits.PadRight(d.Point, '0')
            : d.Digits[..d.Point] + "." + d.Digits[d.Point..];
        return sign + plain;
    }

    /// <summary>
    /// The pieces the integer digits make in a row of placeholders: from the right, a digit each; past the digits a 0 shows 0, a ?
    /// a space, a # nothing; digits beyond the placeholders go into the first one. A comma comes before every third digit.
    /// </summary>
    private static string[] Place(List<char> placeholders, string digits, bool grouping)
    {
        int count = placeholders.Count, n = digits.Length;
        int slots = Math.Max(n, count);
        char? Slot(int k) => k < n ? digits[n - 1 - k] : k < count ? placeholders[count - 1 - k] switch { '0' => '0', '?' => ' ', _ => null } : null;
        string Piece(int k)
        {
            char? c = Slot(k);
            string comma = grouping && (k + 1) % 3 == 0 && k + 1 < slots && Slot(k + 1) is { } up && up != ' ' ? "," : "";
            return comma + (c?.ToString() ?? "");
        }
        var pieces = new string[count];
        for (int p = 1; p < count; p++) pieces[p] = Piece(count - 1 - p);
        if (count > 0)
        {
            var first = new StringBuilder();
            for (int k = slots - 1; k >= count - 1; k--) first.Append(Piece(k));
            pieces[0] = first.ToString();
        }
        return pieces;
    }

    private static string Digits(Section section, double v)
    {
        var tokens = section.Tokens;
        int slash = tokens.FindIndex(t => t.Kind == Kind.Slash);
        if (slash > 0 && tokens[slash - 1].Kind == Kind.Digit && slash + 1 < tokens.Count && (tokens[slash + 1].Kind == Kind.Digit || IsDigitLiteral(tokens[slash + 1])))
        {
            return Fraction(section, v, slash);
        }
        int point = tokens.FindIndex(t => t.Kind == Kind.Point);
        int exp = tokens.FindIndex(t => t.Kind == Kind.Exp);
        int intEnd = point >= 0 ? point : exp >= 0 ? exp : tokens.Count;
        int numberEnd = exp >= 0 ? exp : tokens.Count;

        bool grouping = false;
        int scale = 0;
        var consumed = new bool[tokens.Count];
        for (int i = 0; i < tokens.Count; i++)
        {
            if (tokens[i].Kind != Kind.Group) continue;
            bool before = tokens.Take(i).Any(t => t.Kind == Kind.Digit);
            int limit = i < intEnd ? intEnd : numberEnd;
            bool after = tokens.Skip(i + 1).Take(Math.Max(0, limit - i - 1)).Any(t => t.Kind == Kind.Digit);
            if (before && after && i < intEnd) { grouping = true; consumed[i] = true; }
            else if (before && !after) { scale++; consumed[i] = true; }
        }
        int percents = tokens.Count(t => t.Kind == Kind.Percent);

        var number = Dec.From(v);
        number.Point += 2 * percents - 3 * scale;

        var intHolders = new List<char>();
        var fracHolders = new List<char>();
        int expDigits = 0;
        for (int i = 0; i < tokens.Count; i++)
        {
            if (tokens[i].Kind != Kind.Digit) continue;
            if (exp >= 0 && i > exp) expDigits++;
            else if (point >= 0 && i > point) fracHolders.Add(tokens[i].Ch);
            else intHolders.Add(tokens[i].Ch);
        }

        long exponent = 0;
        if (exp >= 0)
        {
            int width = Math.Max(1, intHolders.Count);
            if (number.Digits.Length > 0)
            {
                int e = number.Point - 1;
                exponent = (long)(e >= 0 ? e / width : -((-e + width - 1) / width)) * width;
            }
            number.Point -= (int)exponent;
            number.RoundAt(number.Point + fracHolders.Count);
            if (number.Digits.Length > 0 && number.Point > width)
            {
                exponent += width;
                number.Point -= width;
            }
        }
        else
        {
            number.RoundAt(number.Point + fracHolders.Count);
        }

        string[] intPieces = Place(intHolders, number.IntDigits, grouping);
        string fraction = number.Fraction(fracHolders.Count);
        int lastShown = -1;
        for (int j = 0; j < fracHolders.Count; j++)
        {
            if (fraction[j] != '0' || fracHolders[j] == '0') lastShown = j;
        }

        var o = new StringBuilder();
        int ip = 0, fp = 0, xp = 0;
        for (int i = 0; i < tokens.Count; i++)
        {
            var t = tokens[i];
            switch (t.Kind)
            {
                case Kind.Digit when exp >= 0 && i > exp:
                    if (xp++ == 0)
                    {
                        string digits = Math.Abs(exponent).ToString(CultureInfo.InvariantCulture);
                        o.Append(digits.PadLeft(expDigits, '0'));
                    }
                    break;
                case Kind.Digit when point >= 0 && i > point:
                    o.Append(fp > lastShown ? (fracHolders[fp] == '?' ? " " : "") : fraction[fp].ToString());
                    fp++;
                    break;
                case Kind.Digit:
                    o.Append(intPieces[ip++]);
                    break;
                case Kind.Point:
                    if (intHolders.Count == 0 && number.IntDigits.Length > 0) o.Append(number.IntDigits);
                    o.Append('.');
                    break;
                case Kind.Group:
                    if (!consumed[i]) o.Append(',');
                    break;
                case Kind.Percent:
                    o.Append('%');
                    break;
                case Kind.Exp:
                    o.Append('E').Append(exponent < 0 ? "-" : t.Ch == '+' ? "+" : "");
                    break;
                case Kind.General:
                case Kind.At:
                    o.Append(GeneralText(v));
                    break;
                case Kind.Literal:
                    o.Append(t.Text);
                    break;
            }
        }
        return o.ToString();
    }

    private static bool IsDigitLiteral(Token t) => t.Kind == Kind.Literal && t.Text.Length > 0 && t.Text.All(c => c is >= '0' and <= '9');

    // Excel's tenths and hundredths codes ("# ?/10") put a 0 in the fixed denominator, which tokenizes as a Digit.
    private static bool IsFixedDenominator(Token t) => IsDigitLiteral(t) || (t.Kind == Kind.Digit && t.Ch == '0');

    private static string DenominatorText(Token t) => t.Kind == Kind.Digit ? t.Ch.ToString() : t.Text;

    private static string Fraction(Section section, double v, int slash)
    {
        var tokens = section.Tokens;
        int numStart = slash;
        while (numStart > 0 && tokens[numStart - 1].Kind == Kind.Digit) numStart--;
        int denEnd = slash + 1;
        bool fixedDenominator = IsDigitLiteral(tokens[slash + 1]);
        if (fixedDenominator) while (denEnd < tokens.Count && IsFixedDenominator(tokens[denEnd])) denEnd++;
        else while (denEnd < tokens.Count && tokens[denEnd].Kind == Kind.Digit) denEnd++;

        var wholeHolders = new List<char>();
        for (int i = 0; i < numStart; i++)
        {
            if (tokens[i].Kind == Kind.Digit) wholeHolders.Add(tokens[i].Ch);
        }
        var numHolders = tokens.Skip(numStart).Take(slash - numStart).Select(t => t.Ch).ToList();
        int denCount = denEnd - slash - 1;

        bool hasWhole = wholeHolders.Count > 0;
        double whole = hasWhole ? Math.Floor(v) : 0;
        double rest = v - whole;
        double n, d;
        if (fixedDenominator)
        {
            d = double.Parse(string.Concat(tokens.Skip(slash + 1).Take(denCount).Select(DenominatorText)), CultureInfo.InvariantCulture);
            if (d < 1) d = 1;
            n = Math.Floor(rest * d + 0.5);
        }
        else
        {
            double max = 1;
            for (int i = 0; i < Math.Min(denCount, 4); i++) max *= 10;
            max -= 1;
            d = 1;
            n = Math.Floor(rest + 0.5);
            double best = Math.Abs(rest - n);
            for (double c = 2; c <= max && best > 0; c++)
            {
                double cn = Math.Floor(rest * c + 0.5);
                double error = Math.Abs(rest - cn / c);
                if (error < best)
                {
                    best = error;
                    d = c;
                    n = cn;
                }
            }
        }
        if (hasWhole && n >= d)
        {
            whole += Math.Floor(n / d);
            n -= Math.Floor(n / d) * d;
        }
        bool blank = hasWhole && n == 0;

        string[] wholePieces = Place(wholeHolders, Dec.From(whole).IntDigits, false);
        string[] numPieces = Place(numHolders, n == 0 ? "0" : Dec.From(n).IntDigits, false);
        string denominator = Dec.From(d).IntDigits;

        var o = new StringBuilder();
        int wp = 0, np = 0, dp = 0;
        for (int i = 0; i < tokens.Count; i++)
        {
            var t = tokens[i];
            if (i >= numStart && i < slash)
            {
                o.Append(blank ? " " : numPieces[np]);
                np++;
            }
            else if (i == slash)
            {
                o.Append(blank ? " " : "/");
            }
            else if (i > slash && i < denEnd)
            {
                if (blank) o.Append(' ', t.Kind == Kind.Digit ? 1 : t.Text.Length);
                else if (fixedDenominator) o.Append(DenominatorText(t));
                else
                {
                    o.Append(dp < denominator.Length ? denominator[dp].ToString() : tokens[i].Ch == '?' ? " " : "");
                    dp++;
                }
            }
            else if (t.Kind == Kind.Digit)
            {
                o.Append(wholePieces[wp++]);
            }
            else if (t.Kind == Kind.Literal)
            {
                o.Append(t.Text);
            }
            else if (t.Kind == Kind.Percent)
            {
                o.Append('%');
            }
        }
        return o.ToString();
    }

    // Dates and times

    private static (int Year, int Month, int Day) Civil(long unixDays)
    {
        long z = unixDays + 719468;
        long era = (z >= 0 ? z : z - 146096) / 146097;
        long doe = z - era * 146097;
        long yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
        long doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        long mp = (5 * doy + 2) / 153;
        int day = (int)(doy - (153 * mp + 2) / 5 + 1);
        int month = (int)(mp < 10 ? mp + 3 : mp - 9);
        return ((int)(yoe + era * 400 + (month <= 2 ? 1 : 0)), month, day);
    }

    private static string Date(Section section, double v, bool date1904)
    {
        if (v < 0 || v >= 1e8) return Hashes;
        var tokens = section.Tokens;
        int sub = tokens.FirstOrDefault(t => t.Kind == Kind.SubSecond)?.Count ?? 0;
        long scale = sub == 0 ? 1 : sub == 1 ? 10 : sub == 2 ? 100 : 1000;
        long perDay = 86400 * scale;
        long total = (long)Math.Floor(v * perDay + 0.5);
        long days = total / perDay;
        long rem = total % perDay;
        long seconds = rem / scale;
        int hour = (int)(seconds / 3600), minute = (int)(seconds % 3600 / 60), second = (int)(seconds % 60);

        int year = 0, month = 0, day = 0, weekday;
        if (date1904)
        {
            (year, month, day) = Civil(days - 24107);
            weekday = (int)((days + 5) % 7);
        }
        else
        {
            if (days == 0) (year, month, day) = (1900, 1, 0);
            else if (days == 60) (year, month, day) = (1900, 2, 29);
            else (year, month, day) = Civil(days < 60 ? days - 25568 : days - 25569);
            weekday = (int)(((days - 1) % 7 + 7) % 7);
        }
        if (year > 9999) return Hashes;

        bool twelve = tokens.Any(t => t.Kind == Kind.AmPm);
        var o = new StringBuilder();
        for (int i = 0; i < tokens.Count; i++)
        {
            var t = tokens[i];
            switch (t.Kind)
            {
                case Kind.Literal:
                    o.Append(t.Text);
                    break;
                case Kind.AmPm:
                    {
                        bool pm = hour >= 12;
                        string word = t.Text.Length == 5 ? (pm ? "PM" : "AM") : (pm ? "P" : "A");
                        o.Append(t.Text[0] is >= 'a' and <= 'z' ? Lower(word) : word);
                        break;
                    }
                case Kind.SubSecond:
                    o.Append('.').Append((rem % scale).ToString(CultureInfo.InvariantCulture).PadLeft(sub, '0'));
                    break;
                case Kind.Elapsed:
                    {
                        long value = t.Ch == 'h' ? days * 24 + hour : t.Ch == 'm' ? days * 1440 + hour * 60 + minute : days * 86400 + seconds;
                        o.Append(value.ToString(CultureInfo.InvariantCulture).PadLeft(t.Count, '0'));
                        break;
                    }
                case Kind.Field:
                    Field(o, t, i, tokens, year, month, day, weekday, hour, minute, second, twelve);
                    break;
            }
        }
        return o.ToString();
    }

    private static bool IsMinute(List<Token> tokens, int at)
    {
        for (int i = at - 1; i >= 0; i--)
        {
            if (tokens[i].Kind is Kind.Field or Kind.Elapsed) return tokens[i].Ch == 'h';
        }
        for (int i = at + 1; i < tokens.Count; i++)
        {
            if (tokens[i].Kind is Kind.Field or Kind.Elapsed) return tokens[i].Ch == 's';
        }
        return false;
    }

    private static void Field(StringBuilder o, Token t, int at, List<Token> tokens, int year, int month, int day, int weekday, int hour, int minute, int second, bool twelve)
    {
        string Two(int n) => n.ToString("00", CultureInfo.InvariantCulture);
        switch (t.Ch)
        {
            case 'y':
                o.Append(t.Count <= 2 ? Two(year % 100) : year.ToString("0000", CultureInfo.InvariantCulture));
                break;
            case 'm' when IsMinute(tokens, at):
                o.Append(t.Count == 1 ? minute.ToString(CultureInfo.InvariantCulture) : Two(minute));
                break;
            case 'm':
                string name = month >= 1 ? Months[month - 1] : "January";
                o.Append(t.Count switch
                {
                    1 => month.ToString(CultureInfo.InvariantCulture),
                    2 => Two(month),
                    3 => name[..3],
                    4 => name,
                    _ => name[..1],
                });
                break;
            case 'd':
                o.Append(t.Count switch
                {
                    1 => day.ToString(CultureInfo.InvariantCulture),
                    2 => Two(day),
                    3 => Days[weekday][..3],
                    _ => Days[weekday],
                });
                break;
            case 'h':
                int h = twelve ? (hour % 12 == 0 ? 12 : hour % 12) : hour;
                o.Append(t.Count == 1 ? h.ToString(CultureInfo.InvariantCulture) : Two(h));
                break;
            case 's':
                o.Append(t.Count == 1 ? second.ToString(CultureInfo.InvariantCulture) : Two(second));
                break;
        }
    }
}
