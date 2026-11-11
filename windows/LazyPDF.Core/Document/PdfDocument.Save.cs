namespace LazyPDF.Core;

// Saving: the two ways out (PdfUpdate and PdfRewriter hold the work) and what they need to know of the reader.
public sealed partial class PdfDocument
{
    /// <summary>
    /// The bytes read, then an update (ISO 32000-1 7.5.6) holding only what changed since: the
    /// objects that differ, the new ones, free entries for deleted ones and a new cross-reference
    /// section. The bytes read are untouched, which is what signatures rest on; anything before the
    /// %PDF header was cut off on reading and is not in them. With no change the result is the bytes read.
    /// </summary>
    public byte[] SaveIncremental()
    {
        byte[] update = PdfUpdate.Build(this);
        var source = Source.Span;
        byte[] file = new byte[source.Length + update.Length];
        source.CopyTo(file);
        update.CopyTo(file.AsSpan(source.Length));
        return file;
    }

    /// <summary>
    /// A new file of the objects reachable from the trailer, renumbered. Signatures do not survive it.
    /// Another handler than the file's own, or none, needs the owner's rights when the file restricts
    /// its permissions, and throws <see cref="PdfPermissionException"/> without them.
    /// </summary>
    public byte[] SaveRewrite(PdfSaveOptions? options = null)
    {
        options ??= new PdfSaveOptions();
        RequireEncryptionRights(options.Security);
        return new PdfRewriter(this, options).Run();
    }

    internal IReadOnlyDictionary<int, Entry> Entries => _entries;

    /// <summary>The file had an /Info and the trailer has none now. Readers fill a missing key in from an older trailer, so an update has to say it is gone.</summary>
    internal bool InfoRemoved => _hadInfo && !Trailer.ContainsKey("Info");

    /// <summary>The offsets of the cross-reference sections, newest first; empty after a rebuild.</summary>
    internal IReadOnlyList<long> SectionOffsets => XrefRebuilt ? [] : _sections;

    /// <summary>The number of the /Encrypt object, 0 when the dictionary is in the trailer or there is none.</summary>
    internal int EncryptNumber => _encryptNumber;

    /// <summary>Something differs from what was read: an object, the trailer, or an object freed.</summary>
    internal bool HasChanges => ChangedObjects().Count > 0 || _deleted.Count > 0 || TrailerChanged;

    /// <summary>The place of object <paramref name="number"/> in its object stream; 0 when that cannot be told.</summary>
    internal int IndexInObjectStream(int number)
    {
        if (!_entries.TryGetValue(number, out var entry) || entry.Kind != EntryKind.Compressed) return 0;
        return LoadObjectStream(entry.StreamNumber)?.NumberIndex.GetValueOrDefault(number) ?? 0;
    }
}
