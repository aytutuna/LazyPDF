using System.Security;
using System.Text;
using System.Text.RegularExpressions;

namespace LazyPDF.Core;

/// <summary>
/// Looks for removed text in the document information, the XMP packets, bookmark titles and the other
/// text strings of the file (descriptions in the tag tree, link addresses, names); replaces it when
/// asked. Copies of whole pages and of earlier versions (XMP thumbnails and history, /PieceInfo) are
/// removed whatever is asked, since no search can find a picture in them.
/// </summary>
internal static partial class RedactionMetadata
{
    // Binary strings and font data that a few letters match by chance, and the bookmark titles, which have their own pass.
    private static readonly string[] Skipped = ["ID", "O", "U", "OE", "UE", "Perms", "DA", "CharSet", "ByteRange", "Title"];

    // Thumbnails and page images (xmpGImg:image in whatever wrapper the producer used, as an element or an attribute),
    // history and what a page was made from, whether the element is closed or written in one tag.
    [GeneratedRegex(@"<(\w+):(Thumbnails|History|Ingredients|DerivedFrom|Pantry|PageInfo|image)\b(?:[^>]*/>|.*?</\1:\2>)|\s\w+:image\s*=\s*(['""]).*?\3", RegexOptions.Singleline)]
    private static partial Regex PageCopies();

    // The ids tie the output to the file it was made from, as elements or as attributes, with whatever prefix the namespace has.
    [GeneratedRegex(@"<(\w+):(DocumentID|InstanceID|OriginalDocumentID)\b[^>]*>.*?</\1:\2>|\s\w+:(?:DocumentID|InstanceID|OriginalDocumentID)\s*=\s*(['""]).*?\3", RegexOptions.Singleline)]
    private static partial Regex Identifiers();

    public static IReadOnlyList<RedactionFinding> Scan(PdfDocument document, HashSet<string> needles, bool change)
    {
        var findings = new List<RedactionFinding>();
        DropPrivateData(document);
        var longestFirst = needles.OrderByDescending(n => n.Length).ToList();

        string Clean(string text) => longestFirst.Aggregate(text, (t, n) => t.Replace(n, RedactionText.ReplacedBy, StringComparison.OrdinalIgnoreCase));
        bool Holds(string text) => longestFirst.Any(n => text.Contains(n, StringComparison.OrdinalIgnoreCase));

        if (document.Info is { } info && needles.Count > 0)
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

        bool xmp = false;
        var spellings = longestFirst.Concat(longestFirst.Select(SecurityElement.Escape).OfType<string>()).OrderByDescending(n => n.Length).ToList();
        foreach (var packet in Packets(document))
        {
            if (Read(document, packet) is not { } xml)
            {
                packet.Dictionary.Remove("Filter");
                packet.Dictionary.Remove("DecodeParms");
                packet.Data = [];
                findings.Add(new RedactionFinding(RedactionText.XmpUnreadable, true));
                continue;
            }
            string text = Identifiers().Replace(PageCopies().Replace(xml, ""), "");
            bool holds = spellings.Any(n => text.Contains(n, StringComparison.OrdinalIgnoreCase));
            if (holds && change)
            {
                foreach (string n in spellings) text = text.Replace(n, RedactionText.ReplacedBy, StringComparison.OrdinalIgnoreCase);
            }
            xmp |= holds;
            if (text == xml) continue;
            packet.Dictionary.Remove("Filter");
            packet.Dictionary.Remove("DecodeParms");
            packet.Data = new UTF8Encoding(false).GetBytes(text);
        }
        if (xmp) findings.Add(new RedactionFinding("The XMP metadata", change));

        if (needles.Count == 0) return findings;
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

        var strings = new Strings(Holds, Clean, change);
        foreach (int number in document.ObjectNumbers)
        {
            var item = document.Get(number) switch { PdfStream s => s.Dictionary, var other => other };
            if (item is null || ReferenceEquals(item, document.Info)) continue;
            var replaced = strings.Replace(item);
            if (!ReferenceEquals(replaced, item)) document.Set(number, replaced);
        }
        if (strings.Found) findings.Add(new RedactionFinding(RedactionText.TextElsewhere, change));
        return findings;
    }

    private static IEnumerable<PdfStream> Packets(PdfDocument document)
    {
        var seen = new HashSet<PdfStream>(ReferenceEqualityComparer.Instance);
        foreach (int number in document.ObjectNumbers)
        {
            var holder = document.Get(number) switch { PdfDictionary d => d, PdfStream s => s.Dictionary, _ => null };
            if (document.Stream(holder, "Metadata") is { } named && seen.Add(named)) yield return named;
            if (document.Get(number) is PdfStream stream && (document.Name(stream.Dictionary, "Type") == "Metadata" || document.Name(stream.Dictionary, "Subtype") == "XML") && seen.Add(stream)) yield return stream;
        }
    }

    // Private data of the producing program can hold the whole page or document as it was.
    private static void DropPrivateData(PdfDocument document)
    {
        document.Catalog.Remove("PieceInfo");
        foreach (var page in document.Pages) page.Dictionary.Remove("PieceInfo");
        foreach (int number in document.ObjectNumbers)
        {
            if (document.Get(number) is PdfStream { Dictionary: var d } && document.Name(d, "Subtype") == "Form") d.Remove("PieceInfo");
        }
    }

    // A packet is UTF-8, UTF-16 or UTF-32 (XMP specification, 7.3). The byte order mark sits inside the begin attribute
    // of the wrapper, so the packet starts with its first character, and a zero byte tells the width and the order.
    // Null when it cannot be read, which is no reason to keep it.
    private static string? Read(PdfDocument document, PdfStream packet)
    {
        try
        {
            var bytes = document.Data(packet, 16 << 20);
            return bytes switch
            {
                [0xFE, 0xFF, ..] => Encoding.BigEndianUnicode.GetString(bytes, 2, bytes.Length - 2),
                [0xFF, 0xFE, ..] => Encoding.Unicode.GetString(bytes, 2, bytes.Length - 2),
                [0xEF, 0xBB, 0xBF, ..] => Encoding.UTF8.GetString(bytes, 3, bytes.Length - 3),
                [0, 0, 0, > 0, ..] => new UTF32Encoding(true, false).GetString(bytes),
                [> 0, 0, 0, 0, ..] => new UTF32Encoding(false, false).GetString(bytes),
                [0, > 0, ..] => Encoding.BigEndianUnicode.GetString(bytes),
                [> 0, 0, ..] => Encoding.Unicode.GetString(bytes),
                _ => Encoding.UTF8.GetString(bytes),
            };
        }
        catch (PdfReadException)
        {
            return null;
        }
    }

    // The text strings held directly in dictionaries and arrays; what a reference leads to is visited as an object of its own.
    private sealed class Strings(Func<string, bool> holds, Func<string, string> clean, bool change)
    {
        private const int MaxDepth = 32;

        public bool Found { get; private set; }

        /// <summary>The object itself, or the string that replaces it.</summary>
        public PdfObject Replace(PdfObject value) => Item(value, 0);

        private void Visit(PdfDictionary dictionary, int depth)
        {
            if (depth > MaxDepth) return;
            foreach (var (key, value) in dictionary.Entries.ToList())
            {
                if (Skipped.Contains(key)) continue;
                var replaced = Item(value, depth);
                if (!ReferenceEquals(replaced, value)) dictionary[key] = replaced;
            }
        }

        private PdfObject Item(PdfObject value, int depth)
        {
            switch (value)
            {
                case PdfString s when Text(s.Bytes) is { } text && holds(text):
                    Found = true;
                    return change ? PdfText.ToObject(clean(text)) : value;
                case PdfDictionary inner:
                    Visit(inner, depth + 1);
                    break;
                case PdfArray array when depth < MaxDepth:
                    for (int i = 0; i < array.Items.Count; i++) array.Items[i] = Item(array.Items[i], depth + 1);
                    break;
            }
            return value;
        }

        // Text in PDFDocEncoding or UTF-16 or UTF-8 with a mark; anything with control bytes is data.
        private static string? Text(byte[] bytes)
        {
            bool marked = bytes.Length >= 2 && ((bytes[0] == 0xFE && bytes[1] == 0xFF) || (bytes[0] == 0xFF && bytes[1] == 0xFE)) || bytes.Length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF;
            if (!marked && bytes.Any(b => b < 0x20 && b is not (9 or 10 or 13))) return null;
            return PdfText.Decode(bytes);
        }
    }
}
