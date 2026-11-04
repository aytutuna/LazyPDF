using LazyPDF.Core;

namespace LazyPDF.App.Viewer;

/// <summary>
/// Which pages a commit, an undo or a redo can have changed. An edit session only ever appends to its buffer
/// or cuts back to an earlier end, so the objects that differ are the ones defined in the stretch by which the
/// longer buffer exceeds the shorter.
/// </summary>
public static class RevisionDiff
{
    private const int MaxObjects = 5000;

    // Keys that lead away from the page: up to the page tree and sideways to other pages. They mean that only in the
    // dictionaries of the page, its annotations and structure; in a resource dictionary a key is any name.
    private static readonly HashSet<string> Away = ["Parent", "P", "Prev", "Next", "StructParent", "StructParents", "Dest", "A", "AA", "Popup", "IRT"];

    /// <summary>
    /// The numbers of the objects defined in the part of one buffer that the other does not have, or null when
    /// neither buffer begins with the other (the file was rewritten) and everything counts as changed.
    /// </summary>
    public static HashSet<int>? Changed(ReadOnlySpan<byte> before, ReadOnlySpan<byte> after)
    {
        var shorter = before.Length <= after.Length ? before : after;
        var longer = before.Length <= after.Length ? after : before;
        if (!longer.StartsWith(shorter)) return null;
        var numbers = new HashSet<int>();
        var tail = longer[shorter.Length..];
        ReadOnlySpan<byte> marker = " obj"u8;
        for (int at = 0; at < tail.Length;)
        {
            int found = tail[at..].IndexOf(marker);
            if (found < 0) break;
            int end = at + found;
            at = end + marker.Length;
            // "12 0 obj": the generation, a space, then the number.
            int i = end - 1;
            while (i >= 0 && tail[i] is >= (byte)'0' and <= (byte)'9') i--;
            if (i < 0 || i == end - 1 || tail[i] != ' ') continue;
            int j = i - 1;
            int stop = j;
            while (j >= 0 && tail[j] is >= (byte)'0' and <= (byte)'9') j--;
            if (j == stop || stop - j > 9) continue;
            if (int.TryParse(System.Text.Encoding.ASCII.GetString(tail[(j + 1)..(stop + 1)]), out int number)) numbers.Add(number);
        }
        return numbers;
    }

    /// <summary>
    /// Whether the page, or anything it draws with (contents, resources, annotations and what those lead to),
    /// or a page tree node it inherits from, is among <paramref name="changed"/>.
    /// </summary>
    public static bool Touches(PdfDocument document, PdfPage page, HashSet<int> changed)
    {
        if (document.Trailer["Root"] is PdfReference root && changed.Contains(root.Number)) return true;
        if (changed.Contains(page.Reference.Number)) return true;
        var node = page.Dictionary;
        for (int depth = 0; depth < 32 && node is not null; depth++)
        {
            if (node["Parent"] is PdfReference up && changed.Contains(up.Number)) return true;
            node = document.Dict(node, "Parent");
        }
        var seen = new HashSet<int>();
        var queue = new Queue<(PdfObject Value, bool Resources)>();
        queue.Enqueue((page.Dictionary, false));
        while (queue.Count > 0)
        {
            // A walk that stops short may have missed the change, and a picture that is too old stays on screen.
            if (seen.Count >= MaxObjects) return true;
            var (value, resources) = queue.Dequeue();
            switch (value)
            {
                case PdfReference reference:
                    if (!seen.Add(reference.Number)) break;
                    if (changed.Contains(reference.Number)) return true;
                    if (document.Get(reference.Number) is { } target) queue.Enqueue((target, resources));
                    break;
                case PdfStream stream:
                    queue.Enqueue((stream.Dictionary, resources));
                    break;
                case PdfDictionary dictionary:
                    // A form field's value, which a widget without an appearance is drawn from, can sit on a parent field.
                    if (!resources && document.Name(dictionary, "Subtype") == "Widget" && WidgetParentChanged(document, dictionary, changed)) return true;
                    foreach (var (key, item) in dictionary.Entries)
                    {
                        if (resources || !Away.Contains(key)) queue.Enqueue((item, resources || key == "Resources"));
                    }
                    break;
                case PdfArray array:
                    foreach (var item in array.Items) queue.Enqueue((item, resources));
                    break;
            }
        }
        return false;
    }

    private static bool WidgetParentChanged(PdfDocument document, PdfDictionary widget, HashSet<int> changed)
    {
        var node = widget;
        for (int depth = 0; depth < 32 && node is not null; depth++)
        {
            if (node["Parent"] is PdfReference up && changed.Contains(up.Number)) return true;
            node = document.Dict(node, "Parent");
        }
        return false;
    }
}
