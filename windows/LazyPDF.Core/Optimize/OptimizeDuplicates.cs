using System.Security.Cryptography;

namespace LazyPDF.Core;

// Objects that say the same thing are written once. Streams count as equal when their dictionaries
// and stored bytes are; a few kinds of plain dictionaries (fonts, descriptors, graphics states)
// too. Pages, annotations and the like never merge, because their identity matters.
internal static class OptimizeDuplicates
{
    private const int Rounds = 8;

    public static int Run(PdfDocument document)
    {
        int merged = 0;
        var hashes = new Dictionary<int, string>();
        for (int round = 0; round < Rounds; round++)
        {
            var groups = new Dictionary<string, List<int>>();
            var live = Reachable(document);
            foreach (var (number, value) in PdfGraph.Objects(document))
            {
                if (!live.Contains(number) || !Mergeable(document, value)) continue;
                string key = PdfGraph.Canonical(value, n => n, true);
                if (value is PdfStream stream)
                {
                    if (!hashes.TryGetValue(number, out string? hash)) hashes[number] = hash = Convert.ToHexString(SHA256.HashData(document.RawData(stream)));
                    key += hash;
                }
                if (!groups.TryGetValue(key, out var list)) groups[key] = list = [];
                list.Add(number);
            }
            var map = new Dictionary<int, int>();
            foreach (var list in groups.Values)
            {
                if (list.Count < 2) continue;
                int keep = list[0];
                foreach (int other in list.Skip(1))
                {
                    if (Same(document, keep, other)) map[other] = keep;
                }
            }
            if (map.Count == 0) break;
            PdfGraph.Redirect(document, map);
            merged += map.Count;
        }
        return merged;
    }

    private static HashSet<int> Reachable(PdfDocument document)
    {
        var reached = new HashSet<int>();
        var queue = new Queue<PdfObject?>([document.Trailer]);
        foreach (var page in document.Pages) queue.Enqueue(page.Dictionary);
        while (queue.Count > 0)
        {
            foreach (var reference in PdfGraph.References(queue.Dequeue()))
            {
                if (reached.Add(reference.Number)) queue.Enqueue(document.Get(reference.Number));
            }
        }
        return reached;
    }

    private static bool Same(PdfDocument document, int a, int b) =>
        document.Get(a) is PdfStream x && document.Get(b) is PdfStream y ? document.RawData(x).AsSpan().SequenceEqual(document.RawData(y)) : true;

    private static bool Mergeable(PdfDocument document, PdfObject value)
    {
        if (value is PdfStream stream)
        {
            return document.Name(stream.Dictionary, "Type") is not ("Metadata" or "XRef" or "ObjStm");
        }
        if (value is not PdfDictionary dictionary) return false;
        return document.Name(dictionary, "Type") is "Font" or "FontDescriptor" or "ExtGState"
            || document.Name(dictionary, "Subtype") is "Type1" or "TrueType" or "Type0" or "CIDFontType0" or "CIDFontType2" or "MMType1"
            || dictionary.ContainsKey("FunctionType");
    }
}
