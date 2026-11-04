using System.Security.Cryptography;

namespace LazyPDF.Core;

// The /DSS dictionary (ETSI EN 319 142-1 5.4.2): shared streams of certificates, OCSP responses and CRLs, and a
// /VRI entry per signature, keyed by the SHA-1 of its /Contents. What the file already holds is reused, not written twice.
internal sealed class DssWriter
{
    public sealed class Entry
    {
        public List<PdfReference> Certificates { get; } = [];
        public List<PdfReference> Ocsps { get; } = [];
        public List<PdfReference> Crls { get; } = [];
    }

    private readonly PdfDocument _document;
    private readonly PdfDictionary _dss;
    private readonly PdfReference? _dssReference;
    private readonly PdfDictionary _vri;
    private readonly Dictionary<string, PdfReference> _known = [];
    private bool _touched;

    public DssWriter(PdfDocument document)
    {
        _document = document;
        if (document.Catalog["DSS"] is PdfReference reference && document.Resolve(reference) is PdfDictionary existing)
        {
            _dss = existing;
            _dssReference = reference;
        }
        else if (document.Catalog["DSS"] is PdfDictionary direct)
        {
            _dss = direct;
        }
        else
        {
            _dss = new PdfDictionary { ["Type"] = new PdfName("DSS") };
        }
        _vri = document.Dict(_dss, "VRI") ?? new PdfDictionary();
        foreach (string key in (ReadOnlySpan<string>)["Certs", "OCSPs", "CRLs"])
        {
            if (document.Array(_dss, key) is not { } array) continue;
            foreach (var item in array.Items)
            {
                if (item is PdfReference r && document.Resolve(r) is PdfStream stream) _known.TryAdd(Hash(document.Data(stream)), r);
            }
        }
    }

    public PdfReference Certificate(System.Security.Cryptography.X509Certificates.X509Certificate2 certificate) => Stream("Certs", certificate.RawData);
    public PdfReference Ocsp(byte[] der) => Stream("OCSPs", der);
    public PdfReference Crl(byte[] der) => Stream("CRLs", der);

    public void Signature(byte[] contents, Entry entry, DateTimeOffset time)
    {
        string key = Convert.ToHexString(SHA1.HashData(contents));
        if (_vri.ContainsKey(key)) return;
        var dictionary = new PdfDictionary { ["Type"] = new PdfName("VRI") };
        AddList(dictionary, "Cert", entry.Certificates);
        AddList(dictionary, "OCSP", entry.Ocsps);
        AddList(dictionary, "CRL", entry.Crls);
        dictionary["TU"] = new PdfString(System.Text.Encoding.ASCII.GetBytes(PdfDate.Format(time)), isHex: false);
        _vri[key] = dictionary;
        _touched = true;
    }

    /// <summary>Puts the dictionary in the catalog; nothing changes in the document when nothing was added.</summary>
    public void Save()
    {
        if (!_touched) return;
        if (!_dss.ContainsKey("VRI")) _dss["VRI"] = _vri;
        if (_dssReference is null && _document.Catalog["DSS"] is null) _document.Catalog["DSS"] = _document.Add(_dss);
    }

    private PdfReference Stream(string list, byte[] bytes)
    {
        string hash = Hash(bytes);
        if (_known.TryGetValue(hash, out var known)) return known;
        var dictionary = new PdfDictionary { ["Filter"] = new PdfName("FlateDecode") };
        var reference = _document.Add(new PdfStream(dictionary, PdfFilterEncoders.Flate(bytes)));
        _known[hash] = reference;
        _touched = true;
        if (_document.Array(_dss, list) is { } array) array.Items.Add(reference);
        else _dss[list] = new PdfArray([reference]);
        return reference;
    }

    private static void AddList(PdfDictionary dictionary, string key, List<PdfReference> items)
    {
        if (items.Count > 0) dictionary[key] = new PdfArray([.. items.Distinct()]);
    }

    private static string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes));
}
