using System.Text;

namespace LazyPDF.Core;

// Walks over the objects of an open document, without following references.
internal static class PdfGraph
{
    private const int MaxDepth = 64;

    /// <summary>The objects the document lists, as (number, value); free and unreadable ones are left out.</summary>
    public static List<(int Number, PdfObject Value)> Objects(PdfDocument document)
    {
        var list = new List<(int, PdfObject)>();
        foreach (int number in document.ObjectNumbers)
        {
            if (document.Get(number) is { } value and not PdfNull) list.Add((number, value));
        }
        return list;
    }

    /// <summary>Every dictionary inside <paramref name="root"/>, stream dictionaries and direct ones included, the root's own first.</summary>
    public static List<PdfDictionary> Dictionaries(PdfObject? root)
    {
        var found = new List<PdfDictionary>();
        var stack = new Stack<(PdfObject Value, int Depth)>();
        if (root is not null) stack.Push((root, 0));
        while (stack.Count > 0)
        {
            var (value, depth) = stack.Pop();
            if (depth > MaxDepth) continue;
            switch (value)
            {
                case PdfStream stream:
                    stack.Push((stream.Dictionary, depth));
                    break;
                case PdfDictionary dictionary:
                    found.Add(dictionary);
                    foreach (var (_, item) in dictionary.Entries) stack.Push((item, depth + 1));
                    break;
                case PdfArray array:
                    foreach (var item in array.Items) stack.Push((item, depth + 1));
                    break;
            }
        }
        return found;
    }

    /// <summary>Every dictionary in the file, indirect or not, in object order.</summary>
    public static List<PdfDictionary> AllDictionaries(PdfDocument document)
    {
        var all = new List<PdfDictionary>();
        foreach (var (_, value) in Objects(document)) all.AddRange(Dictionaries(value));
        all.AddRange(Dictionaries(document.Trailer));
        return all;
    }

    /// <summary>The references written inside <paramref name="root"/>.</summary>
    public static IEnumerable<PdfReference> References(PdfObject? root)
    {
        var stack = new Stack<(PdfObject Value, int Depth)>();
        if (root is not null) stack.Push((root, 0));
        while (stack.Count > 0)
        {
            var (value, depth) = stack.Pop();
            if (depth > MaxDepth) continue;
            switch (value)
            {
                case PdfReference reference:
                    yield return reference;
                    break;
                case PdfStream stream:
                    stack.Push((stream.Dictionary, depth));
                    break;
                case PdfDictionary dictionary:
                    foreach (var (_, item) in dictionary.Entries) stack.Push((item, depth + 1));
                    break;
                case PdfArray array:
                    foreach (var item in array.Items) stack.Push((item, depth + 1));
                    break;
            }
        }
    }

    /// <summary>Points every reference to a key of <paramref name="map"/> at its value, in every object and the trailer.</summary>
    public static void Redirect(PdfDocument document, IReadOnlyDictionary<int, int> map)
    {
        if (map.Count == 0) return;
        foreach (var (_, value) in Objects(document)) RedirectIn(value, map);
        RedirectIn(document.Trailer, map);
    }

    private static void RedirectIn(PdfObject root, IReadOnlyDictionary<int, int> map)
    {
        foreach (var container in ContainersOf(root))
        {
            if (container is PdfDictionary dictionary)
            {
                foreach (var (key, item) in dictionary.Entries.ToArray())
                {
                    if (item is PdfReference r && map.TryGetValue(r.Number, out int to)) dictionary[key] = new PdfReference(to, 0);
                }
            }
            else if (container is PdfArray array)
            {
                for (int i = 0; i < array.Items.Count; i++)
                {
                    if (array.Items[i] is PdfReference r && map.TryGetValue(r.Number, out int to)) array.Items[i] = new PdfReference(to, 0);
                }
            }
        }
    }

    /// <summary>The dictionaries and arrays inside <paramref name="root"/>, its own first.</summary>
    public static List<PdfObject> ContainersOf(PdfObject root)
    {
        var found = new List<PdfObject>();
        var stack = new Stack<(PdfObject Value, int Depth)>();
        stack.Push((root, 0));
        while (stack.Count > 0)
        {
            var (value, depth) = stack.Pop();
            if (depth > MaxDepth) continue;
            switch (value)
            {
                case PdfStream stream:
                    stack.Push((stream.Dictionary, depth));
                    break;
                case PdfDictionary dictionary:
                    found.Add(dictionary);
                    foreach (var (_, item) in dictionary.Entries) stack.Push((item, depth + 1));
                    break;
                case PdfArray array:
                    found.Add(array);
                    foreach (var item in array.Items) stack.Push((item, depth + 1));
                    break;
            }
        }
        return found;
    }

    /// <summary>Takes the references to <paramref name="numbers"/> out of every dictionary (the entry goes) and array (the item goes).</summary>
    public static void Detach(PdfDocument document, IReadOnlySet<int> numbers)
    {
        if (numbers.Count == 0) return;
        foreach (var (_, value) in Objects(document))
        {
            foreach (var container in ContainersOf(value))
            {
                if (container is PdfDictionary dictionary)
                {
                    foreach (var (key, item) in dictionary.Entries.ToArray())
                    {
                        if (item is PdfReference r && numbers.Contains(r.Number)) dictionary.Remove(key);
                    }
                }
                else if (container is PdfArray array)
                {
                    array.Items.RemoveAll(item => item is PdfReference r && numbers.Contains(r.Number));
                }
            }
        }
    }

    /// <summary>The dictionary's text with references named by <paramref name="name"/>, entries sorted, /Length left out for a stream.</summary>
    public static string Canonical(PdfObject value, Func<int, int> name, bool skipLength)
    {
        var text = new StringBuilder();
        Write(text, value, name, skipLength, 0);
        return text.ToString();
    }

    private static void Write(StringBuilder text, PdfObject value, Func<int, int> name, bool skipLength, int depth)
    {
        if (depth > MaxDepth)
        {
            text.Append('~');
            return;
        }
        switch (value)
        {
            case PdfReference reference:
                text.Append('R').Append(name(reference.Number)).Append(' ');
                break;
            case PdfStream stream:
                Write(text, stream.Dictionary, name, true, depth);
                break;
            case PdfDictionary dictionary:
                text.Append("<<");
                foreach (var key in dictionary.Entries.Select(e => e.Key).Distinct().Order(StringComparer.Ordinal))
                {
                    if (skipLength && key == "Length") continue;
                    text.Append('/').Append(key).Append(' ');
                    Write(text, dictionary[key]!, name, false, depth + 1);
                }
                text.Append(">>");
                break;
            case PdfArray array:
                text.Append('[');
                foreach (var item in array.Items) Write(text, item, name, false, depth + 1);
                text.Append(']');
                break;
            case PdfString s:
                text.Append('(').Append(Convert.ToHexString(s.Bytes)).Append(')');
                break;
            default:
                value.WriteTo(text);
                text.Append(' ');
                break;
        }
    }

    /// <summary>Gives a stream new content, deflated when that is smaller; its old filter and parameters go.</summary>
    public static void SetData(PdfStream stream, byte[] data)
    {
        byte[] packed = PdfFilterEncoders.Flate(data, System.IO.Compression.CompressionLevel.SmallestSize);
        stream.Dictionary.Remove("DecodeParms");
        if (packed.Length < data.Length)
        {
            stream.Data = packed;
            stream.Dictionary["Filter"] = new PdfName("FlateDecode");
        }
        else
        {
            stream.Data = data;
            stream.Dictionary.Remove("Filter");
        }
    }

    /// <summary>Bytes an object takes in a file, near enough for counting: its text, and a stream's stored data.</summary>
    public static long SizeOf(PdfDocument document, PdfObject value)
    {
        var text = new StringBuilder();
        Write(text, value is PdfStream s ? s.Dictionary : value, n => n, false, 0);
        long size = text.Length + 20;
        if (value is PdfStream stream) size += document.RawData(stream).Length + 18;
        return size;
    }
}
