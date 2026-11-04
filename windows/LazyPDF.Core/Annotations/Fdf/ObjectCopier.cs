namespace LazyPDF.Core;

/// <summary>
/// Copies a value and everything it refers to from one object space into another (a document into an
/// FDF file or the other way round), once per source object, cycles included.
/// </summary>
internal sealed class ObjectCopier(Func<PdfObject?, PdfObject?> resolve, Func<PdfStream, byte[]> rawData,
    Func<PdfReference> reserve, Action<PdfReference, PdfObject> store)
{
    private const int MaxObjects = 100_000;
    private const int MaxDepth = 64;

    private readonly Dictionary<int, PdfReference> _map = [];
    private int _count;

    /// <summary>Says that source object <paramref name="number"/> is already <paramref name="target"/> over there.</summary>
    public void Preload(int number, PdfReference target) => _map[number] = target;

    public PdfObject Copy(PdfObject value, int depth = 0)
    {
        if (depth > MaxDepth) return PdfNull.Instance;
        switch (value)
        {
            case PdfReference reference:
            {
                if (_map.TryGetValue(reference.Number, out var mapped)) return mapped;
                if (_count >= MaxObjects || resolve(reference) is not { } source) return PdfNull.Instance;
                _count++;
                var target = reserve();
                _map[reference.Number] = target;
                store(target, Copy(source, depth + 1));
                return target;
            }
            case PdfDictionary dictionary:
                return CopyDictionary(dictionary, depth);
            case PdfArray array:
                return new PdfArray([.. array.Items.Select(i => Copy(i, depth + 1))]);
            case PdfStream stream:
            {
                var dictionary = CopyDictionary(stream.Dictionary, depth);
                dictionary.Remove("Length");
                return new PdfStream(dictionary, rawData(stream));
            }
            case PdfString text:
                return new PdfString((byte[])text.Bytes.Clone(), text.IsHex);
            default:
                return value;
        }
    }

    private PdfDictionary CopyDictionary(PdfDictionary dictionary, int depth)
    {
        var copy = new PdfDictionary();
        foreach (var (key, item) in dictionary.Entries) copy[key] = Copy(item, depth + 1);
        return copy;
    }
}
