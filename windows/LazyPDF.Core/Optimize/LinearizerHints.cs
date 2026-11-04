using System.Numerics;

namespace LazyPDF.Core;

// The primary hint stream (F.4): the page offset table, then the shared object table. The first
// page's objects are each a group of the shared table, ahead of the groups of the shared section,
// so that the groups cover the file from the first page's object onward without a gap.
internal sealed partial class Linearizer
{
    // Where in a page its first reference to a shared object lies is not tracked: every fraction is 0 of 4.
    private const int FractionDenominator = 4;

    private sealed record PageHint(int Objects, long Length, int[] Shared, long ContentOffset, long ContentLength);

    /// <summary>The hint stream object, from offsets that do not count the stream itself.</summary>
    private byte[] HintStream(long[] at)
    {
        var entryOf = new Dictionary<int, int>();
        for (int i = 0; i < _part6.Count; i++) entryOf[_part6[i]] = i;
        for (int i = 0; i < _part8.Count; i++) entryOf[_part8[i]] = _part6.Count + i;

        var pages = new PageHint[_pageItem.Length];
        for (int p = 0; p < pages.Length; p++)
        {
            var objects = _pageObjects[p];
            var (offset, length) = ContentSpan(p);
            int[] shared = [.. _pageShared[p].Select(o => entryOf[o]).Order()];
            pages[p] = new PageHint(objects.Count, objects.Sum(o => (long)_length[o]), shared, offset, length);
        }
        var groups = _part6.Concat(_part8).Select(o => (long)_length[o]).ToArray();
        long sharedFirstAt = _part8.Count > 0 ? at[_part8[0]] : 0;
        int sharedFirst = _part8.Count > 0 ? _number[_part8[0]] : 0;
        var outline = _outlines.Count == 0 ? null : new[] { _number[_outlines[0]], at[_outlines[0]], _outlines.Count, _outlines.Sum(o => (long)_length[o]) };
        byte[] tables = Tables(pages, at[_part6[0]], groups, _part6.Count, sharedFirst, sharedFirstAt, outline, out int sharedAt, out int outlineAt);

        var dictionary = new PdfDictionary();
        dictionary.Add("S", new PdfNumber(sharedAt));
        if (outline is not null) dictionary.Add("O", new PdfNumber(outlineAt));
        var bytes = new MemoryStream();
        new PdfObjectWriter(bytes, 0, options.Security).WriteStream(_hintNumber, 0, dictionary, tables);
        return bytes.ToArray();
    }

    /// <summary>Where the page's content streams start in its section and how long they run; 0 and 0 when they are not in it.</summary>
    private (long Offset, long Length) ContentSpan(int page)
    {
        var wanted = new HashSet<int>();
        void Add(PdfObject? value)
        {
            if (value is PdfReference reference && _index.TryGetValue(reference.Number, out int item)) wanted.Add(item);
        }
        var contents = PageDictionary(_pageItem[page])["Contents"];
        Add(contents);
        if (contents is PdfReference r && _index.TryGetValue(r.Number, out int at)) contents = _items[at];
        if (contents is PdfArray array)
        {
            foreach (var item in array.Items) Add(item);
        }

        long position = 0, start = -1, end = 0;
        foreach (int o in _pageObjects[page])
        {
            if (wanted.Contains(o))
            {
                if (start < 0) start = position;
                end = position + _length[o];
            }
            position += _length[o];
        }
        return start < 0 ? (0, 0) : (start, end - start);
    }

    private static byte[] Tables(PageHint[] pages, long firstPageAt, long[] groups, int firstGroups, int sharedFirst, long sharedFirstAt, long[]? outline, out int sharedAt, out int outlineAt)
    {
        long minObjects = pages.Min(p => p.Objects), minLength = pages.Min(p => p.Length);
        long minOffset = pages.Min(p => p.ContentOffset), minContent = pages.Min(p => p.ContentLength);
        int bitsObjects = Bits(pages.Max(p => p.Objects) - minObjects), bitsLength = Bits(pages.Max(p => p.Length) - minLength);
        int bitsOffset = Bits(pages.Max(p => p.ContentOffset) - minOffset), bitsContent = Bits(pages.Max(p => p.ContentLength) - minContent);
        int bitsCount = Bits(pages.Max(p => p.Shared.Length)), bitsId = Bits(pages.Max(p => p.Shared.Length == 0 ? 0 : p.Shared[^1]));

        var w = new BitWriter();
        w.Write(minObjects, 32);
        w.Write(firstPageAt, 32);
        w.Write(bitsObjects, 16);
        w.Write(minLength, 32);
        w.Write(bitsLength, 16);
        w.Write(minOffset, 32);
        w.Write(bitsOffset, 16);
        w.Write(minContent, 32);
        w.Write(bitsContent, 16);
        w.Write(bitsCount, 16);
        w.Write(bitsId, 16);
        w.Write(0, 16);
        w.Write(FractionDenominator, 16);
        foreach (var p in pages) w.Write(p.Objects - minObjects, bitsObjects);
        w.Align();
        foreach (var p in pages) w.Write(p.Length - minLength, bitsLength);
        w.Align();
        foreach (var p in pages) w.Write(p.Shared.Length, bitsCount);
        w.Align();
        foreach (var p in pages)
        {
            foreach (int id in p.Shared) w.Write(id, bitsId);
        }
        w.Align();
        // The numerators take no bits: every fraction is 0.
        foreach (var p in pages) w.Write(p.ContentOffset - minOffset, bitsOffset);
        w.Align();
        foreach (var p in pages) w.Write(p.ContentLength - minContent, bitsContent);
        w.Align();
        sharedAt = w.Length;

        long minGroup = groups.Min();
        int bitsGroup = Bits(groups.Max() - minGroup);
        w.Write(sharedFirst, 32);
        w.Write(sharedFirstAt, 32);
        w.Write(firstGroups, 32);
        w.Write(groups.Length, 32);
        w.Write(0, 16);
        w.Write(minGroup, 32);
        w.Write(bitsGroup, 16);
        foreach (long g in groups) w.Write(g - minGroup, bitsGroup);
        w.Align();
        // No group has a signature, and each is a single object (its count less one takes no bits).
        foreach (long _ in groups) w.Write(0, 1);
        w.Align();
        outlineAt = w.Length;
        if (outline is not null)
        {
            foreach (long value in outline) w.Write(value, 32);
        }
        return w.ToArray();
    }

    private static int Bits(long value) => value <= 0 ? 0 : 64 - BitOperations.LeadingZeroCount((ulong)value);

    private sealed class BitWriter
    {
        private readonly List<byte> _bytes = [];
        private int _used;

        public int Length => _bytes.Count;

        public void Write(long value, int bits)
        {
            for (int b = bits - 1; b >= 0; b--)
            {
                if (_used == 0) _bytes.Add(0);
                if ((value >> b & 1) != 0) _bytes[^1] |= (byte)(0x80 >> _used);
                _used = (_used + 1) & 7;
            }
        }

        public void Align() => _used = 0;

        public byte[] ToArray() => [.. _bytes];
    }
}
