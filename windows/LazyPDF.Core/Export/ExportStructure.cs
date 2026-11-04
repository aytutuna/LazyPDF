using System.Text.RegularExpressions;

namespace LazyPDF.Core;

/// <summary>Document-wide decisions: which size is the body, which paragraphs are headings, which items form which list, which rows are running heads.</summary>
internal static class ExportStructure
{
    private const double BandFraction = 0.08;

    private static readonly Regex PageNumber = new(@"^[\-–—\s]*((page|sayfa|seite|página|pagina|strana)\s*)?\d{1,5}(\s*(of|/|von|de|di)\s*\d{1,5})?[\-–—\s]*$", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    private static readonly Regex Digits = new(@"\d+");

    public static double BodySize(IEnumerable<ExPara> paragraphs)
    {
        var weights = new Dictionary<double, int>();
        foreach (var p in paragraphs) weights[p.Size] = weights.GetValueOrDefault(p.Size) + p.Text.Length;
        return weights.Count == 0 ? 11 : weights.MaxBy(w => w.Value).Key;
    }

    public static void Headings(IReadOnlyList<ExPara> paragraphs, double body)
    {
        var big = paragraphs.Where(p => p.Item is null && p.Size >= body * 1.15 && p.Lines <= 3 && p.Text.Length <= 200).ToList();
        var sizes = new List<double>();
        foreach (double size in big.Select(p => p.Size).Distinct().OrderByDescending(s => s))
        {
            if (sizes.Count == 0 || sizes[^1] - size > 0.6) sizes.Add(size);
        }
        foreach (var p in big) p.Heading = Math.Min(6, sizes.FindIndex(s => s - p.Size <= 0.6) + 1);

        // Bold on a line of its own at body size, over a paragraph of text: a heading one level under the sized ones.
        for (int i = 0; i + 1 < paragraphs.Count; i++)
        {
            var p = paragraphs[i];
            var next = paragraphs[i + 1];
            if (p.Heading != 0 || p.Item is not null || !p.AllBold || p.Lines != 1 || p.Text.Length > 80 || p.Size < body * 0.9 || p.Size >= body * 1.15) continue;
            if (".,;:".Contains(p.Text[^1]) || next.Item is not null || next.AllBold || next.Text.Length < 40 || next.Size > body * 1.15) continue;
            p.Heading = Math.Min(6, sizes.Count + 1);
        }
    }

    /// <summary>Runs of items in a row are a list; a new number sequence or a change between bullets and numbers starts another.</summary>
    public static Dictionary<ExPara, ExportListItem> Lists(IEnumerable<object> flow)
    {
        var result = new Dictionary<ExPara, ExportListItem>();
        var lists = new List<List<ExPara>>();
        ExPara? previous = null;
        int lastNumber = 0;
        foreach (var block in flow)
        {
            if (block is not ExPara { Item: { } item } para)
            {
                previous = null;
                continue;
            }
            var before = previous?.Item;
            bool top = lists.Count > 0 && before is not null && item.MarkerLeft - lists[^1][0].Item!.Value.MarkerLeft < 6;
            bool fresh = before is null || item.Ordered != before.Value.Ordered
                || (item.Ordered && top && item.Number != lastNumber + 1);
            if (fresh) lists.Add([]);
            lists[^1].Add(para);
            if (!item.Ordered || fresh || top) lastNumber = item.Number;
            previous = para;
        }

        for (int id = 0; id < lists.Count; id++)
        {
            var lefts = new List<double>();
            foreach (double left in lists[id].Select(p => p.Item!.Value.MarkerLeft).Distinct().Order())
            {
                if (lefts.Count == 0 || left - lefts[^1] > 6) lefts.Add(left);
            }
            foreach (var para in lists[id])
            {
                var (ordered, number, left) = para.Item!.Value;
                int level = Math.Min(3, lefts.FindLastIndex(l => l <= left + 6));
                result[para] = new ExportListItem(id + 1, ordered, Math.Max(0, level), number);
            }
        }
        return result;
    }

    /// <summary>
    /// Rows in the top or bottom band of a page that are page numbers, or that repeat on at least
    /// half the pages (digits ignored), are running heads and feet.
    /// </summary>
    public static HashSet<ExRow> RunningHeads(IReadOnlyList<(double Height, IReadOnlyList<ExRow> Rows)> pages)
    {
        var seen = new Dictionary<string, int>();
        var inBand = new List<(ExRow ExRow, string Key)>();
        foreach (var (height, rows) in pages)
        {
            var keys = new HashSet<string>();
            foreach (var row in rows)
            {
                double middle = (row.Top + row.Bottom) / 2;
                if (middle > height * BandFraction && middle < height * (1 - BandFraction)) continue;
                string key = Digits.Replace(row.Text, "#").Trim().ToLowerInvariant();
                inBand.Add((row, key));
                if (keys.Add(key)) seen[key] = seen.GetValueOrDefault(key) + 1;
            }
        }
        var dropped = new HashSet<ExRow>();
        foreach (var (row, key) in inBand)
        {
            if (PageNumber.IsMatch(row.Text) || (seen[key] >= 2 && seen[key] * 2 >= pages.Count)) dropped.Add(row);
        }
        return dropped;
    }
}
