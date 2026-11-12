using System.Globalization;
using System.Text;

namespace LazyPDF.Core.Office;

/// <summary>What a list paragraph gets in front of its text, and the level's own paragraph and run formatting.</summary>
internal sealed record NumberLabel(string Text, string Suffix, XmlElement? PPr, XmlElement? RPr, string? SymbolFont, double? TabStop);

/// <summary>
/// The lists of word/numbering.xml. Counters run in document order: a <c>w:num</c> that restarts a level counts for itself,
/// every other one counts with the nums of its <c>w:abstractNum</c>, as in Word.
/// </summary>
internal sealed class DocxNumbering
{
    private const int Levels = 9;
    private const int MaxDefinitions = 10000;
    private const int MaxValue = 32767;
    private const int MaxLabel = 64;

    private sealed class Level
    {
        public string Format = "decimal";
        public string Text = "";
        public int Start = 1;
        public int? Restart;
        public bool Legal;
        public string Suffix = "tab";
        public string? Style;
        public XmlElement? PPr, RPr;
    }

    private sealed class Num
    {
        public int Abstract;
        public Level?[] Replaced = new Level?[Levels];
        public int?[] Starts = new int?[Levels];
        public bool Restarts;
    }

    private sealed class Counters
    {
        public int[] Value = new int[Levels];
        public bool[] Seen = new bool[Levels];
    }

    private readonly Dictionary<int, Level?[]> _abstracts = [];
    private readonly Dictionary<int, Num> _nums = [];
    private readonly Dictionary<(bool, int), Counters> _counters = [];

    public static DocxNumbering Read(XmlElement? root)
    {
        var numbering = new DocxNumbering();
        if (root is null) return numbering;
        foreach (var a in root.Elements(DocxReader.W, "abstractNum"))
        {
            if (numbering._abstracts.Count >= MaxDefinitions) break;
            if (Id(a, "abstractNumId") is not { } id || numbering._abstracts.ContainsKey(id)) continue;
            var levels = new Level?[Levels];
            foreach (var l in a.Elements(DocxReader.W, "lvl"))
            {
                if (ReadLevel(l) is { } found) levels[found.Index] = found.Level;
            }
            numbering._abstracts[id] = levels;
        }
        foreach (var n in root.Elements(DocxReader.W, "num"))
        {
            if (numbering._nums.Count >= MaxDefinitions) break;
            if (Id(n, "numId") is not { } id || numbering._nums.ContainsKey(id)) continue;
            if (Id(n.Child(DocxReader.W, "abstractNumId") ?? n, "val") is not { } target) continue;
            var num = new Num { Abstract = target };
            foreach (var o in n.Elements(DocxReader.W, "lvlOverride"))
            {
                if (DocxReader.Number(o.Attribute(DocxReader.W, "ilvl")) is not { } at || at < 0 || at >= Levels) continue;
                int index = (int)at;
                if (DocxReader.Number(o.Child(DocxReader.W, "startOverride")?.Attribute(DocxReader.W, "val")) is { } start)
                {
                    num.Starts[index] = Clamp(start);
                    num.Restarts = true;
                }
                if (o.Child(DocxReader.W, "lvl") is { } replacement && ReadLevel(replacement) is { } found) num.Replaced[index] = found.Level;
            }
            numbering._nums[id] = num;
        }
        return numbering;
    }

    private static int? Id(XmlElement e, string name) =>
        DocxReader.Number(e.Attribute(DocxReader.W, name)) is { } v ? (int)Math.Clamp(v, int.MinValue, int.MaxValue) : null;

    private static int Clamp(double v) => (int)Math.Clamp(v, 0, MaxValue);

    private static (int Index, Level Level)? ReadLevel(XmlElement l)
    {
        if (DocxReader.Number(l.Attribute(DocxReader.W, "ilvl")) is not { } at || at < 0 || at >= Levels) return null;
        var level = new Level
        {
            Format = l.Child(DocxReader.W, "numFmt")?.Attribute(DocxReader.W, "val") ?? "decimal",
            Text = l.Child(DocxReader.W, "lvlText")?.Attribute(DocxReader.W, "val") ?? "",
            Start = DocxReader.Number(l.Child(DocxReader.W, "start")?.Attribute(DocxReader.W, "val")) is { } s ? Clamp(s) : 1,
            Restart = DocxReader.Number(l.Child(DocxReader.W, "lvlRestart")?.Attribute(DocxReader.W, "val")) is { } r ? Clamp(r) : null,
            Legal = l.Child(DocxReader.W, "isLgl") is { } legal && DocxReader.On(legal),
            Suffix = l.Child(DocxReader.W, "suff")?.Attribute(DocxReader.W, "val") ?? "tab",
            Style = l.Child(DocxReader.W, "pStyle")?.Attribute(DocxReader.W, "val"),
            PPr = l.Child(DocxReader.W, "pPr"),
            RPr = l.Child(DocxReader.W, "rPr"),
        };
        return ((int)at, level);
    }

    private Level? Find(Num num, int index) =>
        num.Replaced[index] ?? (_abstracts.TryGetValue(num.Abstract, out var levels) ? levels[index] : null);

    /// <summary>
    /// The label of the next item of list <paramref name="numId"/>, or null when there is no such list or level, so the
    /// paragraph stays plain. Without <paramref name="level"/> the level linked to the paragraph's style is used, else the first.
    /// </summary>
    public NumberLabel? Next(int numId, int? level, string? styleId)
    {
        if (!_nums.TryGetValue(numId, out var num) || !_abstracts.ContainsKey(num.Abstract)) return null;
        int at = level is { } given ? Math.Clamp(given, 0, Levels - 1) : Linked(num, styleId);
        if (Find(num, at) is not { } current) return null;

        var key = (num.Restarts, num.Restarts ? numId : num.Abstract);
        if (!_counters.TryGetValue(key, out var counters)) _counters[key] = counters = new Counters();
        for (int k = at + 1; k < Levels; k++)
        {
            // A level starts over after a higher one, or after the level lvlRestart names (1 based); 0 means never.
            int after = Find(num, k)?.Restart ?? k;
            if (after > at) counters.Seen[k] = false;
        }
        counters.Value[at] = counters.Seen[at] ? Math.Min(counters.Value[at] + 1, MaxValue) : StartOf(num, current, at);
        counters.Seen[at] = true;

        var text = new StringBuilder();
        string pattern = current.Text;
        for (int i = 0; i < pattern.Length && text.Length < MaxLabel; i++)
        {
            if (pattern[i] == '%' && i + 1 < pattern.Length && pattern[i + 1] is >= '1' and <= '9')
            {
                int referenced = pattern[++i] - '1';
                var other = Find(num, referenced);
                int value = counters.Seen[referenced] ? counters.Value[referenced] : StartOf(num, other, referenced);
                text.Append(Format(value, current.Legal && referenced != at ? "decimal" : other?.Format ?? "decimal"));
            }
            else text.Append(pattern[i]);
        }

        string result = text.Length > MaxLabel ? text.ToString(0, MaxLabel) : text.ToString();
        string? symbol = null;
        if (current.Format == "bullet")
        {
            symbol = SymbolFont(current.RPr);
            result = result.Length == 0 ? "•" : Bullet(result, symbol);
        }
        return new NumberLabel(result, current.Suffix, current.PPr, current.RPr, symbol, TabStop(current.PPr));
    }

    private int Linked(Num num, string? styleId)
    {
        if (styleId is null) return 0;
        for (int k = 0; k < Levels; k++)
        {
            if (Find(num, k)?.Style == styleId) return k;
        }
        return 0;
    }

    private static int StartOf(Num num, Level? level, int at) => num.Starts[at] ?? level?.Start ?? 1;

    // The first explicit stop of the level, in points; "clear" stops do not count.
    private static double? TabStop(XmlElement? pPr)
    {
        foreach (var tab in pPr?.Child(DocxReader.W, "tabs")?.Elements(DocxReader.W, "tab") ?? [])
        {
            string? kind = tab.Attribute(DocxReader.W, "val");
            if (kind is "clear" or "bar" or "num") continue;
            if (DocxReader.Number(tab.Attribute(DocxReader.W, "pos")) is { } pos) return Math.Clamp(pos / 20, 0, 1584);
        }
        return null;
    }

    private static string? SymbolFont(XmlElement? rPr)
    {
        string? name = rPr?.Child(DocxReader.W, "rFonts")?.Attribute(DocxReader.W, "ascii");
        return name is not null && (name.Equals("Symbol", StringComparison.OrdinalIgnoreCase) || name.Equals("Wingdings", StringComparison.OrdinalIgnoreCase)
            || name.Equals("Webdings", StringComparison.OrdinalIgnoreCase)) ? name : null;
    }

    // Symbol fonts keep their bullets in the private use area, which no text font draws.
    private static string Bullet(string text, string? symbolFont)
    {
        if (symbolFont is null) return text;
        var o = new StringBuilder();
        foreach (char c in text)
        {
            if ((c & 0xFF00) != 0xF000)
            {
                o.Append(c);
                continue;
            }
            o.Append((c & 0xFF) switch
            {
                0xA7 => '▪',
                0xD8 => '➢',
                0xFC => '✓',
                0x76 => '❖',
                _ => '•',
            });
        }
        return o.ToString();
    }

    internal static string Format(int value, string format)
    {
        switch (format)
        {
            case "lowerLetter": return Letters(value, false);
            case "upperLetter": return Letters(value, true);
            case "lowerRoman": return Roman(value, false);
            case "upperRoman": return Roman(value, true);
            case "decimalZero": return value is >= 0 and < 10 ? "0" + value.ToString(CultureInfo.InvariantCulture) : value.ToString(CultureInfo.InvariantCulture);
            case "none": return "";
            default: return value.ToString(CultureInfo.InvariantCulture);
        }
    }

    // a to z, then aa, bb, cc: the letter repeats, as in Word.
    private static string Letters(int value, bool upper)
    {
        if (value < 1) return value.ToString(CultureInfo.InvariantCulture);
        char letter = (char)((upper ? 'A' : 'a') + (value - 1) % 26);
        return new string(letter, (value - 1) / 26 + 1);
    }

    private static string Roman(int value, bool upper)
    {
        if (value is < 1 or > 3999) return value.ToString(CultureInfo.InvariantCulture);
        int[] values = [1000, 900, 500, 400, 100, 90, 50, 40, 10, 9, 5, 4, 1];
        string[] symbols = ["M", "CM", "D", "CD", "C", "XC", "L", "XL", "X", "IX", "V", "IV", "I"];
        var o = new StringBuilder();
        for (int i = 0; i < values.Length; i++)
        {
            while (value >= values[i])
            {
                o.Append(symbols[i]);
                value -= values[i];
            }
        }
        string roman = o.ToString();
        if (upper) return roman;
        var lower = roman.ToCharArray();
        for (int i = 0; i < lower.Length; i++) lower[i] = (char)(lower[i] + 32);
        return new string(lower);
    }
}
