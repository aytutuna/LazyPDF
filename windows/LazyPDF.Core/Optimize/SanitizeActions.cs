using System.Text;

namespace LazyPDF.Core;

// Actions that run code, open other files or leave the document. They are taken out where they
// hang (/A, /AA, /OpenAction, /Next), and the name tree of document scripts goes whole.
internal static class SanitizeActions
{
    private static readonly HashSet<string> Leaving =
        ["Launch", "GoToR", "GoToE", "ImportData", "SubmitForm", "Thread", "Movie", "Sound", "Rendition", "RichMediaExecute"];

    private static readonly HashSet<string> Known =
        ["GoTo", "Named", "SetOCGState", "Hide", "ResetForm", "Trans", "GoTo3DView", "JavaScript", "URI", .. Leaving];

    /// <summary>Counts, and with <paramref name="remove"/> takes out, JavaScript, launching or leaving actions, and links to a URI.</summary>
    public static (int JavaScript, int Launch, int Uri) Run(PdfDocument document, bool removeScripts, bool removeLaunch, bool removeUri)
    {
        var count = new int[3];
        bool Wanted(string kind) => kind switch { "JavaScript" => removeScripts, "URI" => removeUri, _ => removeLaunch };
        foreach (var dictionary in PdfGraph.AllDictionaries(document))
        {
            foreach (string key in new[] { "A", "OpenAction", "PA" })
            {
                if (document.Dict(dictionary, key) is { } action && Kind(document, action) is not null && Filter(document, action, Wanted, count, []))
                {
                    dictionary.Remove(key);
                }
            }
            if (document.Dict(dictionary, "AA") is not { } triggers) continue;
            foreach (var (name, _) in triggers.Entries.ToArray())
            {
                if (document.Dict(triggers, name) is { } action && Kind(document, action) is not null && Filter(document, action, Wanted, count, [])) triggers.Remove(name);
            }
            if (triggers.Count == 0) dictionary.Remove("AA");
        }

        var names = document.Dict(document.Catalog, "Names");
        if (names is not null && names.ContainsKey("JavaScript"))
        {
            count[0] += Math.Max(1, PdfNameTree.Read(document, names["JavaScript"]).Count);
            if (removeScripts) names.Remove("JavaScript");
        }
        if (document.Dict(document.Catalog, "AcroForm") is { } form && XfaHasScript(document, form["XFA"]))
        {
            count[0]++;
            if (removeScripts) form.Remove("XFA");
        }
        if (document.Dict(document.Catalog, "URI") is not null)
        {
            count[2]++;
            if (removeUri) document.Catalog.Remove("URI");
        }
        return (count[0], count[1], count[2]);
    }

    public static string? Kind(PdfDocument document, PdfDictionary action)
    {
        string? type = document.Name(action, "S");
        return type is null ? null : !Known.Contains(type) ? "Other" : type == "JavaScript" ? "JavaScript" : type == "URI" ? "URI" : Leaving.Contains(type) ? "Launch" : "Other";
    }

    // True when the action itself is to go; otherwise the actions chained after it are filtered.
    private static bool Filter(PdfDocument document, PdfDictionary action, Func<string, bool> wanted, int[] count, HashSet<PdfDictionary> seen)
    {
        string kind = Kind(document, action)!;
        if (!seen.Add(action)) return false;
        if (kind != "Other")
        {
            count[kind == "JavaScript" ? 0 : kind == "Launch" ? 1 : 2]++;
            if (wanted(kind)) return true;
        }
        switch (document.Resolve(action["Next"]))
        {
            case PdfDictionary next when Kind(document, next) is not null && Filter(document, next, wanted, count, seen):
                action.Remove("Next");
                break;
            case PdfArray list:
                list.Items.RemoveAll(item => document.Resolve(item) is PdfDictionary next && Kind(document, next) is not null && Filter(document, next, wanted, count, seen));
                if (list.Items.Count == 0) action.Remove("Next");
                break;
        }
        return false;
    }

    private static bool XfaHasScript(PdfDocument document, PdfObject? xfa)
    {
        var parts = document.Resolve(xfa) is PdfArray array ? array.Items.Select(document.Resolve) : [document.Resolve(xfa)];
        foreach (var part in parts)
        {
            if (part is not PdfStream stream) continue;
            try
            {
                if (Encoding.Latin1.GetString(document.Data(stream)).Contains("<script", StringComparison.OrdinalIgnoreCase)) return true;
            }
            catch (PdfReadException)
            {
            }
        }
        return false;
    }
}
