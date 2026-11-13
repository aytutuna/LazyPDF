using System.Xml.Linq;

namespace LazyPDF.Core;

// The catalog: output intents, XMP metadata and its agreement with /Info, optional content, names and open action.
internal sealed partial class PdfAChecker
{
    private void CheckCatalog()
    {
        var catalog = _doc.Catalog;
        CheckOutputIntents();
        CheckMetadata();
        CheckOptionalContent();
        if (catalog.ContainsKey("AA")) Add(Part == 4 ? "6.6.3" : C("6.6.2", "6.5.2"), PdfAText.Catalog, PdfAText.CatalogTriggers);
        if (!IsPart1 && catalog.ContainsKey("NeedsRendering")) Add("6.4.2", PdfAText.Catalog, PdfAText.NeedsRendering);
        CheckAction(catalog["OpenAction"], PdfAText.Catalog);
        CheckOutlines();
        if (_doc.Dict(_doc.Dict(catalog, "Names"), "JavaScript") is not null) Add(C("6.6.1", "6.5.1"), PdfAText.Catalog, PdfAText.JavaScript);
        CheckForm();
    }

    private void CheckOutputIntents()
    {
        string clause = C("6.2.2", "6.2.3");
        int? profileNumber = null;
        foreach (var item in _doc.Array(_doc.Catalog, "OutputIntents")?.Items.Take(16) ?? [])
        {
            if (_doc.Resolve(item) is not PdfDictionary intent) continue;
            if (_doc.Resolve(intent["OutputConditionIdentifier"]) is not PdfString) Add(clause, PdfAText.OutputIntent, PdfAText.NoConditionIdentifier);
            if (_doc.Stream(intent, "DestOutputProfile") is not { } profile)
            {
                if (_doc.Name(intent, "S") == "GTS_PDFA1") Add(clause, PdfAText.OutputIntent, PdfAText.NoProfile);
                continue;
            }
            int? number = (intent["DestOutputProfile"] as PdfReference)?.Number;
            if (profileNumber is { } first && first != number) Add(clause, PdfAText.OutputIntent, PdfAText.ProfilesDiffer);
            profileNumber ??= number;
            long? n = _doc.Integer(profile.Dictionary, "N");
            if (n is not (1 or 3 or 4))
            {
                Add(clause, PdfAText.OutputIntent, PdfAText.ProfileComponents);
                continue;
            }
            string? fault;
            try
            {
                fault = IccProblem(_doc.Data(profile, 32L << 20), (int)n, IsPart1 ? 2 : 4, true);
            }
            catch (PdfReadException)
            {
                fault = PdfAText.ProfileUnreadable;
            }
            if (fault is not null) Add(clause, PdfAText.OutputIntent, fault);
            else if (_intentComponents == 0 && _doc.Name(intent, "S") == "GTS_PDFA1") _intentComponents = (int)n;
        }
    }

    private void CheckMetadata()
    {
        string clause = C("6.7.2", "6.6.2.1");
        if (_doc.Stream(_doc.Catalog, "Metadata") is not { } stream)
        {
            Add(clause, PdfAText.Catalog, PdfAText.NoMetadata);
            return;
        }
        if (stream.Dictionary.ContainsKey("Filter")) Add(clause, PdfAText.Metadata, PdfAText.MetadataFilter);
        byte[] bytes;
        try
        {
            bytes = _doc.Data(stream, 16L << 20);
        }
        catch (PdfReadException)
        {
            Add(clause, PdfAText.Metadata, PdfAText.XmpNotWellFormed);
            return;
        }
        if (PdfAXmp.Parse(bytes, out string? problem) is not { } xmp)
        {
            Add(clause, PdfAText.Metadata, problem!);
            return;
        }
        CheckIdentification(xmp);
        foreach (string ns in xmp.UndeclaredNamespaces()) Add(C("6.7.8", "6.6.2.3.1"), PdfAText.Metadata, PdfAText.NoExtensionSchema(ns));
        CheckInfo(xmp);
    }

    private void CheckIdentification(PdfAXmp xmp)
    {
        string clause = C("6.7.11", "6.6.4");
        string? part = xmp.Get(PdfAXmp.Id, "part")?.Trim();
        string? conformance = xmp.Get(PdfAXmp.Id, "conformance")?.Trim();
        if (part is null)
        {
            Add(clause, PdfAText.Metadata, PdfAText.NoIdentification);
            return;
        }
        if (part != Part.ToString(System.Globalization.CultureInfo.InvariantCulture)) Add(clause, PdfAText.Metadata, PdfAText.WrongPart(part, Part));
        if (Part == 4)
        {
            if (xmp.Get(PdfAXmp.Id, "rev")?.Trim() != "2020") Add(clause, PdfAText.Metadata, PdfAText.NoRevision);
            return;
        }
        string[] accepted = level.NeedsTags() ? ["A"] : level.NeedsUnicode() ? ["U", "A"] : IsPart1 ? ["B", "A"] : ["B", "U", "A"];
        if (conformance is null || !accepted.Contains(conformance)) Add(clause, PdfAText.Metadata, PdfAText.WrongConformance(conformance, level.Conformance()!));
    }

    // 6.7.3 in part 1: every /Info entry that has an XMP property has the same value there.
    private void CheckInfo(PdfAXmp xmp)
    {
        if (_doc.Info is not { } info) return;
        string clause = C("6.7.3", "6.6.2.3");
        if (Part == 4)
        {
            foreach (var (key, _) in info.Entries)
            {
                if (key is not ("CreationDate" or "ModDate")) Add("6.1.3", PdfAText.Info, PdfAText.InfoKey(key));
            }
        }
        void Same(string key, string other, XNamespace ns, string property)
        {
            if (PdfText.Read(_doc, info, key) is not { } value) return;
            string? xmpValue = xmp.Get(ns, property);
            bool date = key is "CreationDate" or "ModDate";
            bool equal = date
                ? PdfDate.Parse(value) is { } a && PdfDate.ParseXmp(xmpValue) is { } b && a.ToUniversalTime().ToUnixTimeSeconds() == b.ToUniversalTime().ToUnixTimeSeconds()
                : xmpValue == value;
            if (!equal) Add(clause, PdfAText.Info, PdfAText.InfoDiffers(key, other));
        }
        if (Part == 4)
        {
            Same("CreationDate", "xmp:CreateDate", PdfAXmp.Xmp, "CreateDate");
            Same("ModDate", "xmp:ModifyDate", PdfAXmp.Xmp, "ModifyDate");
            return;
        }
        Same("Title", "dc:title", PdfAXmp.Dc, "title");
        Same("Author", "dc:creator", PdfAXmp.Dc, "creator");
        Same("Subject", "dc:description", PdfAXmp.Dc, "description");
        Same("Keywords", "pdf:Keywords", PdfAXmp.Pdf, "Keywords");
        Same("Creator", "xmp:CreatorTool", PdfAXmp.Xmp, "CreatorTool");
        Same("Producer", "pdf:Producer", PdfAXmp.Pdf, "Producer");
        Same("CreationDate", "xmp:CreateDate", PdfAXmp.Xmp, "CreateDate");
        Same("ModDate", "xmp:ModifyDate", PdfAXmp.Xmp, "ModifyDate");
    }

    private void CheckOptionalContent()
    {
        if (_doc.Dict(_doc.Catalog, "OCProperties") is not { } properties) return;
        if (IsPart1)
        {
            Add("6.1.13", PdfAText.Catalog, PdfAText.OptionalContent);
            return;
        }
        string clause = "6.9";
        var configs = new List<PdfDictionary>();
        if (_doc.Dict(properties, "D") is { } main) configs.Add(main);
        else Add(clause, PdfAText.Catalog, PdfAText.NoDefaultConfig);
        configs.AddRange(_doc.Array(properties, "Configs")?.Items.Take(256).Select(_doc.Resolve).OfType<PdfDictionary>() ?? []);

        var names = new HashSet<string>();
        var groups = _doc.Array(properties, "OCGs")?.Items.OfType<PdfReference>().Select(r => r.Number).ToHashSet() ?? [];
        foreach (var config in configs)
        {
            if (_doc.Resolve(config["Name"]) is not PdfString name) Add(clause, PdfAText.Catalog, PdfAText.ConfigName);
            else if (!names.Add(System.Text.Encoding.Latin1.GetString(name.Bytes))) Add(clause, PdfAText.Catalog, PdfAText.ConfigNameTwice);
            if (config.ContainsKey("AS")) Add(clause, PdfAText.Catalog, PdfAText.AutoState);
            if (_doc.Array(config, "Order") is { } order && groups.Except(Listed(order)).Any()) Add(clause, PdfAText.Catalog, PdfAText.OrderIncomplete);
        }
    }

    private static HashSet<int> Listed(PdfArray order)
    {
        var numbers = new HashSet<int>();
        var stack = new Stack<PdfArray>([order]);
        for (int steps = 0; stack.Count > 0 && steps < 10_000; steps++)
        {
            foreach (var item in stack.Pop().Items)
            {
                if (item is PdfReference r) numbers.Add(r.Number);
                else if (item is PdfArray inner) stack.Push(inner);
            }
        }
        return numbers;
    }
}
