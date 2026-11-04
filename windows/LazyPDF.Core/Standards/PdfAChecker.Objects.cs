using System.Text;

namespace LazyPDF.Core;

// Every object reachable from the trailer: implementation limits, stream keys and filters, file
// specifications. Fonts met on the way are kept for the font checks.
internal sealed partial class PdfAChecker
{
    private const long MaxSteps = 20_000_000;

    private readonly HashSet<PdfDictionary> _fonts = new(ReferenceEqualityComparer.Instance);

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
                case PdfString text:
                    if (text.Bytes.Length > (IsPart1 ? 65535 : 32767)) Add(C("6.1.12", "6.1.13"), where, PdfAText.StringTooLong(text.Bytes.Length));
                    break;
                case PdfName name:
                    if (Encoding.UTF8.GetByteCount(name.Value) > 127) Add(C("6.1.12", "6.1.13"), where, PdfAText.NameTooLong);
                    break;
                case PdfNumber { IsInteger: true } number:
                    if (number.Value is > int.MaxValue or < int.MinValue) Add(C("6.1.12", "6.1.13"), where, PdfAText.IntegerTooBig(number.Text));
                    break;
                case PdfArray array:
                    if (IsPart1 && array.Items.Count > 8191) Add("6.1.12", where, PdfAText.ArrayTooLong(array.Items.Count));
                    foreach (var item in array.Items) stack.Push((item, owner));
                    break;
                case PdfStream stream:
                    CheckStream(stream, owner, where);
                    stack.Push((stream.Dictionary, owner));
                    break;
                case PdfDictionary dictionary:
                    if (IsPart1 && dictionary.Count > 4095) Add("6.1.12", where, PdfAText.DictionaryTooBig(dictionary.Count));
                    CheckDictionary(dictionary, where);
                    foreach (var (_, item) in dictionary.Entries) stack.Push((item, owner));
                    break;
            }
        }
    }

    private void CheckDictionary(PdfDictionary dictionary, string where)
    {
        if (_doc.Name(dictionary, "Type") == "Font" && _doc.Name(dictionary, "Subtype") is "Type1" or "MMType1" or "TrueType" or "Type3" or "Type0") _fonts.Add(dictionary);
        if (dictionary.ContainsKey("EF")) CheckFileSpec(dictionary, where);
    }

    private void CheckStream(PdfStream stream, int owner, string where)
    {
        var d = stream.Dictionary;
        if (owner > 0) CheckStreamSyntax(stream, where);
        foreach (string key in (ReadOnlySpan<string>)["F", "FFilter", "FDecodeParms"])
        {
            if (d.ContainsKey(key)) Add("6.1.7", where, PdfAText.StreamKey(key));
        }
        CheckFilters(FilterNames(d), where);
        if (IsPart1 && _doc.Name(d, "Type") == "ObjStm") Add("6.1.4", where, PdfAText.ObjectStreams);
    }

    private void CheckFilters(IReadOnlyList<string> filters, string where)
    {
        foreach (string filter in filters)
        {
            if (IsFilter(filter, "LZWDecode", "LZW")) Add("6.1.10", where, PdfAText.Lzw);
            else if (filter == "Crypt") Add("6.1.10", where, PdfAText.CryptFilter);
        }
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
            return inner.PdfAPart is >= 1 and <= 3;
        }
        catch (PdfReadException)
        {
            return false;
        }
    }
}
