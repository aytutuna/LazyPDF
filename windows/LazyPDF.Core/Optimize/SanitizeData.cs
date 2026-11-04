namespace LazyPDF.Core;

// What a file carries besides what it shows: attachments, comments, entered form data,
// descriptive metadata, application data, web capture data and file names. Each method counts
// what it finds and, when asked, takes it out.
internal static class SanitizeData
{
    // Annotations that are the reader's own marks; links, widgets and media belong to the page.
    private static readonly HashSet<string> NotComments = ["Link", "Widget", "Screen", "Movie", "3D", "RichMedia", "PrinterMark", "TrapNet", "Watermark", "FileAttachment"];

    public static int EmbeddedFiles(PdfDocument document, bool remove)
    {
        int listed = PdfAttachments.List(document).Count;
        var all = PdfGraph.AllDictionaries(document);
        int specs = all.Count(d => d.ContainsKey("EF"));
        if (remove)
        {
            document.Dict(document.Catalog, "Names")?.Remove("EmbeddedFiles");
            RemoveAnnotations(document, a => document.Name(a, "Subtype") == "FileAttachment");
            foreach (var dictionary in all)
            {
                dictionary.Remove("EF");
                dictionary.Remove("AF");
                if (ReferenceEquals(dictionary, document.Catalog)) dictionary.Remove("Collection");
            }
        }
        return Math.Max(listed, specs);
    }

    public static int Comments(PdfDocument document, bool remove)
    {
        int found = 0;
        foreach (var page in document.Pages)
        {
            if (document.Array(page.Dictionary, "Annots") is not { } annots) continue;
            foreach (var item in annots.Items)
            {
                if (document.Resolve(item) is PdfDictionary a && IsComment(document, a) && document.Name(a, "Subtype") != "Popup") found++;
            }
        }
        if (remove) RemoveAnnotations(document, a => IsComment(document, a));
        return found;
    }

    private static bool IsComment(PdfDocument document, PdfDictionary annotation) =>
        document.Name(annotation, "Subtype") is { } type && !NotComments.Contains(type);

    private static void RemoveAnnotations(PdfDocument document, Func<PdfDictionary, bool> remove)
    {
        foreach (var page in document.Pages)
        {
            if (document.Array(page.Dictionary, "Annots") is not { } annots) continue;
            annots.Items.RemoveAll(item => document.Resolve(item) is PdfDictionary a && remove(a));
            if (annots.Items.Count == 0) page.Dictionary.Remove("Annots");
        }
    }

    public static int FormData(PdfDocument document, bool remove)
    {
        var form = PdfForm.Read(document);
        var entered = form.Fields.Where(f => f.Kind is not (FieldKind.Signature or FieldKind.PushButton) && !string.IsNullOrEmpty(f.Value) && f.Value != "Off").ToList();
        if (!remove) return entered.Count;
        foreach (var field in form.Fields)
        {
            for (var node = field.Dictionary; node is not null; node = document.Dict(node, "Parent")) node.Remove("DV");
        }
        form.Refresh();
        try
        {
            form.Reset();
        }
        catch (Exception e) when (e is PdfReadException or InvalidOperationException)
        {
            foreach (var field in entered) field.Dictionary.Remove("V");
        }
        document.Dict(document.Catalog, "AcroForm")?.Remove("XFA");
        return entered.Count;
    }

    public static int Metadata(PdfDocument document, bool remove)
    {
        int count = document.Trailer.ContainsKey("Info") ? 1 : 0;
        foreach (var dictionary in PdfGraph.AllDictionaries(document))
        {
            foreach (string key in new[] { "Metadata", "LastModified" })
            {
                if (!dictionary.ContainsKey(key)) continue;
                count++;
                if (remove) dictionary.Remove(key);
            }
        }
        if (remove) document.Trailer.Remove("Info");
        return count;
    }

    public static int PieceInfo(PdfDocument document, bool remove)
    {
        int count = 0;
        foreach (var dictionary in PdfGraph.AllDictionaries(document))
        {
            if (!dictionary.ContainsKey("PieceInfo")) continue;
            count++;
            if (remove) dictionary.Remove("PieceInfo");
        }
        return count;
    }

    public static int Thumbnails(PdfDocument document, bool remove)
    {
        int count = document.Pages.Count(p => p.Dictionary.ContainsKey("Thumb"));
        if (remove) OptimizeStrip.Thumbnails(document);
        return count;
    }

    // Web capture keeps its own indexes of pages and addresses.
    public static int SearchIndexes(PdfDocument document, bool remove)
    {
        int count = 0;
        void Take(PdfDictionary? owner, string key)
        {
            if (owner is null || !owner.ContainsKey(key)) return;
            count++;
            if (remove) owner.Remove(key);
        }
        Take(document.Catalog, "SpiderInfo");
        var names = document.Dict(document.Catalog, "Names");
        Take(names, "IDS");
        Take(names, "URLS");
        foreach (var page in document.Pages)
        {
            if (page.Dictionary["ID"] is PdfString) Take(page.Dictionary, "ID");
        }
        return count;
    }

    /// <summary>Cuts file specifications down to a bare file name and drops their platform variants.</summary>
    public static int FilePaths(PdfDocument document, bool remove)
    {
        int count = 0;
        foreach (var dictionary in PdfGraph.AllDictionaries(document))
        {
            bool spec = document.Name(dictionary, "Type") == "Filespec" || dictionary.ContainsKey("EF")
                || (SanitizeActions.Kind(document, dictionary) is "Launch");
            if (!spec) continue;
            bool changed = false;
            foreach (string key in new[] { "F", "UF" })
            {
                if (dictionary[key] is not PdfString text) continue;
                string shown = PdfText.Decode(text.Bytes);
                int cut = shown.LastIndexOfAny(['/', '\\']);
                if (cut < 0) continue;
                changed = true;
                if (remove) text.Bytes = PdfText.Encode(shown[(cut + 1)..]);
            }
            foreach (string key in new[] { "DOS", "Mac", "Unix" })
            {
                if (!dictionary.ContainsKey(key)) continue;
                changed = true;
                if (remove) dictionary.Remove(key);
            }
            if (changed) count++;
        }
        return count;
    }
}
