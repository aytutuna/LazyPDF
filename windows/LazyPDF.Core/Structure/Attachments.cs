using System.Security.Cryptography;

namespace LazyPDF.Core;

/// <summary>
/// A file inside the PDF (ISO 32000-1 7.11.4): an entry of the /EmbeddedFiles name tree
/// (<see cref="PageIndex"/> null) or a FileAttachment annotation on that page. Sizes are in bytes,
/// <see cref="Size"/> as the file says (uncompressed) and <see cref="StoredSize"/> of the stream
/// as stored; <see cref="CheckSum"/> is the MD5 as hex.
/// </summary>
public sealed record PdfAttachment(
    string Name, string FileName, string? Description, string? MimeType, long? Size, long? StoredSize,
    DateTimeOffset? Created, DateTimeOffset? Modified, string? CheckSum, int? PageIndex, PdfReference? Annotation)
{
    internal PdfObject? Spec { get; init; }
    internal string? Key { get; init; }
}

public static class PdfAttachments
{
    private const int MaxAnnotations = 50_000;
    private const long MaxExtractSize = 1L << 30;
    private static readonly string[] StreamKeys = ["UF", "F", "DOS", "Mac", "Unix"];

    /// <summary>The embedded files of the tree, then those of the pages' attachment annotations. A file specification with no embedded stream is left out.</summary>
    public static IReadOnlyList<PdfAttachment> List(PdfDocument document)
    {
        var list = new List<PdfAttachment>();
        var tree = document.Dict(document.Dict(document.Catalog, "Names"), "EmbeddedFiles");
        foreach (var (key, value) in PdfNameTree.Read(document, tree))
        {
            if (Describe(document, PdfNameTree.TextOf(key), value, null, null, null) is { } found) list.Add(found with { Key = key });
        }
        int annotations = 0;
        foreach (var page in document.Pages)
        {
            if (document.Array(page.Dictionary, "Annots") is not { } annots) continue;
            foreach (var item in annots.Items)
            {
                if (++annotations > MaxAnnotations) return list;
                if (document.Resolve(item) is not PdfDictionary annot || document.Name(annot, "Subtype") != "FileAttachment") continue;
                string? note = PdfText.Read(document, annot, "Contents");
                if (Describe(document, "", annot["FS"], page.Index, item as PdfReference, note) is { } found) list.Add(found with { Name = found.FileName });
            }
        }
        return list;
    }

    internal static PdfStream? StreamOf(PdfDocument document, PdfAttachment attachment) =>
        EmbeddedStream(document, document.Resolve(attachment.Spec) as PdfDictionary);

    /// <summary>The file's bytes, decoded; up to 1 GiB, above the default decode cap.</summary>
    public static byte[] Extract(PdfDocument document, PdfAttachment attachment)
    {
        var stream = EmbeddedStream(document, document.Resolve(attachment.Spec) as PdfDictionary)
                     ?? throw new InvalidOperationException("The attachment is no longer in the document.");
        return document.Data(stream, MaxExtractSize);
    }

    /// <summary>
    /// Adds a file to the /EmbeddedFiles tree. A name the tree has already gets " (2)", " (3)"...
    /// before its extension. Dates are given, not read from a clock; they are left out when null.
    /// </summary>
    public static PdfAttachment Add(PdfDocument document, string name, byte[] data, string? mimeType = null, string? description = null,
        DateTimeOffset? created = null, DateTimeOffset? modified = null)
    {
        var tree = document.Dict(document.Dict(document.Catalog, "Names"), "EmbeddedFiles");
        var entries = PdfNameTree.Read(document, tree).ToList();
        string unique = Unique(name, entries.Select(e => PdfNameTree.TextOf(e.Key)).ToHashSet());

        var parameters = new PdfDictionary { ["Size"] = new PdfNumber(data.Length) };
        if (created is { } c) parameters["CreationDate"] = PdfText.ToObject(PdfDate.Format(c));
        if (modified is { } m) parameters["ModDate"] = PdfText.ToObject(PdfDate.Format(m));
        parameters["CheckSum"] = new PdfString(MD5.HashData(data), true);
        var dictionary = new PdfDictionary { ["Type"] = new PdfName("EmbeddedFile") };
        if (mimeType is not null) dictionary["Subtype"] = new PdfName(mimeType);
        dictionary["Params"] = parameters;
        byte[] stored = data;
        if (data.Length > 64 && PdfFilterEncoders.Flate(data) is { } packed && packed.Length < data.Length)
        {
            stored = packed;
            dictionary["Filter"] = new PdfName("FlateDecode");
        }
        var stream = document.Add(new PdfStream(dictionary, stored));

        var spec = new PdfDictionary
        {
            ["Type"] = new PdfName("Filespec"),
            ["F"] = PdfText.ToFileName(unique),
            ["UF"] = PdfText.ToObject(unique),
            ["EF"] = new PdfDictionary { ["F"] = stream, ["UF"] = stream },
        };
        if (!string.IsNullOrEmpty(description)) spec["Desc"] = PdfText.ToObject(description);
        var specRef = document.Add(spec);

        entries.Add(new(PdfNameTree.KeyOf(unique), specRef));
        WriteTree(document, tree, entries);
        return Describe(document, unique, specRef, null, null, null)! with { Key = PdfNameTree.KeyOf(unique) };
    }

    /// <summary>Takes the file out and frees its objects: an entry of the tree by name, an annotation by its reference. False when it is not there.</summary>
    public static bool Remove(PdfDocument document, PdfAttachment attachment)
    {
        if (attachment.Annotation is { } annotation)
        {
            var page = attachment.PageIndex is { } i && i < document.Pages.Count ? document.Pages[i] : null;
            if (page is null || document.Array(page.Dictionary, "Annots") is not { } annots) return false;
            if (!annots.Items.Any(x => x is PdfReference r && r.Number == annotation.Number)) return false;
            // The popup and replies go with it, as when the annotation is deleted any other way.
            if (document.Resolve(annotation) is PdfDictionary d && PdfAnnotations.Parse(document, d, annotation, page.Index) is { } parsed)
            {
                new PdfAnnotationWriter(document).Delete(parsed);
            }
            else
            {
                annots.Items.RemoveAll(x => x is PdfReference r && r.Number == annotation.Number);
                document.Delete(annotation.Number);
            }
            if (!InUse(document, attachment.Spec)) FreeSpec(document, attachment.Spec);
            return true;
        }
        var tree = document.Dict(document.Dict(document.Catalog, "Names"), "EmbeddedFiles");
        var entries = PdfNameTree.Read(document, tree).ToList();
        string key = attachment.Key ?? PdfNameTree.KeyOf(attachment.Name);
        int at = entries.FindIndex(e => e.Key == key);
        if (at < 0) return false;
        var spec = entries[at].Value;
        entries.RemoveAt(at);
        if (!InUse(document, spec) && !entries.Any(e => SameObject(document, e.Value, spec))) FreeSpec(document, spec);
        if (entries.Count == 0 && document.Dict(document.Catalog, "Names") is { } names)
        {
            PdfNameTree.Write(document, tree, entries);
            if (names["EmbeddedFiles"] is PdfReference root) document.Delete(root.Number);
            names.Remove("EmbeddedFiles");
        }
        else WriteTree(document, tree, entries);
        return true;
    }

    private static PdfAttachment? Describe(PdfDocument document, string name, PdfObject? value, int? page, PdfReference? annotation, string? note)
    {
        if (document.Resolve(value) is not PdfDictionary spec || EmbeddedStream(document, spec) is not { } stream) return null;
        var parameters = document.Dict(stream.Dictionary, "Params");
        string fileName = PdfActions.FileName(document, spec) ?? name;
        string? checksum = document.Resolve(parameters?["CheckSum"]) is PdfString { Bytes.Length: > 0 } sum ? Convert.ToHexString(sum.Bytes) : null;
        return new PdfAttachment(
            name.Length > 0 ? name : fileName, fileName, PdfText.Read(document, spec, "Desc") ?? note,
            document.Name(stream.Dictionary, "Subtype"), document.Integer(parameters, "Size"), stream.Data?.Length ?? document.Integer(stream.Dictionary, "Length"),
            PdfDate.Parse(PdfText.Read(document, parameters, "CreationDate")), PdfDate.Parse(PdfText.Read(document, parameters, "ModDate")),
            checksum, page, annotation) { Spec = value };
    }

    private static PdfStream? EmbeddedStream(PdfDocument document, PdfDictionary? spec)
    {
        if (document.Dict(spec, "EF") is not { } files) return null;
        foreach (string key in StreamKeys)
        {
            if (document.Stream(files, key) is { } stream) return stream;
        }
        return null;
    }

    // A page copied with its file attachment shares the file specification with the original.
    private static bool InUse(PdfDocument document, PdfObject? spec)
    {
        foreach (var page in document.Pages)
        {
            if (document.Array(page.Dictionary, "Annots") is not { } annots) continue;
            foreach (var item in annots.Items)
            {
                if (document.Resolve(item) is PdfDictionary d && SameObject(document, d["FS"], spec)) return true;
            }
        }
        return false;
    }

    private static bool SameObject(PdfDocument document, PdfObject? a, PdfObject? b) =>
        a is PdfReference x && b is PdfReference y ? x.Number == y.Number : ReferenceEquals(document.Resolve(a), document.Resolve(b)) && document.Resolve(a) is not null;

    private static void FreeSpec(PdfDocument document, PdfObject? value)
    {
        if (document.Resolve(value) is PdfDictionary spec && document.Dict(spec, "EF") is { } files)
        {
            foreach (var entry in files.Entries)
            {
                if (entry.Value is PdfReference stream) document.Delete(stream.Number);
            }
        }
        if (value is PdfReference reference) document.Delete(reference.Number);
    }

    private static void WriteTree(PdfDocument document, PdfDictionary? tree, List<KeyValuePair<string, PdfObject>> entries)
    {
        var root = PdfNameTree.Write(document, tree, entries);
        if (tree is null) PdfNames.Ensure(document)["EmbeddedFiles"] = document.Add(root);
    }

    private static string Unique(string name, HashSet<string> taken)
    {
        if (!taken.Contains(name)) return name;
        string stem = Path.GetFileNameWithoutExtension(name), extension = Path.GetExtension(name);
        for (int n = 2; ; n++)
        {
            string candidate = $"{stem} ({n}){extension}";
            if (!taken.Contains(candidate)) return candidate;
        }
    }
}

/// <summary>One column of a portfolio's detail view (ISO 32000-1 12.3.5, table 156).</summary>
public sealed record PortfolioField(string Key, string Label, string Type, int Order, bool Visible, bool Editable);

/// <summary>A PDF portfolio: the /Collection of the catalog. <see cref="View"/> is "D" (details), "T" (tiles) or "H" (hidden).</summary>
public sealed record PdfPortfolio(string View, string? InitialDocument, IReadOnlyList<PortfolioField> Fields)
{
    /// <summary>The collection dictionary, or null when the document is no portfolio.</summary>
    public static PdfPortfolio? Read(PdfDocument document)
    {
        if (document.Dict(document.Catalog, "Collection") is not { } collection) return null;
        var fields = new List<PortfolioField>();
        if (document.Dict(collection, "Schema") is { } schema)
        {
            foreach (var entry in schema.Entries.Where(e => e.Key != "Type").Take(1000))
            {
                if (document.Resolve(entry.Value) is not PdfDictionary field) continue;
                fields.Add(new PortfolioField(
                    entry.Key, PdfText.Read(document, field, "N") ?? entry.Key, document.Name(field, "Subtype") ?? "S",
                    (int)(document.Integer(field, "O") ?? 0), document.Bool(field, "V") ?? true, document.Bool(field, "E") ?? false));
            }
        }
        return new PdfPortfolio(document.Name(collection, "View") ?? "D", PdfText.Read(document, collection, "D"), [.. fields.OrderBy(f => f.Order)]);
    }
}
