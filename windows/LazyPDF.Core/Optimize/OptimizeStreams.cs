using System.IO.Compression;

namespace LazyPDF.Core;

// Flate at the smallest level for every stream, and the older text and run-length filters turned into Flate.
internal static class OptimizeStreams
{
    private static readonly HashSet<string> Flate = ["FlateDecode", "Fl"];
    private static readonly HashSet<string> Old = ["LZWDecode", "LZW", "ASCII85Decode", "A85", "ASCIIHexDecode", "AHx", "RunLengthDecode", "RL"];
    private static readonly string[] PredictorKeys = ["Predictor", "Colors", "BitsPerComponent", "Columns"];

    /// <summary>Returns (streams recompressed, streams converted from the old filters).</summary>
    public static (int Recompressed, int Converted) Run(PdfDocument document, bool recompress, bool convert)
    {
        int recompressed = 0, converted = 0;
        foreach (var (_, value) in PdfGraph.Objects(document))
        {
            if (value is not PdfStream stream) continue;
            var filters = Filters(document, stream);
            if (filters is null || filters.Count == 0) continue;
            bool old = filters.Any(Old.Contains);
            if (old ? !convert : !recompress) continue;
            if (document.Name(stream.Dictionary, "Type") is "Metadata" or "XRef" or "ObjStm") continue;
            if (!Encode(document, stream, filters)) continue;
            if (old) converted++;
            else recompressed++;
        }
        return (recompressed, converted);
    }

    // Null for a chain with an image codec or anything else that is not left to us.
    private static List<string>? Filters(PdfDocument document, PdfStream stream)
    {
        List<string> names = document.DecodeSpec(stream).Filter switch
        {
            PdfName name => [name.Value],
            PdfArray array => [.. array.Items.Select(i => (i as PdfName)?.Value ?? "")],
            _ => [],
        };
        return names.All(n => Flate.Contains(n) || Old.Contains(n)) ? names : null;
    }

    private static bool Encode(PdfDocument document, PdfStream stream, List<string> filters)
    {
        var dictionary = stream.Dictionary;
        var each = document.DecodeSpec(stream).Parameters switch
        {
            PdfArray array => array.Items.Select(i => i as PdfDictionary).ToList(),
            PdfDictionary single => [single],
            _ => new List<PdfDictionary?>(),
        };
        // A predictor belongs to the last stage; the new stream keeps it and only the stage under it changes.
        PdfDictionary? predictor = null;
        var stripped = new List<PdfObject>();
        for (int i = 0; i < filters.Count; i++)
        {
            var p = i < each.Count ? each[i] : null;
            var plain = p?.Copy() ?? new PdfDictionary();
            if (p is not null && document.Integer(p, "Predictor") > 1)
            {
                if (i != filters.Count - 1) return false;
                predictor = new PdfDictionary();
                foreach (string key in PredictorKeys)
                {
                    if (p[key] is { } v) predictor[key] = v;
                    plain.Remove(key);
                }
            }
            stripped.Add(plain);
        }
        byte[] raw = document.RawData(stream);
        byte[] data;
        try
        {
            data = PdfFilters.Decode(raw, new PdfArray([.. filters.Select(f => (PdfObject)new PdfName(f))]), new PdfArray(stripped), PdfFilters.DefaultMaxSize, strict: true);
        }
        catch (PdfReadException)
        {
            return false;
        }
        byte[] packed = PdfFilterEncoders.Flate(data, CompressionLevel.SmallestSize);
        bool onlyFlate = filters.Count == 1 && Flate.Contains(filters[0]);
        // The same filter again only has to be smaller; a different one is worth the change when it is not larger.
        if (onlyFlate ? packed.Length >= raw.Length : packed.Length > raw.Length) return false;
        stream.Data = packed;
        dictionary["Filter"] = new PdfName("FlateDecode");
        if (predictor is not null) dictionary["DecodeParms"] = predictor;
        else dictionary.Remove("DecodeParms");
        return true;
    }
}
