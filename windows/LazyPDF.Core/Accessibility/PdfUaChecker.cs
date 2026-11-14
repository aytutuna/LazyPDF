namespace LazyPDF.Core;

// The rule checks behind PdfUaValidator. Each Add names the Matterhorn failure condition and the clause of ISO 14289-1
// behind it; checkpoints come out in order because the checks run in order.
internal sealed partial class PdfUaChecker(PdfDocument document, CancellationToken cancel)
{
    private const int MaxIssues = 1000;
    private const int MaxEntries = 10_000;

    private readonly PdfDocument _doc = document;
    private readonly List<PdfUaIssue> _issues = [];
    private readonly HashSet<string> _seen = [];
    private bool _truncated;
    private StructureTree? _tree;

    public PdfUaReport Report() => new([.. _issues.OrderBy(i => i.Condition, StringComparer.Ordinal)], _truncated);

    public void Run()
    {
        CheckMarkInfo();
        _tree = StructureTree.Read(_doc);
        CheckTree();
        CheckContent();
        CheckMetadata();
        CheckDisplayTitle();
        CheckLanguage();
        CheckStructure();
        CheckOptionalContent();
        CheckEmbeddedFiles();
        CheckForm();
        CheckSecurity();
        CheckAnnotations();
        CheckXObjects();
    }

    private void Add(string condition, string clause, string where, string message)
    {
        if (_issues.Count >= MaxIssues)
        {
            _truncated = true;
            return;
        }
        if (_seen.Add($"{condition}|{where}|{message}")) _issues.Add(new PdfUaIssue(condition, clause, where, message));
    }

    private static string Place(StructElement element)
    {
        if (element.Reference is { } reference) return PdfAText.StructureElement(reference.Number);
        return PageOf(element) is >= 0 and var page ? PdfAText.PageName(page + 1) : PdfAText.Catalog;
    }

    private static int PageOf(StructElement element)
    {
        if (element.PageIndex >= 0) return element.PageIndex;
        foreach (var kid in element.Kids)
        {
            if (kid is StructContent { PageIndex: >= 0 } content) return content.PageIndex;
            if (kid is StructObject { PageIndex: >= 0 } target) return target.PageIndex;
        }
        return -1;
    }

    // No Matterhorn condition covers an untagged file, so these two carry the ISO clause only.
    private void CheckMarkInfo()
    {
        var info = _doc.Dict(_doc.Catalog, "MarkInfo");
        if (_doc.Bool(info, "Marked") != true) Add("", "6.2", PdfAText.Catalog, PdfUaText.NoMarkInfo);
        if (_doc.Bool(info, "Suspects") == true) Add("01-007", "7.1", PdfAText.Catalog, PdfUaText.Suspects);
    }

    private void CheckTree()
    {
        if (_tree is null) Add("", "7.1", PdfAText.Catalog, PdfUaText.NoStructTree);
        else if (_tree.IsTruncated) Add("", "7.1", PdfAText.Catalog, PdfUaText.StructTreeTooBig);
    }

    // 7.1: the catalog's XMP names PDF/UA and carries the title.
    private void CheckMetadata()
    {
        if (_doc.Stream(_doc.Catalog, "Metadata") is not { } stream)
        {
            Add("06-001", "7.1", PdfAText.Catalog, PdfUaText.NoMetadata);
            return;
        }
        PdfAXmp? xmp;
        string? problem = null;
        try
        {
            xmp = PdfAXmp.Parse(_doc.Data(stream, 16L << 20), out problem);
        }
        catch (PdfReadException)
        {
            xmp = null;
            problem = PdfAText.XmpNotWellFormed;
        }
        if (xmp is null)
        {
            Add("06-001", "7.1", PdfAText.Metadata, problem!);
            return;
        }
        if (xmp.Get(XmpPacket.PdfUAId, "part")?.Trim() != "1") Add("06-002", "5", PdfAText.Metadata, PdfUaText.NoIdentifier);
        if (string.IsNullOrWhiteSpace(xmp.Get(PdfAXmp.Dc, "title"))) Add("06-003", "7.1", PdfAText.Metadata, PdfUaText.NoTitle);
    }

    private void CheckDisplayTitle()
    {
        if (ViewerSettings.Read(_doc).DisplayDocTitle) return;
        bool listed = _doc.Dict(_doc.Catalog, "ViewerPreferences") is { } preferences && preferences.ContainsKey("DisplayDocTitle");
        Add(listed ? "07-002" : "07-001", "7.1", PdfAText.Catalog, PdfUaText.TitleNotShown);
    }

    // 7.2: the language of the text can be told, from the catalog or from every top structure element.
    private void CheckLanguage()
    {
        string? language = PdfText.Read(_doc, _doc.Catalog, "Lang");
        bool valid = language is not null && AccessibilityChecker.LanguageTagPattern.IsMatch(language);
        if (language is not null && !valid) Add("11-006", "7.2", PdfAText.Catalog, PdfUaText.BadLanguage(language));
        if (valid) return;
        if (language is null) Add("11-006", "7.2", PdfAText.Catalog, PdfUaText.NoLanguage);
        bool roots = _tree is { Roots.Count: > 0 } && _tree.Roots.All(r => r.Lang is not null && AccessibilityChecker.LanguageTagPattern.IsMatch(r.Lang));
        if (!roots) Add("11-001", "7.2", PdfAText.Catalog, PdfUaText.TextLanguage);
    }

    // 7.10: configurations have a name and no automatic state.
    private void CheckOptionalContent()
    {
        if (_doc.Dict(_doc.Catalog, "OCProperties") is not { } properties) return;
        var configs = new List<(PdfDictionary Config, string NoName)>();
        if (_doc.Dict(properties, "D") is { } main) configs.Add((main, "20-002"));
        configs.AddRange((_doc.Array(properties, "Configs")?.Items.Take(256).Select(_doc.Resolve).OfType<PdfDictionary>() ?? []).Select(c => (c, "20-001")));
        foreach (var (config, noName) in configs)
        {
            if (_doc.Resolve(config["Name"]) is not PdfString { Bytes.Length: > 0 }) Add(noName, "7.10", PdfAText.Catalog, PdfUaText.ConfigName);
            if (config.ContainsKey("AS")) Add("20-003", "7.10", PdfAText.Catalog, PdfUaText.ConfigAutoState);
        }
    }

    // 7.11: a file specification names the file twice, as F and as UF.
    private void CheckEmbeddedFiles()
    {
        var names = _doc.Dict(_doc.Catalog, "Names");
        foreach (var (_, value) in PdfNameTree.Read(_doc, names?["EmbeddedFiles"]).Take(MaxEntries)) CheckFileSpec(value);
    }

    private void CheckFileSpec(PdfObject? value)
    {
        if (_doc.Resolve(value) is PdfDictionary spec && (!spec.ContainsKey("F") || !spec.ContainsKey("UF"))) Add("21-001", "7.11", PdfAText.Catalog, PdfUaText.FileSpec);
    }

    // 7.15: a dynamic XFA form, one the viewer builds as it opens, has no structure to tag.
    private void CheckForm()
    {
        if (_doc.Dict(_doc.Catalog, "AcroForm") is { } form && form.ContainsKey("XFA") && _doc.Bool(_doc.Catalog, "NeedsRendering") == true)
            Add("25-001", "7.15", PdfAText.Form, PdfUaText.Xfa);
    }

    // 7.16: the extraction-for-accessibility permission is not withheld.
    private void CheckSecurity()
    {
        if (_doc.Security is { } security && (security.Permissions & PdfPermissions.ExtractForAccessibility) == 0)
            Add("26-002", "7.16", PdfAText.Catalog, PdfUaText.Encrypted);
    }
}
