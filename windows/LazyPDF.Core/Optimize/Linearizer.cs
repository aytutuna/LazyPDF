using System.Globalization;
using System.Security.Cryptography;
using System.Text;

namespace LazyPDF.Core;

// Linearized output (ISO 32000-1 Annex F). In file order: header, the linearization dictionary,
// the first-page cross-reference section, the catalog, the hint stream, the first page's objects,
// the other pages one after the other, shared objects, everything else, and the main
// cross-reference section. Objects are numbered in file order, the main section's first, so that
// each section is one run of numbers.
internal sealed partial class Linearizer(PdfDocument document, PdfSaveOptions options)
{
    // The fields written last (lengths, offsets) take this many characters whatever their value,
    // so that sizes are known before the numbers are.
    private const int FieldWidth = 10;

    // The file is built in one array, and the hint stream and cross-reference sections come on top of the objects.
    private const long MaxSize = int.MaxValue - (64 << 20);

    private readonly MemoryStream _blob = new();
    private long[] _start = [];
    private int[] _length = [];
    private int[] _number = [];
    private int _linNumber;
    private int _hintNumber;
    private int _size;
    private PdfArray _id = new([]);

    public byte[] Run()
    {
        Collect();
        Classify();
        Number();
        Serialize();
        return Assemble();
    }

    private void Number()
    {
        _number = new int[_items.Count];
        int next = 1;
        for (int p = 1; p < _pageObjects.Length; p++)
        {
            foreach (int o in _pageObjects[p]) _number[o] = next++;
        }
        foreach (int o in _part8) _number[o] = next++;
        foreach (int o in _part9) _number[o] = next++;
        _linNumber = next++;
        foreach (int o in _part4) _number[o] = next++;
        _hintNumber = next++;
        foreach (int o in _part6) _number[o] = next++;
        _size = next;
    }

    private void Serialize()
    {
        var security = options.Security;
        var writer = new PdfObjectWriter(_blob, 0, security);
        _start = new long[_items.Count];
        _length = new int[_items.Count];
        for (int o = 0; o < _items.Count; o++)
        {
            _start[o] = _blob.Length;
            if (_items[o] is PdfStream stream)
            {
                var dictionary = RemapDictionary(stream.Dictionary, true);
                bool dropped = !ReferenceEquals(security, document.Security) && DropCrypt(stream, dictionary);
                var view = security is null || dropped ? null : document.CryptView(stream.Dictionary);
                byte[] data = document.RawData(stream);
                if (_blob.Length + data.Length > MaxSize) throw new PdfReadException(PdfReadProblem.Unsupported, "The file is too large to linearize.");
                writer.WriteStream(_number[o], 0, dictionary, data, cryptView: view);
            }
            else
            {
                writer.WriteObject(_number[o], 0, Remap(_items[o]), encrypt: o != _encrypt);
            }
            _length[o] = (int)(_blob.Length - _start[o]);
        }
    }

    private PdfObject Remap(PdfObject value) => value switch
    {
        PdfReference reference => _index.TryGetValue(reference.Number, out int item) ? new PdfReference(_number[item], 0) : PdfNull.Instance,
        PdfArray array => new PdfArray([.. array.Items.Select(Remap)]),
        PdfDictionary dictionary => RemapDictionary(dictionary, false),
        // An integer too big for 64 bits is a real as far as a strict reader is concerned.
        PdfNumber { IsInteger: true, Integer: null } number when number.Value != 0 && double.IsFinite(number.Value) => new PdfNumber(number.Text + ".0"),
        _ => value,
    };

    private PdfDictionary RemapDictionary(PdfDictionary source, bool stream)
    {
        var copy = new PdfDictionary();
        foreach (var (key, item) in source.Entries)
        {
            if (!ReferenceEquals(source[key], item) || (stream && key == "Length")) continue;
            var mapped = Remap(item);
            if (mapped is not PdfNull) copy.Add(key, mapped);
        }
        return copy;
    }

    // As in PdfRewriter: a new handler has no crypt filter of the old one's names, and the data is already decrypted.
    private bool DropCrypt(PdfStream stream, PdfDictionary dictionary)
    {
        var (filter, parameters, crypt) = document.DecodeSpec(stream);
        if (!crypt) return false;
        dictionary.Remove("DecodeParms");
        if (filter is null or PdfArray { Items.Count: 0 })
        {
            dictionary.Remove("Filter");
            return true;
        }
        dictionary["Filter"] = filter;
        if (parameters is not (null or PdfNull)) dictionary["DecodeParms"] = parameters;
        return true;
    }

    private byte[] Assemble()
    {
        _id = PdfXrefWriter.IdPair(FirstId());
        byte[] header = Header();
        int linLength = Linearization(0, 0, 0, 0, 0, 0, 0).Length;
        int firstCount = _part4.Count + _part6.Count + 2;
        string firstHead = $"xref\n{_linNumber} {firstCount}\n";
        long firstXref = header.Length + linLength;
        long position = firstXref + firstHead.Length + 20L * firstCount + FirstTrailer(0).Length;

        var at = new long[_items.Count];
        foreach (int o in _part4)
        {
            at[o] = position;
            position += _length[o];
        }
        // Offsets in the hint tables count the file as if the hint stream were not in it (F.3.3), so
        // the layout is made without it first and moved by its length once that is known.
        long hintAt = position;
        var behind = Behind();
        foreach (int o in behind)
        {
            at[o] = position;
            position += _length[o];
        }
        byte[] hint = HintStream(at);
        foreach (int o in behind) at[o] += hint.Length;
        long firstPageEnd = hintAt + hint.Length + _part6.Sum(o => (long)_length[o]);
        long mainAt = position + hint.Length;

        var offsets = new long[_size];
        for (int o = 0; o < _items.Count; o++) offsets[_number[o]] = at[o];
        offsets[_linNumber] = header.Length;
        offsets[_hintNumber] = hintAt;
        byte[] main = MainSection(offsets, firstXref);
        long length = mainAt + main.Length;
        if (length > int.MaxValue) throw new PdfReadException(PdfReadProblem.Unsupported, "The file is too large to linearize.");
        byte[] lin = Linearization(length, hintAt, hint.Length, _number[_part6[0]], firstPageEnd, _pageItem.Length, mainAt + "xref\n".Length + $"0 {_linNumber}".Length);

        var output = new MemoryStream((int)length);
        output.Write(header);
        output.Write(lin);
        var first = new StringBuilder(firstHead);
        for (int n = _linNumber; n < _size; n++) first.Append(Entry(offsets[n]));
        output.Write(Encoding.Latin1.GetBytes(first.ToString()));
        output.Write(FirstTrailer(mainAt));
        foreach (int o in _part4) Append(output, o);
        output.Write(hint);
        foreach (int o in behind) Append(output, o);
        output.Write(main);
        return output.ToArray();
    }

    /// <summary>The objects after the hint stream, in file order.</summary>
    private List<int> Behind()
    {
        var order = new List<int>(_part6);
        for (int p = 1; p < _pageObjects.Length; p++) order.AddRange(_pageObjects[p]);
        order.AddRange(_part8);
        order.AddRange(_part9);
        return order;
    }

    private void Append(MemoryStream output, int item) => output.Write(_blob.GetBuffer().AsSpan((int)_start[item], _length[item]));

    private static string Entry(long offset) => $"{offset.ToString("D10", CultureInfo.InvariantCulture)} 00000 n \n";

    private byte[] Header()
    {
        var bytes = new MemoryStream();
        new PdfObjectWriter(bytes).WriteHeader(HeaderVersion());
        return bytes.ToArray();
    }

    /// <summary>The linearization parameter dictionary (F.3.2), padded to the size it has with the widest values.</summary>
    private byte[] Linearization(long length, long hintAt, long hintLength, long firstPage, long end, long pages, long mainFirst)
    {
        string Text(long l, long h0, long h1, long o, long e, long n, long t) =>
            $"{_linNumber} 0 obj\n<< /Linearized 1 /L {l} /H [ {h0} {h1} ] /O {o} /E {e} /N {n} /T {t}";
        const long Widest = 9_999_999_999;
        string text = Text(length, hintAt, hintLength, firstPage, end, pages, mainFirst);
        int room = Text(Widest, Widest, Widest, Widest, Widest, Widest, Widest).Length - text.Length;
        return Encoding.Latin1.GetBytes(text + new string(' ', room) + " >>\nendobj\n");
    }

    private byte[] FirstTrailer(long previous)
    {
        var text = new StringBuilder("trailer\n<< /Size ").Append(_size).Append(" /Root ").Append(_number[_root]).Append(" 0 R");
        if (_info >= 0) text.Append(" /Info ").Append(_number[_info]).Append(" 0 R");
        if (_encrypt >= 0) text.Append(" /Encrypt ").Append(_number[_encrypt]).Append(" 0 R");
        text.Append(" /ID ");
        _id.WriteTo(text);
        text.Append(" /Prev ").Append(previous.ToString(CultureInfo.InvariantCulture).PadRight(FieldWidth)).Append(" >>\nstartxref\n0\n%%EOF\n");
        return Encoding.Latin1.GetBytes(text.ToString());
    }

    private byte[] MainSection(long[] offsets, long firstXref)
    {
        var text = new StringBuilder($"xref\n0 {_linNumber}\n0000000000 65535 f \n");
        for (int n = 1; n < _linNumber; n++) text.Append(Entry(offsets[n]));
        text.Append("trailer\n<< /Size ").Append(_linNumber).Append(" /ID ");
        _id.WriteTo(text);
        text.Append(" >>\nstartxref\n").Append(firstXref).Append("\n%%EOF\n");
        return Encoding.Latin1.GetBytes(text.ToString());
    }

    private byte[] FirstId()
    {
        // The keys of the older handlers are made from the first string, so a kept handler keeps it.
        if (options.Security is not null && ReferenceEquals(options.Security, document.Security)) return document.FirstId ?? [];
        // The first string names the document across its versions (ISO 32000-1 14.4.1).
        if (options.DocumentId is null && options.Security is null && document.FirstId is { Length: > 0 } kept) return kept;
        return options.DocumentId ?? RandomNumberGenerator.GetBytes(16);
    }

    private string HeaderVersion()
    {
        string version = Raised(document.Version, "1.2");
        if (options.Security is { Revision: >= 5 }) version = Raised(version, "1.7");
        else if (options.Security is { Revision: 4 }) version = Raised(version, "1.6");
        return version;
    }

    private static string Raised(string version, string least) =>
        Version.TryParse(version, out var v) && v >= Version.Parse(least) ? version : least;
}
