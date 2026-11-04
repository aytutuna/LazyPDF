namespace LazyPDF.Core;

// Ranges of character codes with a value, searched by binary search. A code is keyed with its byte
// length, since <41> and <0041> are different codes in a CMap with mixed code lengths.
internal sealed class CodeRanges<T>
{
    // Overlapping ranges are a defect of the file; looking a few back finds the one nested in a wider one.
    const int OverlapProbe = 4;

    readonly record struct Range(ulong Lo, ulong Hi, int Order, T Value);

    readonly List<Range> _added = [];
    Range[] _sorted = [];

    public int Count => _added.Count + _sorted.Length;

    public int LengthMask { get; private set; }

    public void Add(int length, uint lo, uint hi, T value)
    {
        ulong key = (ulong)length << 32;
        _added.Add(new Range(key | lo, key | hi, _added.Count, value));
        LengthMask |= 1 << length;
    }

    /// <summary>Sorts what was added. Later additions win over earlier ones that cover the same code.</summary>
    public void Freeze()
    {
        _sorted = [.. _added];
        Array.Sort(_sorted, static (a, b) => a.Lo != b.Lo ? a.Lo.CompareTo(b.Lo) : a.Order.CompareTo(b.Order));
        _added.Clear();
    }

    public bool TryFind(int length, uint code, out uint lo, out T value)
    {
        ulong key = ((ulong)length << 32) | code;
        int low = 0, high = _sorted.Length - 1, at = -1;
        while (low <= high)
        {
            int mid = (low + high) >>> 1;
            if (_sorted[mid].Lo <= key) { at = mid; low = mid + 1; }
            else high = mid - 1;
        }
        for (int i = at; i >= 0 && i > at - OverlapProbe; i--)
        {
            var r = _sorted[i];
            if (r.Hi >= key)
            {
                lo = (uint)r.Lo;
                value = r.Value;
                return true;
            }
        }
        lo = 0;
        value = default!;
        return false;
    }
}
