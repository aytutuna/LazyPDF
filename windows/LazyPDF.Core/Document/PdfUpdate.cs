using System.Security.Cryptography;

namespace LazyPDF.Core;

// An incremental update (ISO 32000-1 7.5.6): the changed and new objects after the original bytes,
// then a cross-reference section of the kind the file already ends with.
internal static class PdfUpdate
{
    /// <summary>The bytes to append to the document's source; empty when nothing changed.</summary>
    public static byte[] Build(PdfDocument document)
    {
        var changed = document.ChangedObjects();
        var freed = document.DeletedObjects;
        if (changed.Count == 0 && freed.Count == 0 && !document.TrailerChanged) return [];

        var source = document.Source.Span;
        var output = new MemoryStream();
        // The update starts on a line of its own.
        if (source.Length > 0 && source[^1] is not (10 or 13)) output.WriteByte(10);
        var writer = new PdfObjectWriter(output, source.Length + output.Length, document.Security);

        var entries = new List<XrefEntry>();
        foreach (int number in changed)
        {
            // Objects that came from an object stream are written as plain objects.
            var value = document.Get(number)!;
            int generation = document.GenerationOf(number);
            bool plain = number == document.EncryptNumber;
            long at = value is PdfStream stream
                ? writer.WriteStream(number, generation, stream.Dictionary, document.RawData(stream), !plain, document.Security is null ? null : document.CryptView(stream.Dictionary))
                : writer.WriteObject(number, generation, value, !plain);
            entries.Add(new XrefEntry(number, 1, at, generation));
        }
        for (int i = 0; i < freed.Count; i++)
        {
            entries.Add(new XrefEntry(freed[i], 0, i + 1 < freed.Count ? freed[i + 1] : 0, document.GenerationOf(freed[i])));
        }
        if (freed.Count > 0) entries.Add(new XrefEntry(0, 0, freed[0], 65535));

        // After a rebuild the file's own sections cannot be built on, so this one lists everything.
        bool full = document.XrefRebuilt;
        if (full)
        {
            var written = new HashSet<int>(entries.Select(e => e.Number));
            foreach (var (number, entry) in document.Entries)
            {
                if (written.Contains(number)) continue;
                switch (entry.Kind)
                {
                    case PdfDocument.EntryKind.InUse:
                        entries.Add(new XrefEntry(number, 1, entry.Offset, entry.Generation));
                        break;
                    case PdfDocument.EntryKind.Compressed:
                        entries.Add(new XrefEntry(number, 2, entry.StreamNumber, document.IndexInObjectStream(number)));
                        break;
                }
            }
            if (freed.Count == 0) entries.Add(new XrefEntry(0, 0, 0, 65535));
        }
        // Only the trailer changed.
        if (entries.Count == 0) entries.Add(new XrefEntry(0, 0, 0, 65535));
        entries.Sort((a, b) => a.Number.CompareTo(b.Number));

        bool asStream = document.XrefIsStream || entries.Any(e => e.Type == 2);
        int size = Math.Max(document.NextObjectNumber, entries[^1].Number + 1);
        // The cross-reference stream is an object too, and PDF has no number past the limit for it.
        if (asStream && size > PdfDocument.MaxObjectNumber) throw new InvalidOperationException("The file has no object numbers left.");
        var trailer = new PdfDictionary();
        trailer.Add("Size", new PdfNumber(asStream ? size + 1 : size));
        foreach (var (key, value) in document.Trailer.Entries)
        {
            if (key is not ("Size" or "Prev" or "XRefStm" or "ID")) trailer.Add(key, value);
        }
        if (document.InfoRemoved) trailer.Add("Info", PdfNull.Instance);
        trailer.Add("ID", PdfXrefWriter.IdPair(document.FirstId ?? RandomNumberGenerator.GetBytes(16)));
        if (!full) trailer.Add("Prev", new PdfNumber(document.StartXref));

        if (asStream) PdfXrefWriter.WriteStream(writer, size, entries, trailer, compress: false);
        else PdfXrefWriter.WriteTable(writer, entries, trailer);
        return output.ToArray();
    }
}
