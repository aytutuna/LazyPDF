using System.Text;
using System.Text.RegularExpressions;

namespace LazyPDF.Core;

/// <summary>
/// Run ids are only unique within the file that made them. Pages brought together from several
/// files can carry the same id for different runs; they are given ids of their own, so that removing
/// one run does not take another with it.
/// </summary>
internal static class StampRuns
{
    private const int MaxContent = 64 << 20;

    /// <summary>Pages in their final order, each with the file it came from.</summary>
    public static void Separate(PdfDocument document, IReadOnlyList<(PdfPage Page, object Origin)> pages)
    {
        var claimed = new Dictionary<int, (StampKind Kind, string? Label, bool Behind)>();
        var renamed = new Dictionary<(object Origin, int Id), int>();
        var done = new HashSet<PdfObject>(ReferenceEqualityComparer.Instance);
        int next = pages.SelectMany(p => StampStreams.Scan(document, p.Page)).Select(f => f.Id).DefaultIfEmpty(0).Max();
        foreach (var (page, origin) in pages)
        {
            foreach (var found in StampStreams.Scan(document, page))
            {
                var signature = (found.Kind, found.Label, found.Behind);
                if (renamed.TryGetValue((origin, found.Id), out int already))
                {
                    if (already != found.Id) Renumber(document, page, found.Id, already, done);
                    continue;
                }
                int id = found.Id;
                if (claimed.TryGetValue(id, out var holder) && holder != signature)
                {
                    id = ++next;
                    Renumber(document, page, found.Id, id, done);
                }
                claimed[id] = signature;
                renamed[(origin, found.Id)] = id;
            }
        }
    }

    private static void Renumber(PdfDocument document, PdfPage page, int from, int to, HashSet<PdfObject> done)
    {
        foreach (var item in StampStreams.Contents(document, page))
        {
            if (document.Resolve(item) is not PdfStream stream || !done.Add(stream)) continue;
            if (document.Dict(stream.Dictionary, StampStreams.Key) is not { } marker || document.Integer(marker, "Id") != from) continue;
            marker["Id"] = new PdfNumber(to);
            string text = Encoding.Latin1.GetString(document.Data(stream, MaxContent));
            text = text.Replace(StampStreams.Prefix(from), StampStreams.Prefix(to), StringComparison.Ordinal);
            text = Regex.Replace(text, $@"(/{StampStreams.Key}\s+){from}(?!\d)", $"${{1}}{to}");
            stream.Data = Encoding.Latin1.GetBytes(text);
            stream.Dictionary.Remove("Filter");
            stream.Dictionary.Remove("DecodeParms");
        }
        if (document.Dict(page.Dictionary, "Resources") is not { } resources) return;
        string prefix = StampStreams.Prefix(from);
        foreach (string category in (ReadOnlySpan<string>)["Font", "XObject", "ExtGState", "Properties"])
        {
            if (document.Dict(resources, category) is not { } entries) continue;
            foreach (var (name, value) in entries.Entries.Where(e => e.Key.StartsWith(prefix, StringComparison.Ordinal)).ToList())
            {
                entries.Remove(name);
                entries[StampStreams.Prefix(to) + name[prefix.Length..]] = value;
                if (category == "Properties" && document.Resolve(value) is PdfDictionary group && done.Add(group)
                    && document.Integer(group, StampStreams.Key) == from) group[StampStreams.Key] = new PdfNumber(to);
            }
        }
    }
}
