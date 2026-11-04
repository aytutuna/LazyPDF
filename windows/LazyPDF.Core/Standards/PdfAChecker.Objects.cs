using System.Text;

namespace LazyPDF.Core;

// Every object reachable from the trailer: implementation limits, stream keys and filters, file specifications.
internal sealed partial class PdfAChecker
{
    private const long MaxSteps = 20_000_000;

    private static readonly HashSet<string> Table6 =
    [
        "ASCIIHexDecode", "ASCII85Decode", "LZWDecode", "FlateDecode", "RunLengthDecode", "CCITTFaxDecode", "JBIG2Decode", "DCTDecode", "JPXDecode", "Crypt",
    ];

    // The short names ISO 32000-1 Table 94 allows in an inline image.
    private static readonly HashSet<string> InlineFilters = ["AHx", "A85", "LZW", "Fl", "RL", "CCF", "DCT"];

    private void CheckObjects()
    {
        var visited = new HashSet<int>();
        var stack = new Stack<(PdfObject Value, int Owner)>();
        stack.Push((_doc.Trailer, 0));
        for (long steps = 0; stack.Count > 0 && steps < MaxSteps; steps++)
        {
            var (value, owner) = stack.Pop();
            string where = owner == 0 ? PdfAText.Trailer : PdfAText.ObjectName(owner);
            switch (value)
            {
                case PdfReference reference:
                    if (visited.Add(reference.Number) && _doc.Get(reference.Number) is { } target) stack.Push((target, reference.Number));
                    break;
                case PdfArray array:
                    CheckLimits(array, where);
                    foreach (var item in array.Items) stack.Push((item, owner));
                    break;
                case PdfStream stream:
                    CheckStream(stream, owner, where);
                    stack.Push((stream.Dictionary, owner));
                    break;
                case PdfDictionary dictionary:
                    CheckLimits(dictionary, where);
                    if (dictionary.ContainsKey("EF")) CheckFileSpec(dictionary, where);
                    foreach (var (_, item) in dictionary.Entries) stack.Push((item, owner));
                    break;
                default:
                    CheckLimits(value, where);
                    break;
            }
        }
    }

    // The limits one value can break: 6.1.12 in part 1, 6.1.13 after. Part 1 also bounds reals and the size of arrays and dictionaries.
    private void CheckLimits(PdfObject value, string where)
    {
        string clause = C("6.1.12", "6.1.13");
        switch (value)
        {
            case PdfString text when text.Bytes.Length > (IsPart1 ? 65535 : 32767):
                Add(clause, where, PdfAText.StringTooLong(text.Bytes.Length));
                break;
            case PdfName name when Encoding.UTF8.GetByteCount(name.Value) > 127:
                Add(clause, where, PdfAText.NameTooLong);
                break;
            case PdfNumber { IsInteger: true } number when number.Value is > int.MaxValue or < int.MinValue:
                Add(clause, where, PdfAText.IntegerTooBig(number.Text));
                break;
            case PdfNumber { IsInteger: false } real when IsPart1 && Math.Abs(real.Value) > 32767:
                Add(clause, where, PdfAText.RealTooBig(real.Text));
                break;
            case PdfArray array when IsPart1 && array.Items.Count > 8191:
                Add(clause, where, PdfAText.ArrayTooLong(array.Items.Count));
                break;
            case PdfDictionary dictionary when IsPart1 && dictionary.Count > 4095:
                Add(clause, where, PdfAText.DictionaryTooBig(dictionary.Count));
                break;
        }
    }

    private void CheckStream(PdfStream stream, int owner, string where)
    {
        var d = stream.Dictionary;
        if (owner > 0) CheckStreamSyntax(stream, where);
        foreach (string key in (ReadOnlySpan<string>)["F", "FFilter", "FDecodeParms"])
        {
            if (d.ContainsKey(key)) Add("6.1.7", where, PdfAText.StreamKey(key));
        }
        CheckFilters(d, where, false);
    }

    // Part 1 names LZW alone (6.1.10). Later parts name it with the other filters in 6.1.7.2 and keep 6.1.10 for inline images; they list the
    // filters of Table 6 in ISO 32000-1 and take a Crypt filter only as the identity, in a stream and never in an inline image.
    private void CheckFilters(PdfDictionary owner, string where, bool inline)
    {
        string clause = IsPart1 || inline ? "6.1.10" : "6.1.7.2";
        var filters = FilterNames(owner);
        for (int i = 0; i < filters.Count; i++)
        {
            string filter = filters[i];
            if (IsFilter(filter, "LZWDecode", "LZW")) Add(clause, where, PdfAText.Lzw);
            else if (filter == "Crypt" && inline) Add(clause, where, PdfAText.CryptFilter);
            else if (filter == "Crypt") CheckCrypt(owner, i, clause, where);
            else if (!IsPart1 && filter.Length > 0 && !Table6.Contains(filter) && !(inline && InlineFilters.Contains(filter))) Add(clause, where, PdfAText.UnknownFilter(filter));
        }
    }

    private void CheckCrypt(PdfDictionary owner, int index, string clause, string where)
    {
        var parameters = _doc.Resolve(owner["DecodeParms"] ?? owner["DP"]) switch
        {
            PdfArray list => index < list.Items.Count ? _doc.Resolve(list.Items[index]) as PdfDictionary : null,
            PdfDictionary single => single,
            _ => null,
        };
        if (IsPart1 || (_doc.Name(parameters, "Name") ?? "Identity") != "Identity") Add(clause, where, PdfAText.CryptFilter);
    }

    private void CheckFileSpec(PdfDictionary spec, string where)
    {
        if (Part is 1 or 4)
        {
            Add(IsPart1 ? "6.1.11" : "6.8", where, PdfAText.EmbeddedFile);
            return;
        }
        var stream = _doc.Dict(spec, "EF") is { } ef ? _doc.Stream(ef, "F") ?? _doc.Stream(ef, "UF") : null;
        if (Part == 2)
        {
            if (stream is null || !IsPdfA(_doc, stream)) Add("6.8", where, PdfAText.EmbeddedNotPdfA);
            return;
        }
        if (!spec.ContainsKey("AFRelationship")) Add("6.8", where, PdfAText.NoRelationship);
        if (stream is not null && _doc.Name(stream.Dictionary, "Subtype") is null) Add("6.8", where, PdfAText.NoMimeType);
    }

    internal static bool IsPdfA(PdfDocument document, PdfStream stream)
    {
        try
        {
            byte[] data = document.Data(stream, 256L << 20);
            if (!data.AsSpan().StartsWith("%PDF-"u8)) return false;
            using var inner = PdfDocument.Open(data);
            return inner.PdfAPart is 1 or 2;
        }
        catch (PdfReadException)
        {
            return false;
        }
    }
}
