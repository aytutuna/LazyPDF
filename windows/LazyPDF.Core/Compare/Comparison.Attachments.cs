using System.Security.Cryptography;

namespace LazyPDF.Core;

internal sealed partial class Comparison
{
    private const long MaxAttachmentBytes = 64L << 20;
    private const long AttachmentBudget = 256L << 20;

    /// <summary>A file name used twice keeps its later files under "name (2)", "name (3)".</summary>
    private Dictionary<string, PdfStream> Attachments(PdfDocument document)
    {
        var result = new Dictionary<string, PdfStream>();
        var used = new Dictionary<string, int>();
        foreach (var attachment in PdfAttachments.List(document))
        {
            _cancellation.ThrowIfCancellationRequested();
            if (PdfAttachments.StreamOf(document, attachment) is not { } stream) continue;
            string file = attachment.FileName;
            int n = used.GetValueOrDefault(file, 1);
            string name = file;
            while (result.ContainsKey(name)) name = $"{file} ({++n})";
            used[file] = n;
            result[name] = stream;
        }
        return result;
    }

    private static Dictionary<string, string> Stored(PdfDocument document, Dictionary<string, PdfStream> streams)
    {
        var known = new Dictionary<PdfStream, string>(ReferenceEqualityComparer.Instance);
        var result = new Dictionary<string, string>();
        foreach (var (name, stream) in streams)
        {
            if (!known.TryGetValue(stream, out string? text))
            {
                byte[] stored = document.RawData(stream);
                known[stream] = text = $"{stored.Length} bytes stored, {Convert.ToHexString(SHA256.HashData(stored), 0, 6)}";
            }
            result[name] = text;
        }
        return result;
    }

    /// <summary>
    /// The decoded content of the files, null for one that is larger than the cap, over the budget, or does not decode.
    /// A stream shared by several specifications is read once; a failed decode is charged its full limit, since
    /// it may have run to the limit before it gave up.
    /// </summary>
    private Dictionary<string, string?> Decoded(PdfDocument document, Dictionary<string, PdfStream> streams, HashSet<string> skip)
    {
        var known = new Dictionary<PdfStream, string?>(ReferenceEqualityComparer.Instance);
        var result = new Dictionary<string, string?>();
        long budget = AttachmentBudget;
        foreach (var (name, stream) in streams)
        {
            if (skip.Contains(name)) continue;
            _cancellation.ThrowIfCancellationRequested();
            if (!known.TryGetValue(stream, out string? text)) known[stream] = text = Decode(document, stream, ref budget);
            result[name] = text;
        }
        return result;
    }

    private static string? Decode(PdfDocument document, PdfStream stream, ref long budget)
    {
        long limit = Math.Min(MaxAttachmentBytes, budget);
        if (limit <= 0) return null;
        try
        {
            byte[] data = document.Data(stream, limit);
            if (data.Length > limit) return null;
            budget -= data.Length;
            return $"{data.Length} bytes, {Convert.ToHexString(SHA256.HashData(data), 0, 6)}";
        }
        catch (PdfReadException)
        {
            budget -= limit;
            return null;
        }
    }

    /// <summary>
    /// A name whose stored bytes are equal on both sides is the same file and costs no decoding. Of the others, a file that one
    /// side could not decode is judged by its stored bytes on both sides, so the budget used by other attachments cannot
    /// make the two sides disagree on how to read it. A file stored differently on the two sides and too large to decode on
    /// either is reported as changed.
    /// </summary>
    private void CompareAttachments(List<CompareChange> changes)
    {
        var before = Attachments(_before);
        var after = Attachments(_after);
        var storedBefore = Stored(_before, before);
        var storedAfter = Stored(_after, after);
        var same = storedBefore.Where(p => storedAfter.TryGetValue(p.Key, out string? other) && other == p.Value).Select(p => p.Key).ToHashSet();
        var decodedBefore = Decoded(_before, before, same);
        var decodedAfter = Decoded(_after, after, same);
        Dictionary<string, string?> Texts(Dictionary<string, string> stored, Dictionary<string, string?> decoded, Dictionary<string, string?> other) =>
            decoded.ToDictionary(p => p.Key, p => (string?)(p.Value is { } text && (!other.TryGetValue(p.Key, out string? o) || o is not null) ? text : stored[p.Key]));
        CompareValues(Texts(storedBefore, decodedBefore, decodedAfter), Texts(storedAfter, decodedAfter, decodedBefore), name => $"{CompareText.Attachment} {name}", changes);
    }
}
