using System.Xml;
using System.Xml.Linq;

namespace LazyPDF.Core;

/// <summary>
/// The descriptive metadata of a document (ISO 32000-1 14.3): the /Info dictionary and, kept in
/// step with it, the XMP packet. <see cref="Custom"/> holds the /Info entries with other keys whose
/// value is a string.
/// <see cref="XmpUnreadable"/> is true when the file has an XMP packet that could not be read.
/// </summary>
public sealed record DocumentMetadata(
    string? Title, string? Author, string? Subject, string? Keywords, string? Creator, string? Producer,
    DateTimeOffset? Created, DateTimeOffset? Modified, IReadOnlyDictionary<string, string> Custom, bool XmpUnreadable = false)
{
    private static readonly string[] Standard = ["Title", "Author", "Subject", "Keywords", "Creator", "Producer", "CreationDate", "ModDate", "Trapped"];

    /// <summary>The metadata from /Info; what it lacks is taken from the XMP packet. Dates without a zone count as UTC.</summary>
    public static DocumentMetadata Read(PdfDocument document)
    {
        var info = document.Info;
        var xmp = XmpPacket.Load(document);
        string? Text(string key, XNamespace? ns, string name) =>
            PdfText.Read(document, info, key) ?? (ns is null ? null : xmp?.Get(ns, name));
        DateTimeOffset? Date(string key, string name) =>
            PdfDate.Parse(PdfText.Read(document, info, key)) ?? PdfDate.ParseXmp(xmp?.Get(XmpPacket.Xmp, name));

        var custom = new SortedDictionary<string, string>(StringComparer.Ordinal);
        foreach (var entry in info?.Entries.Take(10_000) ?? [])
        {
            if (Standard.Contains(entry.Key) || document.Resolve(entry.Value) is not PdfString text) continue;
            custom[entry.Key] = PdfText.Decode(text.Bytes);
        }
        return new DocumentMetadata(
            Text("Title", XmpPacket.Dc, "title"), Text("Author", XmpPacket.Dc, "creator"), Text("Subject", XmpPacket.Dc, "description"),
            Text("Keywords", XmpPacket.Pdf, "Keywords"), Text("Creator", XmpPacket.Xmp, "CreatorTool"), Text("Producer", XmpPacket.Pdf, "Producer"),
            Date("CreationDate", "CreateDate"), Date("ModDate", "ModifyDate"), custom,
            xmp is null && XmpPacket.IsPresent(document));
    }

    /// <summary>
    /// Stores the metadata: /Info is made if the file has none, a key set to null or empty is
    /// taken out, and an /Info entry that is not here and not a string stays. The XMP packet is
    /// updated when the file has one that can be read and is not behind a Crypt filter; none is made.
    /// </summary>
    public void Write(PdfDocument document)
    {
        var info = document.Info ?? new PdfDictionary();
        if (document.Info is null) document.Trailer["Info"] = document.Add(info);
        var before = Read(document).Custom;

        void Put(string key, string? value)
        {
            if (string.IsNullOrEmpty(value)) info.Remove(key);
            else info[key] = PdfText.ToObject(value);
        }
        Put("Title", Title);
        Put("Author", Author);
        Put("Subject", Subject);
        Put("Keywords", Keywords);
        Put("Creator", Creator);
        Put("Producer", Producer);
        // A date Read could not parse is not Created, but it is still in the file and stays.
        if (Created is not null || PdfDate.Parse(PdfText.Read(document, info, "CreationDate")) is not null || !info.ContainsKey("CreationDate"))
            Put("CreationDate", Created is { } c ? PdfDate.Format(c) : null);
        if (Modified is not null || PdfDate.Parse(PdfText.Read(document, info, "ModDate")) is not null || !info.ContainsKey("ModDate"))
            Put("ModDate", Modified is { } m ? PdfDate.Format(m) : null);
        var wanted = Custom.Where(e => e.Key.Length > 0 && !Standard.Contains(e.Key)).ToList();
        foreach (string key in before.Keys.Where(k => wanted.All(w => w.Key != k))) info.Remove(key);
        foreach (var (key, value) in wanted) Put(key, value);

        WriteXmp(document, before.Keys.Concat(wanted.Select(w => w.Key)).Distinct());
    }

    private void WriteXmp(PdfDocument document, IEnumerable<string> customKeys)
    {
        if (document.Stream(document.Catalog, "Metadata") is not { } stream || HasCryptFilter(document, stream)) return;
        if (XmpPacket.Load(document) is not { } xmp) return;

        string? Nullable(string? s) => string.IsNullOrEmpty(s) ? null : s;
        xmp.SetAlt(XmpPacket.Dc, "dc", "title", Nullable(Title));
        xmp.SetSeq(XmpPacket.Dc, "dc", "creator", Nullable(Author));
        xmp.SetAlt(XmpPacket.Dc, "dc", "description", Nullable(Subject));
        xmp.Set(XmpPacket.Pdf, "pdf", "Keywords", Nullable(Keywords));
        xmp.SetBag(XmpPacket.Dc, "dc", "subject", Keywords?.Split([',', ';'], StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries) ?? []);
        xmp.Set(XmpPacket.Pdf, "pdf", "Producer", Nullable(Producer));
        xmp.Set(XmpPacket.Xmp, "xmp", "CreatorTool", Nullable(Creator));
        xmp.Set(XmpPacket.Xmp, "xmp", "CreateDate", Created is { } c ? PdfDate.FormatXmp(c) : null);
        xmp.Set(XmpPacket.Xmp, "xmp", "ModifyDate", Modified is { } m ? PdfDate.FormatXmp(m) : null);
        if (Modified is { } md && xmp.Has(XmpPacket.Xmp, "MetadataDate")) xmp.Set(XmpPacket.Xmp, "xmp", "MetadataDate", PdfDate.FormatXmp(md));
        foreach (string key in customKeys.Where(IsXmlName))
        {
            xmp.Set(XmpPacket.Pdfx, "pdfx", key, Custom.TryGetValue(key, out var value) && value.Length > 0 ? value : null);
        }

        stream.Data = xmp.ToBytes();
        stream.Dictionary.Remove("Filter");
        stream.Dictionary.Remove("DecodeParms");
    }

    private static bool HasCryptFilter(PdfDocument document, PdfStream stream) =>
        document.Resolve(stream.Dictionary["Filter"]) switch
        {
            PdfName n => n.Value == "Crypt",
            PdfArray a => a.Items.Any(i => document.Resolve(i) is PdfName { Value: "Crypt" }),
            _ => false,
        };

    private static bool IsXmlName(string key)
    {
        try
        {
            XmlConvert.VerifyNCName(key);
            return true;
        }
        catch (XmlException)
        {
            return false;
        }
    }
}
