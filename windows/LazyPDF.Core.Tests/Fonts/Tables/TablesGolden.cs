using System.Globalization;
using System.Text;
using LazyPDF.Core;

namespace LazyPDF.Core.Tests;

// Mirrored by Tests/LazyPDFKitTests/Fonts/Tables/TablesGolden.swift. One case per input line:
// "<codeBytes> pairs <code>=<UTF-16BE hex> ...", "<codeBytes> many <count>" (codes 0, 2, 4, ... with a
// letter and a CJK character, so every section is a bfchar) or "<codeBytes> spans <count>" (pairs of codes
// that do not join, so every section is a bfrange). The dump is the written stream after the line it came from.
internal static class TablesGolden
{
    private static string Text(string hex)
    {
        var sb = new StringBuilder();
        for (int i = 0; i < hex.Length; i += 4)
            sb.Append((char)int.Parse(hex.AsSpan(i, 4), NumberStyles.HexNumber, CultureInfo.InvariantCulture));
        return sb.ToString();
    }

    private static IEnumerable<KeyValuePair<int, string>> Pairs(string[] parts)
    {
        foreach (var part in parts.Skip(2))
        {
            int eq = part.IndexOf('=');
            int code = (int)uint.Parse(part.AsSpan(0, eq), NumberStyles.HexNumber, CultureInfo.InvariantCulture);
            yield return KeyValuePair.Create(code, Text(part[(eq + 1)..]));
        }
    }

    private static IEnumerable<KeyValuePair<int, string>> Many(int count)
    {
        for (int i = 0; i < count; i++)
            yield return KeyValuePair.Create(i * 2, "x" + (char)(0x4E00 + i * 3));
    }

    private static IEnumerable<KeyValuePair<int, string>> Spans(int count)
    {
        for (int i = 0; i < count; i++)
        {
            yield return KeyValuePair.Create(i * 0x10, ((char)(0x4E00 + i * 3)).ToString());
            yield return KeyValuePair.Create(i * 0x10 + 1, ((char)(0x4E00 + i * 3 + 1)).ToString());
        }
    }

    public static string ToUnicode(string input)
    {
        var sb = new StringBuilder();
        foreach (var line in input.Split('\n', StringSplitOptions.RemoveEmptyEntries))
        {
            var parts = line.Split(' ');
            int codeBytes = int.Parse(parts[0], CultureInfo.InvariantCulture);
            var map = parts[1] switch
            {
                "pairs" => Pairs(parts),
                "many" => Many(int.Parse(parts[2], CultureInfo.InvariantCulture)),
                _ => Spans(int.Parse(parts[2], CultureInfo.InvariantCulture)),
            };
            sb.Append("== ").Append(line).Append('\n');
            sb.Append(Encoding.ASCII.GetString(ToUnicodeCMap.Write(map, codeBytes)));
        }
        return sb.ToString();
    }
}
