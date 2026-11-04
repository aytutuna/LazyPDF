namespace LazyPDF.Core;

// A page's /Resources may list far more than the page draws: some writers give every page the
// resources of the whole file. Copying them all would carry fonts and pictures of pages that were
// left behind, so a copied page keeps the resources whose names its content mentions.
internal sealed partial class PageImporter
{
    private const int MaxRounds = 64;

    private static readonly string[] Named = ["Font", "XObject", "ExtGState", "ColorSpace", "Pattern", "Shading", "Properties"];

    private PdfObject Pruned(PdfPage page, PdfObject resources) => _same ? resources : Pruned(resources, UsedNames(page));

    // The resources of a form that has its own: the same rule, over the names its own content mentions.
    private PdfObject PrunedForm(PdfStream form, PdfObject resources)
    {
        if (_same) return resources;
        var used = new HashSet<string>();
        return Pruned(resources, TryCollectNames(form, used) ? used : null);
    }

    private PdfObject Pruned(PdfObject resources, HashSet<string>? used)
    {
        if (_source.Resolve(resources) is not PdfDictionary dictionary || used is null) return resources;
        // A form without resources of its own draws with the page's, so what it names counts as used (7.8.3).
        var scanned = new HashSet<PdfStream>(ReferenceEqualityComparer.Instance);
        for (int round = 0; round < MaxRounds; round++)
        {
            var pruned = new PdfDictionary();
            bool removed = false, grew = false;
            foreach (var (category, value) in dictionary.Entries)
            {
                if (!Named.Contains(category) || _source.Resolve(value) is not PdfDictionary group)
                {
                    pruned.Add(category, value);
                    continue;
                }
                var kept = new PdfDictionary();
                foreach (var (name, item) in group.Entries)
                {
                    if (used.Contains(name)) kept.Add(name, item);
                }
                foreach (var (_, item) in kept.Entries)
                {
                    switch (_source.Resolve(item))
                    {
                        case PdfStream { } form when category == "XObject" && _source.Name(form.Dictionary, "Subtype") == "Form" && _source.Dict(form.Dictionary, "Resources") is null:
                            if (!scanned.Add(form)) break;
                            if (!TryCollectNames(form, used)) return resources;
                            grew = true;
                            break;
                        case PdfDictionary font when category == "Font" && _source.Name(font, "Subtype") == "Type3" && _source.Dict(font, "Resources") is null:
                            return resources;
                    }
                }
                removed |= kept.Count < group.Count;
                pruned.Add(category, kept);
            }
            if (!grew) return removed ? pruned : resources;
        }
        return resources;
    }

    private bool TryCollectNames(PdfStream stream, HashSet<string> into)
    {
        try
        {
            CollectNames(_source.Data(stream), into);
            return true;
        }
        catch (PdfReadException)
        {
            return false;
        }
    }

    // Every name written in the content, whatever it is used for. Null when a stream does not decode: then nothing can be left out.
    private HashSet<string>? UsedNames(PdfPage page)
    {
        var used = new HashSet<string>();
        var contents = _source.Resolve(page.Dictionary["Contents"]);
        foreach (var item in contents is PdfArray array ? array.Items : [contents ?? PdfNull.Instance])
        {
            if (_source.Resolve(item) is PdfStream stream && !TryCollectNames(stream, used)) return null;
        }
        return used;
    }

    private static void CollectNames(byte[] content, HashSet<string> into)
    {
        var name = new System.Text.StringBuilder();
        for (int i = 0; i < content.Length; i++)
        {
            if (content[i] != '/') continue;
            name.Clear();
            for (i++; i < content.Length && !PdfLexer.IsWhiteSpace(content[i]) && !PdfLexer.IsDelimiter(content[i]); i++)
            {
                if (content[i] == '#' && i + 2 < content.Length && Uri.IsHexDigit((char)content[i + 1]) && Uri.IsHexDigit((char)content[i + 2]))
                {
                    name.Append((char)Convert.ToInt32(((char)content[i + 1]).ToString() + (char)content[i + 2], 16));
                    i += 2;
                }
                else
                {
                    name.Append((char)content[i]);
                }
            }
            into.Add(name.ToString());
            i--;
        }
    }
}
