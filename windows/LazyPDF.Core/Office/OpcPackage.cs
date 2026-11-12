namespace LazyPDF.Core.Office;

internal sealed record OpcRelationship(string Id, string Type, string Target, string Part);

/// <summary>
/// An Office Open XML package on top of <see cref="ZipReader"/>: content types, relationships and parsed parts.
/// Part names are absolute (no leading slash), relationship targets are resolved against their source part, and
/// external targets are never followed.
/// </summary>
internal sealed class OpcPackage
{
    public const string ContentTypesNs = "http://schemas.openxmlformats.org/package/2006/content-types";
    public const string RelationshipsNs = "http://schemas.openxmlformats.org/package/2006/relationships";
    public const string OfficeDocument = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument";

    private readonly ZipReader _zip;
    private readonly Dictionary<string, string> _defaults = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, string> _overrides = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, XmlElement> _parsed = new(StringComparer.OrdinalIgnoreCase);

    private OpcPackage(ZipReader zip) => _zip = zip;

    public static OpcPackage Open(byte[] data, ZipLimits? limits = null)
    {
        var package = new OpcPackage(ZipReader.Open(data, limits));
        if (!package._zip.Contains("[Content_Types].xml")) throw PdfReadException.Damaged("The file is not an Office document: it has no [Content_Types].xml.");
        foreach (var e in package.Xml("[Content_Types].xml").Elements())
        {
            if (e.Uri != ContentTypesNs) continue;
            string? type = e.Attribute("ContentType");
            if (type is null) continue;
            if (e.Name == "Default" && e.Attribute("Extension") is { } ext) package._defaults[ext] = type;
            else if (e.Name == "Override" && e.Attribute("PartName") is { } name) package._overrides[name.TrimStart('/')] = type;
        }
        return package;
    }

    public bool Contains(string part) => _zip.Contains(part);

    public byte[] Bytes(string part) => _zip.Read(part);

    public XmlElement Xml(string part)
    {
        if (!_parsed.TryGetValue(part, out var root)) _parsed[part] = root = XmlTree.Parse(_zip.Read(part));
        return root;
    }

    public string? ContentType(string part)
    {
        if (_overrides.TryGetValue(part, out var type)) return type;
        int dot = part.LastIndexOf('.');
        return dot >= 0 && _defaults.TryGetValue(part[(dot + 1)..], out type) ? type : null;
    }

    /// <summary>The internal relationships of <paramref name="part"/> (empty string for the package itself).</summary>
    public IReadOnlyList<OpcRelationship> Relationships(string part)
    {
        int slash = part.LastIndexOf('/');
        string folder = slash < 0 ? "" : part[..slash];
        string name = slash < 0 ? part : part[(slash + 1)..];
        string path = (folder.Length > 0 ? folder + "/" : "") + "_rels/" + name + ".rels";
        var list = new List<OpcRelationship>();
        if (!_zip.Contains(path)) return list;
        foreach (var e in Xml(path).Elements(RelationshipsNs, "Relationship"))
        {
            string? id = e.Attribute("Id"), type = e.Attribute("Type"), target = e.Attribute("Target");
            if (id is null || type is null || target is null || e.Attribute("TargetMode") == "External") continue;
            list.Add(new OpcRelationship(id, type, Resolve(part, target), part));
        }
        return list;
    }

    private static string Resolve(string source, string target)
    {
        var segments = new List<string>();
        if (!target.StartsWith('/'))
        {
            int slash = source.LastIndexOf('/');
            if (slash >= 0) segments.AddRange(source[..slash].Split('/'));
        }
        foreach (string s in target.Replace("\\", "/").Split('/'))
        {
            if (s == "..") { if (segments.Count > 0) segments.RemoveAt(segments.Count - 1); }
            else if (s.Length > 0 && s != ".") segments.Add(s);
        }
        return string.Join('/', segments);
    }
}
