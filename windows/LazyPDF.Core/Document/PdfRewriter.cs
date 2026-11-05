using System.Security.Cryptography;
using System.Text;

namespace LazyPDF.Core;

// A rewrite keeps what the trailer can reach, numbers it afresh and lays the file out again, with
// no history in it. Reachability is a walk from /Root and /Info; the numbers come out in the order
// the walk meets the objects, which puts the catalog first.
internal sealed class PdfRewriter(PdfDocument document, PdfSaveOptions options)
{
    // The size qpdf and most writers pack to; an object stream is parsed whole to read one object.
    private const int ObjectsPerStream = 100;

    private static readonly string[] Repackable =
        ["FlateDecode", "Fl", "LZWDecode", "LZW", "ASCII85Decode", "A85", "ASCIIHexDecode", "AHx", "RunLengthDecode", "RL"];

    private readonly Dictionary<int, int> _numbers = [];
    private readonly List<PdfObject> _items = [];
    private int _followed;

    public byte[] Run()
    {
        int root = Intern(document.Trailer["Root"]);
        int info = document.Info is null ? 0 : Intern(document.Trailer["Info"]);
        Follow();
        // Pages the reader shows without the tree reaching them (it found them by scanning) are kept too.
        foreach (var page in document.Pages) Intern(page.Reference);
        Follow();

        var security = options.Security;
        var packed = new List<int>();
        if (options.UseObjectStreams)
        {
            // The catalog stays a plain object: PdfPig asks for it before it can decrypt an object stream.
            for (int n = 1; n <= _items.Count; n++)
            {
                if (n != root && _items[n - 1] is not PdfStream && !(_items[n - 1] is PdfDictionary d && PdfDocument.IsSignature(d))) packed.Add(n);
            }
        }
        var packedSet = packed.ToHashSet();
        int next = _items.Count + 1;
        int firstStream = next;
        next += (packed.Count + ObjectsPerStream - 1) / ObjectsPerStream;
        int encryptNumber = security is null ? 0 : next++;
        int xrefNumber = options.UseObjectStreams ? next++ : 0;

        var output = new MemoryStream();
        var writer = new PdfObjectWriter(output, 0, security);
        writer.WriteHeader(HeaderVersion());
        var entries = new List<XrefEntry> { new(0, 0, 0, 65535) };

        for (int n = 1; n <= _items.Count; n++)
        {
            if (packedSet.Contains(n)) continue;
            long at;
            if (_items[n - 1] is PdfStream stream)
            {
                var dictionary = RemapDictionary(stream.Dictionary, true);
                bool dropped = !ReferenceEquals(security, document.Security) && DropCrypt(stream, dictionary);
                var view = security is null || dropped ? null : document.CryptView(stream.Dictionary);
                at = writer.WriteStream(n, 0, dictionary, Stored(stream, dictionary), cryptView: view);
            }
            else
            {
                at = writer.WriteObject(n, 0, Remap(_items[n - 1]));
            }
            entries.Add(new XrefEntry(n, 1, at, 0));
        }
        for (int s = 0; s * ObjectsPerStream < packed.Count; s++)
        {
            var members = packed.Skip(s * ObjectsPerStream).Take(ObjectsPerStream).ToList();
            int number = firstStream + s;
            var (dictionary, data) = Pack(members);
            entries.Add(new XrefEntry(number, 1, writer.WriteStream(number, 0, dictionary, data), 0));
            for (int i = 0; i < members.Count; i++) entries.Add(new XrefEntry(members[i], 2, number, i));
        }
        if (security is not null)
        {
            entries.Add(new XrefEntry(encryptNumber, 1, writer.WriteObject(encryptNumber, 0, security.Dictionary, encrypt: false), 0));
        }

        var trailer = new PdfDictionary();
        trailer.Add("Size", new PdfNumber(next));
        trailer.Add("Root", new PdfReference(root, 0));
        if (info > 0) trailer.Add("Info", new PdfReference(info, 0));
        if (security is not null) trailer.Add("Encrypt", new PdfReference(encryptNumber, 0));
        trailer.Add("ID", PdfXrefWriter.IdPair(FirstId()));
        entries.Sort((a, b) => a.Number.CompareTo(b.Number));
        if (xrefNumber > 0) PdfXrefWriter.WriteStream(writer, xrefNumber, entries, trailer, compress: true);
        else PdfXrefWriter.WriteTable(writer, entries, trailer);
        return output.ToArray();
    }

    private void Follow()
    {
        for (; _followed < _items.Count; _followed++)
        {
            if (_items[_followed] is PdfStream stream) Visit(stream.Dictionary, true);
            else Visit(_items[_followed], false);
        }
    }

    /// <summary>A new handler has no crypt filters of the old one's names, so the stream's Crypt stage goes; the data is already decrypted.</summary>
    private bool DropCrypt(PdfStream stream, PdfDictionary dictionary)
    {
        var (filter, parameters, crypt) = document.DecodeSpec(stream);
        if (!crypt) return false;
        dictionary.Remove("DecodeParms");
        if (filter is null or PdfArray { Items.Count: 0 })
        {
            dictionary.Remove("Filter");
            return true;
        }
        dictionary["Filter"] = Remap(filter);
        if (parameters is not (null or PdfNull)) dictionary["DecodeParms"] = Remap(parameters);
        return true;
    }

    /// <summary>The number the object <paramref name="entry"/> names or is gets in the new file; 0 for nothing there.</summary>
    private int Intern(PdfObject? entry)
    {
        if (entry is PdfReference reference)
        {
            if (_numbers.TryGetValue(reference.Number, out int known)) return known;
            if (document.Get(reference.Number) is not { } value || value is PdfNull) return 0;
            _items.Add(value);
            return _numbers[reference.Number] = _items.Count;
        }
        if (document.Resolve(entry) is not { } direct) return 0;
        _items.Add(direct);
        return _items.Count;
    }

    /// <summary>Numbers the objects a value refers to. A stream's /Length is not followed: it is written afresh.</summary>
    private void Visit(PdfObject value, bool stream)
    {
        switch (value)
        {
            case PdfReference:
                Intern(value);
                break;
            case PdfArray array:
                foreach (var item in array.Items) Visit(item, false);
                break;
            case PdfDictionary dictionary:
                foreach (var (key, item) in dictionary.Entries)
                {
                    if (!(stream && key == "Length")) Visit(item, false);
                }
                break;
        }
    }

    /// <summary>The value with its references renumbered; one to an object that is not there is dropped from a dictionary and null in an array.</summary>
    private PdfObject Remap(PdfObject value) => value switch
    {
        PdfReference reference => _numbers.TryGetValue(reference.Number, out int n) ? new PdfReference(n, 0) : PdfNull.Instance,
        PdfArray array => new PdfArray([.. array.Items.Select(Remap)]),
        PdfDictionary dictionary => RemapDictionary(dictionary, false),
        // A stream the flattened parameters met (/JBIG2Globals) is written as the reference it came from.
        PdfStream stream => _numbers.TryGetValue(stream.Number, out int n) ? new PdfReference(n, 0) : PdfNull.Instance,
        _ => value,
    };

    private PdfDictionary RemapDictionary(PdfDictionary source, bool stream)
    {
        var copy = new PdfDictionary();
        foreach (var (key, item) in source.Entries)
        {
            if (!ReferenceEquals(source[key], item) || (stream && key == "Length")) continue;
            var mapped = Remap(item);
            if (mapped is not PdfNull) copy.Add(key, mapped);
        }
        return copy;
    }

    private (PdfDictionary Dictionary, byte[] Data) Pack(List<int> members)
    {
        var header = new StringBuilder();
        var body = new MemoryStream();
        var bodyWriter = new PdfObjectWriter(body);
        foreach (int number in members)
        {
            header.Append(number).Append(' ').Append(body.Length).Append(' ');
            bodyWriter.WriteDirect(Remap(_items[number - 1]));
            bodyWriter.WriteAscii("\n");
        }
        byte[] first = Encoding.Latin1.GetBytes(header.ToString());
        var dictionary = new PdfDictionary();
        dictionary.Add("Type", new PdfName("ObjStm"));
        dictionary.Add("N", new PdfNumber(members.Count));
        dictionary.Add("First", new PdfNumber(first.Length));
        dictionary.Add("Filter", new PdfName("FlateDecode"));
        return (dictionary, PdfFilterEncoders.Flate([.. first, .. body.ToArray()]));
    }

    /// <summary>
    /// The data to store for a stream. What is not compressed, or only by the old text filters, is
    /// deflated when that is smaller. A stream with a predictor is left (deflating without it
    /// would lose more than it gains), as are Flate streams already, metadata, and image data,
    /// which is never touched.
    /// </summary>
    private byte[] Stored(PdfStream stream, PdfDictionary dictionary)
    {
        byte[] raw = document.RawData(stream);
        if (!CanRepack(stream.Dictionary)) return raw;
        byte[] plain;
        try
        {
            plain = document.Data(stream, PdfFilters.DefaultMaxSize, strict: true);
        }
        catch (PdfReadException)
        {
            return raw;
        }
        byte[] deflated = PdfFilterEncoders.Flate(plain);
        if (deflated.Length >= raw.Length) return raw;
        dictionary["Filter"] = new PdfName("FlateDecode");
        dictionary.Remove("DecodeParms");
        return deflated;
    }

    private bool CanRepack(PdfDictionary dictionary)
    {
        if (document.Name(dictionary, "Type") is "Metadata" or "XRef" or "ObjStm") return false;
        List<string> filters = document.Resolve(dictionary["Filter"]) switch
        {
            null => [],
            PdfName name => [name.Value],
            PdfArray array => [.. array.Items.Select(i => (document.Resolve(i) as PdfName)?.Value ?? "")],
            _ => [""],
        };
        if (filters.Count == 1 && filters[0] is "FlateDecode" or "Fl") return false;
        if (!filters.All(f => Repackable.Contains(f))) return false;
        var parameters = document.Resolve(dictionary["DecodeParms"]);
        IEnumerable<PdfObject?> each = parameters is PdfArray list ? list.Items : new[] { parameters };
        return !each.Any(p => document.Integer(document.Resolve(p) as PdfDictionary, "Predictor") > 1);
    }

    private byte[] FirstId()
    {
        // The keys of the older handlers are made from the first string, so a kept handler keeps it.
        if (options.Security is not null && ReferenceEquals(options.Security, document.Security)) return document.FirstId ?? [];
        // The first string names the document across its versions (ISO 32000-1 14.4.1).
        if (options.DocumentId is null && options.Security is null && document.FirstId is { Length: > 0 } kept) return kept;
        return options.DocumentId ?? RandomNumberGenerator.GetBytes(16);
    }

    private string HeaderVersion()
    {
        string version = document.Version;
        if (options.UseObjectStreams) version = Raised(version, "1.5");
        if (options.Security is { Revision: >= 5 }) version = Raised(version, "1.7");
        else if (options.Security is { Revision: 4 }) version = Raised(version, "1.6");
        return version;
    }

    private static string Raised(string version, string least) =>
        Version.TryParse(version, out var v) && v >= Version.Parse(least) ? version : least;
}
