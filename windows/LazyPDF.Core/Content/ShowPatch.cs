using System.Text;

namespace LazyPDF.Core;

/// <summary>One piece of what replaces a text-showing operator.</summary>
internal abstract record ShowItem;

/// <summary>Bytes to show with the font in force.</summary>
internal sealed record ShowText(byte[] Bytes) : ShowItem;

/// <summary>A number of a <c>TJ</c> array: thousandths of the font size to move back.</summary>
internal sealed record ShowShift(double Amount) : ShowItem;

/// <summary>Operators written between the pieces of text, such as a font change.</summary>
internal sealed record ShowOps(byte[] Raw) : ShowItem;

/// <summary>
/// Cuts and insertions in one <c>Tj</c>, <c>TJ</c>, <c>'</c> or <c>"</c>, counted in bytes of the
/// strings it shows. The result is one or more operators written over the original's byte range,
/// so that a line that is still in one piece keeps the form it had.
/// </summary>
internal sealed class ShowPatch(ContentOperation operation)
{
    private readonly List<(int Element, int Start, int End)> _cuts = [];
    private readonly List<(int Element, int Offset, IReadOnlyList<ShowItem> Items)> _inserts = [];

    public ContentOperation Operation { get; } = operation;

    public (int Cuts, int Inserts) Count => (_cuts.Count, _inserts.Count);

    public void Truncate((int Cuts, int Inserts) count)
    {
        _cuts.RemoveRange(count.Cuts, _cuts.Count - count.Cuts);
        _inserts.RemoveRange(count.Inserts, _inserts.Count - count.Inserts);
    }

    public void Cut(int element, int start, int end) => _cuts.Add((element, start, end));

    public void Insert(int element, int offset, IReadOnlyList<ShowItem> items) => _inserts.Add((element, offset, items));

    public Splice Compile()
    {
        var items = new List<ShowItem>();
        var op = Operation;
        var elements = new List<PdfObject>();
        switch (op.Operator)
        {
            case "Tj":
                elements.Add(op.Operands[^1]);
                break;
            case "'" or "\"":
                var preamble = new ContentWriter();
                if (op.Operator == "\"" && op.Operands.Count >= 3)
                {
                    preamble.Add(new ContentOperation("Tw", [op.Operands[^3]], 0, 0));
                    preamble.Add(new ContentOperation("Tc", [op.Operands[^2]], 0, 0));
                }
                preamble.Op("T*");
                items.Add(new ShowOps(preamble.ToArray()));
                elements.Add(op.Operands[^1]);
                break;
            default:
                if (op.Operands[^1] is PdfArray array) elements.AddRange(array.Items);
                break;
        }
        // The element index of a quote operator's string is 0 or 1 in the interpreter; here the string is alone.
        int offsetOfElement = op.Operator == "\"" ? 1 : 0;
        for (int e = 0; e < elements.Count; e++)
        {
            int index = e + (elements.Count == 1 ? offsetOfElement : 0);
            switch (elements[e])
            {
                case PdfString s:
                    AddString(items, index, s.Bytes);
                    break;
                case PdfNumber n:
                    items.Add(new ShowShift(n.Value));
                    break;
            }
        }
        var written = Write(items, op.Operands.Count > 0 && op.Operands[^1] is PdfString { IsHex: true } || op.Operands[^1] is PdfArray { Items: [PdfString { IsHex: true }, ..] });
        return new Splice(op.Start, op.End, written);
    }

    private void AddString(List<ShowItem> items, int element, byte[] bytes)
    {
        var run = new List<byte>();
        void Flush()
        {
            if (run.Count > 0) items.Add(new ShowText([.. run]));
            run.Clear();
        }
        for (int p = 0; p <= bytes.Length; p++)
        {
            foreach (var insert in _inserts)
            {
                if (insert.Element != element || insert.Offset != p) continue;
                Flush();
                items.AddRange(insert.Items);
            }
            if (p == bytes.Length) break;
            bool cut = false;
            foreach (var c in _cuts)
            {
                if (c.Element == element && p >= c.Start && p < c.End) cut = true;
            }
            if (!cut) run.Add(bytes[p]);
        }
        Flush();
    }

    /// <summary>Writes items as operators: consecutive text and shifts become one <c>Tj</c> or <c>TJ</c>.</summary>
    internal static byte[] Write(IReadOnlyList<ShowItem> items, bool hex)
    {
        var w = new ContentWriter();
        var group = new List<ShowItem>();
        void Flush()
        {
            if (group.Count == 0) return;
            if (group is [ShowText only]) w.Op("Tj", [Str(only.Bytes, hex)]);
            else
            {
                var array = group.Select(i => i is ShowText t ? (PdfObject)Str(t.Bytes, hex) : new PdfNumber(((ShowShift)i).Amount)).ToList();
                w.Op("TJ", [new PdfArray(array)]);
            }
            group.Clear();
        }
        foreach (var item in items)
        {
            if (item is ShowOps ops)
            {
                Flush();
                w.Raw(Encoding.Latin1.GetString(ops.Raw));
            }
            else group.Add(item);
        }
        Flush();
        var bytes = w.ToArray();
        // The original is followed by its own white space.
        return bytes.Length > 0 && bytes[^1] == '\n' ? bytes[..^1] : bytes;
    }

    internal static PdfString Str(byte[] bytes, bool hex)
    {
        bool plain = !hex && bytes.All(b => b is >= 0x20 and < 0x7F);
        return new PdfString(bytes, !plain);
    }
}

/// <summary>Bytes <paramref name="Start"/> up to <paramref name="End"/> of a content stream, replaced.</summary>
internal readonly record struct Splice(int Start, int End, byte[] Bytes);
