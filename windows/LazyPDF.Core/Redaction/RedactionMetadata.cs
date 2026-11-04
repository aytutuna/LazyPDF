using System.Security;
using System.Text;

namespace LazyPDF.Core;

/// <summary>Looks for removed text in the document information, the XMP packet and bookmark titles; replaces it when asked.</summary>
internal static class RedactionMetadata
{
    public static IReadOnlyList<RedactionFinding> Scan(PdfDocument document, HashSet<string> needles, bool change)
    {
        var findings = new List<RedactionFinding>();
        if (needles.Count == 0) return findings;
        var longestFirst = needles.OrderByDescending(n => n.Length).ToList();

        string Clean(string text) => longestFirst.Aggregate(text, (t, n) => t.Replace(n, RedactionText.ReplacedBy, StringComparison.OrdinalIgnoreCase));
        bool Holds(string text) => longestFirst.Any(n => text.Contains(n, StringComparison.OrdinalIgnoreCase));

        if (document.Info is { } info)
        {
            bool found = false;
            foreach (var (key, value) in info.Entries.ToList())
            {
                if (document.Resolve(value) is not PdfString s) continue;
                string text = PdfText.Decode(s.Bytes);
                if (!Holds(text)) continue;
                found = true;
                if (change) info[key] = PdfText.ToObject(Clean(text));
            }
            if (found) findings.Add(new RedactionFinding("The document information", change));
        }

        if (document.Stream(document.Catalog, "Metadata") is { } packet)
        {
            string xml = Read(document, packet);
            var escaped = longestFirst.Select(SecurityElement.Escape).OfType<string>();
            if (longestFirst.Concat(escaped).Any(n => xml.Contains(n, StringComparison.OrdinalIgnoreCase)))
            {
                if (change)
                {
                    foreach (string n in longestFirst.Concat(escaped).OrderByDescending(n => n.Length))
                        xml = xml.Replace(n, RedactionText.ReplacedBy, StringComparison.OrdinalIgnoreCase);
                    packet.Dictionary.Remove("Filter");
                    packet.Dictionary.Remove("DecodeParms");
                    packet.Data = new UTF8Encoding(false).GetBytes(xml);
                }
                findings.Add(new RedactionFinding("The XMP metadata", change));
            }
        }

        var outline = Outline.Read(document);
        bool titles = false;
        void Walk(OutlineItem item)
        {
            if (Holds(item.Title))
            {
                titles = true;
                if (change) item.Title = Clean(item.Title);
            }
            foreach (var child in item.Children) Walk(child);
        }
        foreach (var item in outline.Items) Walk(item);
        if (titles)
        {
            if (change) outline.Write(document);
            findings.Add(new RedactionFinding("A bookmark title", change));
        }
        return findings;
    }

    private static string Read(PdfDocument document, PdfStream packet)
    {
        try
        {
            return Encoding.UTF8.GetString(document.Data(packet, 16 << 20));
        }
        catch (PdfReadException)
        {
            return "";
        }
    }
}
