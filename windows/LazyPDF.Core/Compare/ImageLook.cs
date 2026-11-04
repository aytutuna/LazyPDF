using System.Globalization;
using System.Security.Cryptography;

namespace LazyPDF.Core;

/// <summary>
/// What besides its samples decides how a picture looks: how the stored bytes are read (filters and their
/// parameters), the colour space, /Decode, masks (ISO 32000-1 8.9.5) and whatever else a nested stream says.
/// References are followed, never printed, strings and numbers are taken by value, and an entry that says
/// what its absence says is left out, so the same picture keeps its look when objects are renumbered
/// or a value is respelled.
/// </summary>
internal sealed class ImageLook(PdfDocument document, CancellationToken cancellation)
{
    private const int MaxDepth = 6;
    private const int MaxNodes = 1024;
    private const int MaxItems = 256;
    private const long MaxBytes = 16L << 20;
    private static readonly string[] Keys = ["ColorSpace", "BitsPerComponent", "Decode", "ImageMask", "Mask", "SMask", "Matte"];

    // How a nested stream is stored says nothing about what it holds: its data is judged decoded.
    private static readonly string[] StorageKeys = ["Length", "Filter", "DecodeParms", "DL", "Metadata"];

    private static readonly Dictionary<string, string> FilterNames = new()
    {
        ["Fl"] = "FlateDecode",
        ["LZW"] = "LZWDecode",
        ["AHx"] = "ASCIIHexDecode",
        ["A85"] = "ASCII85Decode",
        ["RL"] = "RunLengthDecode",
        ["CCF"] = "CCITTFaxDecode",
        ["DCT"] = "DCTDecode",
    };

    // What a /DecodeParms entry means when absent (ISO 32000-1 7.4.4.3, 7.4.4.4, 7.4.6); a boolean counts as 0 or 1.
    private static readonly Dictionary<string, double> ParameterDefaults = new()
    {
        ["Predictor"] = 1,
        ["Colors"] = 1,
        ["BitsPerComponent"] = 8,
        ["Columns"] = 1,
        ["EarlyChange"] = 1,
        ["K"] = 0,
        ["Rows"] = 0,
        ["EndOfLine"] = 0,
        ["EncodedByteAlign"] = 0,
        ["BlackIs1"] = 0,
        ["DamagedRowsBeforeError"] = 0,
    };

    private readonly Dictionary<PdfStream, string> _samples = new(ReferenceEqualityComparer.Instance);
    private int _nodes;

    public static string Fingerprint(byte[] data) => Convert.ToHexString(SHA256.HashData(data), 0, 12);

    public string Of(PdfDictionary image)
    {
        _nodes = 0;
        var look = new PdfDictionary();
        foreach (string key in Keys) look[key] = image[key];
        return $"|{Storage(image)}|{Entries(look, Keys, 0, isImage: true)}";
    }

    /// <summary>The filters by full name with the parameters that are not the defaults; one filter in an array reads like a bare name, a null entry like none.</summary>
    private string Storage(PdfDictionary image)
    {
        List<string> filters = document.Resolve(image["Filter"]) switch
        {
            PdfName name => [Expand(name.Value)],
            PdfArray array => [.. array.Items.Take(MaxItems).Select(i => Expand((document.Resolve(i) as PdfName)?.Value ?? ""))],
            _ => [],
        };
        List<PdfDictionary?> parameters = document.Resolve(image["DecodeParms"]) switch
        {
            PdfArray array => [.. array.Items.Take(MaxItems).Select(i => document.Resolve(i) as PdfDictionary)],
            PdfDictionary dictionary => [dictionary],
            _ => [],
        };
        return string.Join(',', filters.Select((filter, i) => filter + (i < parameters.Count && parameters[i] is { } p ? Parameters(p, filter) : "")));
    }

    private static string Expand(string filter) => FilterNames.GetValueOrDefault(filter, filter);

    private string Parameters(PdfDictionary parameters, string filter)
    {
        var keys = parameters.Entries.Select(e => e.Key).Where(key => !IsDefaultParameter(parameters, key, filter));
        string text = Entries(parameters, keys, 1, isImage: false);
        return text == "<>" ? "" : text;
    }

    private bool IsDefaultParameter(PdfDictionary parameters, string key, string filter)
    {
        if (!ParameterDefaults.TryGetValue(key, out double fallback)) return false;
        if (key == "Columns" && filter == "CCITTFaxDecode") fallback = 1728;
        return document.Resolve(parameters[key]) switch
        {
            PdfNumber number => number.Value == fallback,
            PdfBoolean flag => (flag.Value ? 1 : 0) == fallback,
            _ => false,
        };
    }

    private string Entries(PdfDictionary dictionary, IEnumerable<string> keys, int depth, bool isImage)
    {
        var parts = new List<string>();
        foreach (string key in keys.Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal).Take(MaxItems))
        {
            var value = document.Resolve(dictionary[key]);
            if (value is null or PdfNull || (isImage && IsDefault(dictionary, key, value))) continue;
            parts.Add($"{key} {Describe(value, depth)}");
        }
        return $"<{string.Join(' ', parts)}>";
    }

    private string Describe(PdfObject? value, int depth)
    {
        value = document.Resolve(value);
        if (depth >= MaxDepth || value is null or PdfNull || ++_nodes > MaxNodes) return "";
        cancellation.ThrowIfCancellationRequested();
        return value switch
        {
            PdfStream stream => $"S{SamplesOf(stream)}{Entries(stream.Dictionary, stream.Dictionary.Entries.Select(e => e.Key).Except(StorageKeys), depth + 1, stream.Dictionary.ContainsKey("Width"))}",
            PdfDictionary dictionary => Entries(dictionary, dictionary.Entries.Select(e => e.Key), depth + 1, isImage: false),
            PdfArray array => $"[{string.Join(' ', array.Items.Take(MaxItems).Select(item => Describe(item, depth + 1)))}]",
            PdfString text => Convert.ToHexString(text.Bytes),
            PdfNumber number => number.Value.ToString("R", CultureInfo.InvariantCulture),
            _ => value.ToString(),
        };
    }

    /// <summary>An entry of an image dictionary that reads as it does when left out (ISO 32000-1 8.9.5, Table 89).</summary>
    private bool IsDefault(PdfDictionary image, string key, PdfObject value)
    {
        bool mask = document.Resolve(image["ImageMask"]) is PdfBoolean { Value: true };
        return key switch
        {
            "ImageMask" or "Interpolate" => value is PdfBoolean { Value: false },
            "BitsPerComponent" => mask && value is PdfNumber { Value: 1 },
            "Decode" => value is PdfArray array && IsDefaultDecode(image, array),
            _ => false,
        };
    }

    // Table 90: [0 1] for each component, but an Indexed space runs to its last entry and Lab has ranges of its own.
    private bool IsDefaultDecode(PdfDictionary image, PdfArray decode)
    {
        var values = decode.Items.Take(MaxItems).Select(i => (document.Resolve(i) as PdfNumber)?.Value).ToList();
        if (values.Count == 0 || values.Count % 2 != 0 || values.Any(v => v is null)) return false;
        var space = document.Resolve(image["ColorSpace"]);
        if (space is PdfArray { Items.Count: > 0 } family) space = document.Resolve(family.Items[0]);
        double high = 1;
        switch ((space as PdfName)?.Value)
        {
            case "Lab":
                return false;
            case "Indexed" or "I":
                if (document.Resolve(image["BitsPerComponent"]) is not PdfNumber { Value: >= 1 and <= 16 } bits) return false;
                high = (1 << (int)bits.Value) - 1;
                break;
        }
        for (int i = 0; i < values.Count; i += 2)
        {
            if (values[i] != 0 || values[i + 1] != high) return false;
        }
        return true;
    }

    /// <summary>A palette or profile is judged by its content: saving may store it with another filter. A stream reached again is not decoded again.</summary>
    private string SamplesOf(PdfStream stream)
    {
        if (_samples.TryGetValue(stream, out string? known)) return known;
        byte[] data;
        try
        {
            data = document.Data(stream, MaxBytes);
        }
        catch (PdfReadException)
        {
            data = document.RawData(stream);
        }
        return _samples[stream] = Fingerprint(data);
    }
}
