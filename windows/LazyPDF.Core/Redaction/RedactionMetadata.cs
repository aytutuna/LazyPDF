using System.Text;
using System.Xml;

namespace LazyPDF.Core;

/// <summary>
/// Looks for removed text in the document information, the XMP packets, bookmark titles and the other
/// text strings of the file (descriptions in the tag tree, link addresses, names); replaces it when
/// asked. Copies of whole pages and of earlier versions (XMP thumbnails and history, /PieceInfo) are
/// removed whatever is asked, since no search can find a picture in them.
/// </summary>
internal static class RedactionMetadata
{
    // Binary strings and font data that a few letters match by chance, and the bookmark titles, which have their own pass.
    private static readonly string[] Skipped = ["ID", "O", "U", "OE", "UE", "Perms", "DA", "CharSet", "ByteRange", "Title"];

    /// <summary>The depth of objects held inside objects. The lexer stops at 200, so nothing the reader returns is deeper.</summary>
    internal const int ObjectDepth = 256;

    private const int MaxPacket = 16 << 20;
    private const int MaxXmlDepth = 128;

    // Thumbnails and page images (xmpGImg:image in whatever wrapper the producer used, as an element or an attribute),
    // history and what a page was made from. Names are compared without their prefix, since producers choose their own.
    private static readonly string[] PageCopies = ["Thumbnails", "History", "Ingredients", "DerivedFrom", "ManagedFrom", "RenditionOf", "Manifest", "Pantry", "PageInfo", "image", "Versions", "DocumentAncestors"];

    // The ids tie the output to the file it was made from.
    private static readonly string[] Identifiers = ["DocumentID", "InstanceID", "OriginalDocumentID"];

    public static IReadOnlyList<RedactionFinding> Scan(PdfDocument document, HashSet<string> needles, bool change)
    {
        var findings = new List<RedactionFinding>();
        DropPrivateData(document);
        var longestFirst = needles.OrderByDescending(n => n.Length).ToList();

        // The phrases have single spaces; a producer may break a line or indent between the words.
        static string Spaced(string text) => string.Join(' ', text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
        string Clean(string text) => longestFirst.Aggregate(Spaced(text), (t, n) => t.Replace(n, RedactionText.ReplacedBy, StringComparison.OrdinalIgnoreCase));
        bool Holds(string text)
        {
            string spaced = Spaced(text);
            return longestFirst.Any(n => spaced.Contains(n, StringComparison.OrdinalIgnoreCase));
        }

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
        foreach (var packet in Packets(document))
        {
            if (Read(document, packet) is not { } text || Parse(text) is not { } xml)
            {
                Emptied(packet, findings);
                continue;
            }
            bool changed = Strip(xml);
            bool holds = false;
            foreach (var (value, replace) in Carriers(xml))
            {
                if (!Holds(value)) continue;
                holds = true;
                if (!change) continue;
                replace(Clean(value));
                changed = true;
            }
            xmp |= holds;
            if (!changed) continue;
            if (xml.FirstChild is XmlDeclaration declaration) declaration.Encoding = "UTF-8";
            string written;
            try
            {
                written = xml.OuterXml;
            }
            catch (Exception e) when (e is ArgumentException or XmlException)
            {
                // The parser took names the writer refuses (a reserved xmlns binding); a packet that cannot be written back is not kept.
                Emptied(packet, findings);
                continue;
            }
            packet.Dictionary.Remove("Filter");
            packet.Dictionary.Remove("DecodeParms");
            packet.Data = new UTF8Encoding(false).GetBytes(written);
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

    private static void Emptied(PdfStream packet, List<RedactionFinding> findings)
    {
        packet.Dictionary.Remove("Filter");
        packet.Dictionary.Remove("DecodeParms");
        packet.Data = [];
        findings.Add(new RedactionFinding(RedactionText.XmpUnreadable, true));
    }

    private static IEnumerable<PdfStream> Packets(PdfDocument document)
    {
        var seen = new HashSet<PdfStream>(ReferenceEqualityComparer.Instance);
        foreach (int number in document.ObjectNumbers)
        {
            var value = document.Get(number);
            foreach (var holder in Direct(value, 0))
            {
                if (document.Stream(holder, "Metadata") is { } named && seen.Add(named)) yield return named;
            }
            if (value is PdfStream stream && (document.Name(stream.Dictionary, "Type") == "Metadata" || document.Name(stream.Dictionary, "Subtype") == "XML") && seen.Add(stream)) yield return stream;
        }
    }

    // Every dictionary held directly in the object; what a reference leads to is an object of its own.
    private static IEnumerable<PdfDictionary> Direct(PdfObject? value, int depth)
    {
        if (depth > ObjectDepth) yield break;
        switch (value)
        {
            case PdfStream stream:
                foreach (var inner in Direct(stream.Dictionary, depth)) yield return inner;
                break;
            case PdfDictionary dictionary:
                yield return dictionary;
                foreach (var (_, item) in dictionary.Entries)
                {
                    foreach (var inner in Direct(item, depth + 1)) yield return inner;
                }
                break;
            case PdfArray array:
                foreach (var item in array.Items)
                {
                    foreach (var inner in Direct(item, depth + 1)) yield return inner;
                }
                break;
        }
    }

    /// <summary>The character data of an XMP packet with the character references resolved, one piece per line; null when it is not XML.</summary>
    public static string? PlainText(byte[] data) =>
        data.Length <= MaxPacket && Parse(Decode(data)) is { } xml ? string.Join('\n', Carriers(xml).Select(c => c.Value)) : null;

    /// <summary>Whether a name is text a person wrote, not one of the names the format defines.</summary>
    public static bool IsFreeText(string name) => name.Any(c => !(char.IsAsciiLetterOrDigit(c) || c is '.' or '_' or '-' or '+'));

    /// <summary>The value of a font name entry, which takes spaces and commas without being text a person wrote.</summary>
    public static bool IsFontName(string key, PdfObject value) => value is PdfName && key is "BaseFont" or "FontName";

    /// <summary>The text a name stands for: its bytes are UTF-8 (ISO 32000-1 7.3.5), held one to a character.</summary>
    public static string NameText(string name)
    {
        if (name.Any(c => c > 0xFF)) return name;
        try
        {
            return new UTF8Encoding(false, true).GetString(Encoding.Latin1.GetBytes(name));
        }
        catch (ArgumentException)
        {
            return name;
        }
    }

    private static string NameValue(string text) => Encoding.Latin1.GetString(Encoding.UTF8.GetBytes(text));

    // The prefixes are left alone: producers use any and some leave them undeclared.
    private static XmlDocument? Parse(string text)
    {
        static XmlTextReader Open(string text) => new(new StringReader(text)) { Namespaces = false, DtdProcessing = DtdProcessing.Prohibit, XmlResolver = null };
        try
        {
            using (var reader = Open(text))
            {
                while (reader.Read())
                {
                    if (reader.Depth > MaxXmlDepth) return null;
                }
            }
            var xml = new XmlDocument { PreserveWhitespace = true, XmlResolver = null };
            using var again = Open(text);
            xml.Load(again);
            return xml;
        }
        catch (XmlException)
        {
            return null;
        }
    }

    private static IEnumerable<XmlNode> Walk(XmlNode root)
    {
        var pending = new Stack<XmlNode>([root]);
        while (pending.Count > 0)
        {
            var node = pending.Pop();
            yield return node;
            // PreviousSibling walks from the first child, so a long list is read forwards and pushed back to front.
            var children = node.ChildNodes.Cast<XmlNode>().ToList();
            for (int i = children.Count - 1; i >= 0; i--) pending.Push(children[i]);
        }
    }

    // Text, comments and attribute values: where words can be. The text of an element makes one piece with what its child
    // elements hold, since a word can be split between them, by a comment or by a tag.
    private static IEnumerable<(string Value, Action<string> Replace)> Carriers(XmlDocument xml)
    {
        foreach (var node in Walk(xml))
        {
            if (node is XmlComment comment) yield return (comment.Value ?? "", v => comment.Value = v);
            if (node is not XmlElement element) continue;
            foreach (XmlAttribute attribute in element.Attributes)
            {
                if (!attribute.Name.StartsWith("xmlns", StringComparison.Ordinal)) yield return (attribute.Value, v => attribute.Value = v);
            }
            if (!element.ChildNodes.Cast<XmlNode>().Any(n => n is XmlText or XmlCDataSection && !string.IsNullOrWhiteSpace(n.Value))) continue;
            var runs = Walk(element).Where(n => n is XmlText or XmlCDataSection).ToList();
            yield return (string.Concat(runs.Select(n => n.Value)), v =>
            {
                runs[0].Value = v;
                foreach (var rest in runs.Skip(1)) rest.Value = "";
            });
        }
    }

    // RemoveChild finds the node before the one it removes by walking from the first child, so taking many out of a long
    // list one at a time is quadratic; the element is emptied and what stays put back instead.
    private static bool Strip(XmlDocument xml)
    {
        static bool Dropped(string name) => PageCopies.Concat(Identifiers).Contains(name[(name.LastIndexOf(':') + 1)..], StringComparer.OrdinalIgnoreCase);
        bool any = false;
        foreach (var element in Walk(xml).OfType<XmlElement>().ToList())
        {
            var children = element.ChildNodes.Cast<XmlNode>().ToList();
            var attributes = element.Attributes.Cast<XmlAttribute>().ToList();
            if (!children.Any(c => c is XmlElement && Dropped(c.Name)) && !attributes.Any(a => Dropped(a.Name))) continue;
            any = true;
            element.RemoveAll();
            foreach (var attribute in attributes.Where(a => !Dropped(a.Name))) element.Attributes.Append(attribute);
            foreach (var child in children.Where(c => !(c is XmlElement && Dropped(c.Name)))) element.AppendChild(child);
        }
        return any;
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

    // Null when it cannot be read, which is no reason to keep it.
    private static string? Read(PdfDocument document, PdfStream packet)
    {
        try
        {
            var bytes = document.Data(packet, MaxPacket);
            return bytes.Length > MaxPacket ? null : Decode(bytes);
        }
        catch (PdfReadException)
        {
            return null;
        }
    }

    // A packet is UTF-8, UTF-16 or UTF-32 (XMP specification, 7.3). The byte order mark sits inside the begin attribute
    // of the wrapper, so the packet starts with its first character, and a zero byte tells the width and the order.
    // A mark at the very start is taken too.
    private static string Decode(byte[] bytes) => bytes switch
    {
        [0xFF, 0xFE, 0, 0, ..] => new UTF32Encoding(false, false).GetString(bytes, 4, bytes.Length - 4),
        [0, 0, 0xFE, 0xFF, ..] => new UTF32Encoding(true, false).GetString(bytes, 4, bytes.Length - 4),
        [0xFE, 0xFF, ..] => Encoding.BigEndianUnicode.GetString(bytes, 2, bytes.Length - 2),
        [0xFF, 0xFE, ..] => Encoding.Unicode.GetString(bytes, 2, bytes.Length - 2),
        [0xEF, 0xBB, 0xBF, ..] => Encoding.UTF8.GetString(bytes, 3, bytes.Length - 3),
        [0, 0, 0, > 0, ..] => new UTF32Encoding(true, false).GetString(bytes),
        [> 0, 0, 0, 0, ..] => new UTF32Encoding(false, false).GetString(bytes),
        [0, > 0, ..] => Encoding.BigEndianUnicode.GetString(bytes),
        [> 0, 0, ..] => Encoding.Unicode.GetString(bytes),
        _ => Encoding.UTF8.GetString(bytes),
    };

    // The text strings held directly in dictionaries and arrays; what a reference leads to is visited as an object of its own.
    private sealed class Strings(Func<string, bool> holds, Func<string, string> clean, bool change)
    {
        private const int MaxDepth = ObjectDepth;

        public bool Found { get; private set; }

        /// <summary>The object itself, or the string that replaces it.</summary>
        public PdfObject Replace(PdfObject value) => Item(value, 0);

        private void Visit(PdfDictionary dictionary, int depth)
        {
            if (depth > MaxDepth) return;
            foreach (var (key, value) in dictionary.Entries.ToList())
            {
                if (Skipped.Contains(key) || IsFontName(key, value)) continue;
                var replaced = Item(value, depth);
                if (IsFreeText(key) && holds(NameText(key)))
                {
                    Found = true;
                    if (change)
                    {
                        string renamed = NameValue(clean(NameText(key)));
                        while (dictionary.ContainsKey(renamed)) renamed += "_";
                        dictionary.Remove(key);
                        dictionary[renamed] = replaced;
                        continue;
                    }
                }
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
                case PdfName name when IsFreeText(name.Value) && holds(NameText(name.Value)):
                    Found = true;
                    return change ? new PdfName(NameValue(clean(NameText(name.Value)))) : value;
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
