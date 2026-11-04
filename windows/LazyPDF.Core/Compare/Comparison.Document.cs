using System.Globalization;
using System.Security.Cryptography;

namespace LazyPDF.Core;

internal sealed partial class Comparison
{
    private const long MaxAttachmentBytes = 64L << 20;
    private const long AttachmentBudget = 256L << 20;

    private void CompareDocuments(List<PagePair> pairs, List<CompareChange> changes)
    {
        CompareMetadata(changes);
        CompareBookmarks(pairs, changes);
        CompareAttachments(changes);
        CompareForms(changes);
    }

    private static CompareChange Document(ChangeKind kind, string? oldText, string? newText, string detail) =>
        new(kind, ChangeArea.Document, -1, -1, oldText ?? "", newText ?? "", [], [], detail);

    /// <summary>One change for each value that differs between two keyed lists.</summary>
    private static void CompareValues(IReadOnlyDictionary<string, string?> before, IReadOnlyDictionary<string, string?> after, Func<string, string> detail, List<CompareChange> changes)
    {
        foreach (var (key, value) in after)
        {
            before.TryGetValue(key, out string? old);
            if (string.IsNullOrEmpty(old) && string.IsNullOrEmpty(value)) continue;
            if (string.IsNullOrEmpty(old)) changes.Add(Document(ChangeKind.Added, null, value, detail(key)));
            else if (string.IsNullOrEmpty(value)) changes.Add(Document(ChangeKind.Removed, old, null, detail(key)));
            else if (old != value) changes.Add(Document(ChangeKind.Changed, old, value, detail(key)));
        }
        foreach (var (key, old) in before)
        {
            if (!after.ContainsKey(key) && !string.IsNullOrEmpty(old)) changes.Add(Document(ChangeKind.Removed, old, null, detail(key)));
        }
    }

    private void CompareMetadata(List<CompareChange> changes)
    {
        static Dictionary<string, string?> Fields(PdfDocument document)
        {
            var m = DocumentMetadata.Read(document);
            var fields = new Dictionary<string, string?>
            {
                ["Title"] = m.Title,
                ["Author"] = m.Author,
                ["Subject"] = m.Subject,
                ["Keywords"] = m.Keywords,
                ["Creator"] = m.Creator,
                ["Producer"] = m.Producer,
                ["Created"] = m.Created?.UtcDateTime.ToString("yyyy-MM-dd HH:mm:ss'Z'", CultureInfo.InvariantCulture),
                ["Modified"] = m.Modified?.UtcDateTime.ToString("yyyy-MM-dd HH:mm:ss'Z'", CultureInfo.InvariantCulture),
            };
            foreach (var (key, value) in m.Custom) fields[key] = value;
            return fields;
        }
        CompareValues(Fields(_before), Fields(_after), CompareText.Metadata, changes);
    }

    private void CompareBookmarks(List<PagePair> pairs, List<CompareChange> changes)
    {
        var before = Flatten(Outline.Read(_before).Root, 0);
        var after = Flatten(Outline.Read(_after).Root, 0);
        if (before.Count == 0 && after.Count == 0) return;
        var ids = new Dictionary<string, int>();
        int Id(Bookmark b) => ids.TryGetValue($"{b.Level}\t{b.Title}", out int id) ? id : ids[$"{b.Level}\t{b.Title}"] = ids.Count;
        int[] a = [.. before.Select(Id)], b = [.. after.Select(Id)];
        string Titles(List<Bookmark> list, int from, int count) => string.Join("; ", list.Skip(from).Take(count).Select(x => x.Title));

        var hunks = SequenceDiff.Diff(a, b);
        foreach (var h in hunks)
        {
            var kind = h.OldCount == 0 ? ChangeKind.Added : h.NewCount == 0 ? ChangeKind.Removed : ChangeKind.Changed;
            changes.Add(Document(kind, Titles(before, h.OldStart, h.OldCount), Titles(after, h.NewStart, h.NewCount), CompareText.Bookmark));
        }

        var newOf = pairs.Where(p => p.OldIndex >= 0 && p.NewIndex >= 0).ToDictionary(p => p.OldIndex, p => p.NewIndex);
        int i = 0, j = 0;
        void Equal(int x, int y)
        {
            if (before[x].Page < 0 || after[y].Page < 0) return;
            if (!newOf.TryGetValue(before[x].Page, out int mapped) || mapped != after[y].Page)
                changes.Add(Document(ChangeKind.Changed, before[x].Title, after[y].Title, CompareText.BookmarkPage));
        }
        foreach (var h in hunks)
        {
            while (i < h.OldStart) Equal(i++, j++);
            (i, j) = (h.OldStart + h.OldCount, h.NewStart + h.NewCount);
        }
        while (i < before.Count) Equal(i++, j++);
    }

    private readonly record struct Bookmark(int Level, string Title, int Page);

    private static List<Bookmark> Flatten(OutlineItem parent, int level)
    {
        var list = new List<Bookmark>();
        foreach (var item in parent.Children)
        {
            list.Add(new Bookmark(level, item.Title, item.Destination?.PageIndex ?? -1));
            list.AddRange(Flatten(item, level + 1));
        }
        return list;
    }

    /// <param name="Decoded">The decoded file; null when it is too large, over the budget, or does not decode.</param>
    private sealed record Attachment(string? Decoded, string Stored);

    /// <summary>A file name used twice keeps its second file under "name (2)".</summary>
    private Dictionary<string, Attachment> Attachments(PdfDocument document)
    {
        var result = new Dictionary<string, Attachment>();
        var known = new Dictionary<PdfStream, Attachment>(ReferenceEqualityComparer.Instance);
        long budget = AttachmentBudget;
        foreach (var attachment in PdfAttachments.List(document))
        {
            _cancellation.ThrowIfCancellationRequested();
            if (PdfAttachments.StreamOf(document, attachment) is not { } stream) continue;
            string name = attachment.FileName;
            for (int n = 2; result.ContainsKey(name); n++) name = $"{attachment.FileName} ({n})";
            if (!known.TryGetValue(stream, out var fingerprint)) known[stream] = fingerprint = Fingerprint(document, stream, ref budget);
            result[name] = fingerprint;
        }
        return result;
    }

    // A failed decode is charged in full: it may have run to the limit before it gave up.
    private static Attachment Fingerprint(PdfDocument document, PdfStream stream, ref long budget)
    {
        byte[] stored = document.RawData(stream);
        string storedText = $"{stored.Length} bytes stored, {Convert.ToHexString(SHA256.HashData(stored), 0, 6)}";
        long limit = Math.Min(MaxAttachmentBytes, budget);
        if (limit <= 0) return new Attachment(null, storedText);
        try
        {
            byte[] data = document.Data(stream, limit);
            if (data.Length > limit) return new Attachment(null, storedText);
            budget -= data.Length;
            return new Attachment($"{data.Length} bytes, {Convert.ToHexString(SHA256.HashData(data), 0, 6)}", storedText);
        }
        catch (PdfReadException)
        {
            budget -= limit;
            return new Attachment(null, storedText);
        }
    }

    /// <summary>A file that one side could not decode is judged by its stored bytes on both sides, so that the budget used by other attachments cannot make an unchanged file differ.</summary>
    private void CompareAttachments(List<CompareChange> changes)
    {
        var before = Attachments(_before);
        var after = Attachments(_after);
        Dictionary<string, string?> Texts(Dictionary<string, Attachment> side, Dictionary<string, Attachment> other) =>
            side.ToDictionary(p => p.Key, p => (string?)(p.Value.Decoded is { } text && (!other.TryGetValue(p.Key, out var o) || o.Decoded is not null) ? text : p.Value.Stored));
        CompareValues(Texts(before, after), Texts(after, before), name => $"{CompareText.Attachment} {name}", changes);
    }

    private void CompareForms(List<CompareChange> changes)
    {
        static Dictionary<string, string?> Values(PdfDocument document) =>
            PdfForm.Read(document).Fields.Where(f => f.Kind != FieldKind.Signature).GroupBy(f => f.Name).ToDictionary(g => g.Key, g => g.First() is { Selected.Count: > 1 } f ? string.Join("; ", f.Selected) : g.First().Value);
        CompareValues(Values(_before), Values(_after), CompareText.FormField, changes);
    }
}
