using System.Text;

namespace LazyPDF.Core;

// Reader after Lazy Scan's PdfReaderLite.cs: its cross-reference tables, cross-reference streams,
// hybrid files, object streams and limits, with the refusals turned into repairs (PdfDocument.Repair.cs)
// and the page tree, security and editing added around them.

/// <summary>
/// An open PDF: the object table, the trailer and catalog, the pages and the facts about the file.
/// Objects load on first use and are cached, so the same object is always the same instance and
/// a change made to it stays. The reader repairs what it can (<see cref="Repairs"/>); what it
/// cannot is a <see cref="PdfReadException"/>. Not safe to share between threads.
/// </summary>
public sealed partial class PdfDocument : IDisposable
{
    /// <summary>The highest object number a PDF may use (ISO 32000-1 Annex C).</summary>
    internal const int MaxObjectNumber = 8_388_607;

    private const int MaxRepairs = 100;

    private byte[] _data;
    private PdfArrayBytes _bytes;
    private readonly List<string> _repairs = [];
    private string? _password;
    private int _headerVersionEnd;
    private bool _hadInfo;

    private PdfDocument(byte[] data)
    {
        _data = data;
        _bytes = new PdfArrayBytes(data);
    }

    public static PdfDocument Open(byte[] bytes, string? password = null)
    {
        var document = new PdfDocument(bytes);
        document._password = password;
        document.Load();
        return document;
    }

    public static PdfDocument Open(string path, string? password = null)
    {
        if (new FileInfo(path).Length > int.MaxValue) throw new PdfReadException(PdfReadProblem.Unsupported, "The file is too large.");
        return Open(File.ReadAllBytes(path), password);
    }

    public void Dispose()
    {
        _objects.Clear();
        _objectStreams.Clear();
        _entries.Clear();
        _pages = null;
    }

    /// <summary>What was wrong with the file and how it was got round, one line each (at most 100).</summary>
    public IReadOnlyList<string> Repairs => _repairs;

    internal void AddRepair(string text)
    {
        if (_repairs.Count < MaxRepairs) _repairs.Add(text);
        else if (_repairs.Count == MaxRepairs) _repairs.Add("More repairs were made than are listed.");
    }

    /// <summary>The bytes the document was read from, starting at the header (anything before it is cut off).</summary>
    public int Length => _data.Length;

    internal ReadOnlyMemory<byte> Source => _data;

    /// <summary>The newest trailer; /Root, /Info, /ID and /Encrypt come from an older one when the newest lacks them.</summary>
    public PdfDictionary Trailer { get; private set; } = new();

    public PdfDictionary Catalog { get; private set; } = new();

    public PdfDictionary? Info => Dict(Trailer, "Info");

    /// <summary>The trailer's two /ID strings; empty without them.</summary>
    public IReadOnlyList<byte[]> Id =>
        Array(Trailer, "ID") is { } ids ? [.. ids.Items.Select(Resolve).OfType<PdfString>().Select(s => s.Bytes)] : [];

    public bool IsEncrypted => _encrypt is not null;

    /// <summary>The handler that decrypts the file; null when it is not encrypted.</summary>
    public PdfSecurity? Security => _security;

    /// <summary>The version of the file: the header's, or the catalog's /Version when that is newer.</summary>
    public string Version
    {
        get
        {
            string header = HeaderVersion();
            return Name(Catalog, "Version") is { } declared && System.Version.TryParse(declared, out var d)
                   && System.Version.TryParse(header, out var h) && d > h ? declared : header;
        }
    }

    private string HeaderVersion()
    {
        int at = 5;
        var text = Encoding.Latin1.GetString(_data.AsSpan(at, Math.Min(_headerVersionEnd - at, 8)));
        return System.Version.TryParse(text, out _) ? text : "1.4";
    }

    private void Load()
    {
        FindHeader();
        bool rebuilt = false;
        try
        {
            LoadCrossReferences();
        }
        catch (PdfReadException e)
        {
            Rebuild(e.Message);
            rebuilt = true;
        }
        if (!rebuilt)
        {
            OpenSecurity();
            if (!CatalogUsable()) Rebuild("The catalog could not be read.");
        }
        _firstNew = NextObjectNumber;
        _trailerPrint = Print(Trailer);
        _hadInfo = Trailer.ContainsKey("Info");
    }

    /// <summary>The header must come in the first 1024 bytes; what is before it is cut off, so offsets count from it as viewers count them.</summary>
    private void FindHeader()
    {
        int at = _data.AsSpan(0, Math.Min(_data.Length, 1024)).IndexOf("%PDF-"u8);
        if (at < 0) throw new PdfReadException(PdfReadProblem.NotPdf, "The file does not start with %PDF.");
        if (at > 0)
        {
            _data = _data[at..];
            _bytes = new PdfArrayBytes(_data);
            AddRepair($"Cut {at} bytes before the %PDF header.");
        }
        int end = 5;
        while (end < _data.Length && end < 13 && (_data[end] is >= (byte)'0' and <= (byte)'9' || _data[end] == '.')) end++;
        _headerVersionEnd = end;
    }

    private bool CatalogUsable()
    {
        if (Resolve(Trailer["Root"]) is not PdfDictionary catalog) return false;
        if (Resolve(catalog["Pages"]) is not PdfDictionary) return false;
        Catalog = catalog;
        return true;
    }
}
