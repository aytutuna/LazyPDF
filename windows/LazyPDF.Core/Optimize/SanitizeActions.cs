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
            if (dictionary.ContainsKey("OnInstantiate"))
            {
                count[0]++;
                if (removeScripts) dictionary.Remove("OnInstantiate");
            }
            foreach (string key in new[] { "A", "OpenAction", "PA", "NA" })
            {
                if (document.Dict(dictionary, key) is { } action) Filter(document, dictionary, key, action, Wanted, count);
            }
            if (document.Dict(dictionary, "AA") is not { } triggers) continue;
            foreach (var (name, _) in triggers.Entries.ToArray())
            {
                if (document.Dict(triggers, name) is { } action) Filter(document, triggers, name, action, Wanted, count);
            }
            if (triggers.Count == 0) dictionary.Remove("AA");
        }

        var names = document.Dict(document.Catalog, "Names");
        // Pages a script can spawn (12.7.6) and slide shows are content only the viewer's scripting or presentation mode reaches.
        foreach (string key in new[] { "JavaScript", "Templates", "Pages", "AlternatePresentations" })
        {
            if (names is null || !names.ContainsKey(key)) continue;
            count[0] += Math.Max(1, PdfNameTree.Read(document, names[key]).Count);
            if (removeScripts) names.Remove(key);
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

    public static string Kind(PdfDocument document, PdfDictionary action)
    {
        string? type = document.Name(action, "S");
        if (type is null || !Known.Contains(type)) return "Other";
        if (type == "Rendition" && action.ContainsKey("JS")) return "JavaScript";
        return type == "JavaScript" ? "JavaScript" : type == "URI" ? "URI" : Leaving.Contains(type) ? "Launch" : "Other";
    }

    // Takes the actions the options choose out of the chain that starts at holder[key]. The chain is a graph
    // (/Next may name an action twice or loop), so it is walked with a work list. An action that stays is kept even behind
    // one that goes: it takes the removed one's place in each link, and in the holder when the root goes.
    private static void Filter(PdfDocument document, PdfDictionary holder, string key, PdfDictionary root, Func<string, bool> wanted, int[] count)
    {
        var raw = new Dictionary<PdfDictionary, PdfObject>(ReferenceEqualityComparer.Instance) { [root] = holder[key]! };
        var gone = new HashSet<PdfDictionary>(ReferenceEqualityComparer.Instance);
        var pending = new Stack<PdfDictionary>([root]);
        while (pending.Count > 0)
        {
            var action = pending.Pop();
            string kind = Kind(document, action);
            if (kind != "Other")
            {
                count[kind == "JavaScript" ? 0 : kind == "Launch" ? 1 : 2]++;
                // A rendition with a script is still a media action.
                bool media = kind == "JavaScript" && document.Name(action, "S") == "Rendition";
                if (media) count[1]++;
                if (wanted(kind) || (media && wanted("Launch"))) gone.Add(action);
            }
            foreach (var (item, next) in Chained(document, action))
            {
                if (raw.TryAdd(next, item)) pending.Push(next);
            }
        }
        if (gone.Count == 0) return;
        foreach (var action in raw.Keys.Where(a => !gone.Contains(a)).ToList())
        {
            var links = Chained(document, action);
            if (links.Any(l => gone.Contains(l.Action))) SetNext(document, action, links.SelectMany(l => gone.Contains(l.Action) ? Surviving(document, l.Action, gone) : [l.Action]), raw);
        }
        if (!gone.Contains(root)) return;
        var left = Surviving(document, root, gone);
        if (left.Count == 0)
        {
            holder.Remove(key);
            return;
        }
        holder[key] = raw[left[0]];
        if (left.Count > 1) SetNext(document, left[0], Chained(document, left[0]).Select(l => l.Action).Concat(left.Skip(1)), raw);
    }

    // The actions that stay among those chained after this one, looking through the ones that go.
    private static List<PdfDictionary> Surviving(PdfDocument document, PdfDictionary from, HashSet<PdfDictionary> gone)
    {
        var found = new List<PdfDictionary>();
        var visited = new HashSet<PdfDictionary>(ReferenceEqualityComparer.Instance) { from };
        var pending = new Stack<PdfDictionary>(Chained(document, from).Select(l => l.Action).Reverse());
        while (pending.Count > 0)
        {
            var action = pending.Pop();
            if (!gone.Contains(action))
            {
                if (!found.Contains(action)) found.Add(action);
            }
            else if (visited.Add(action))
            {
                foreach (var (_, next) in Chained(document, action).AsEnumerable().Reverse()) pending.Push(next);
            }
        }
        return found;
    }

    private static void SetNext(PdfDocument document, PdfDictionary action, IEnumerable<PdfDictionary> next, Dictionary<PdfDictionary, PdfObject> raw)
    {
        var items = next.Distinct().Select(n => raw[n]).ToList();
        if (items.Count == 0) action.Remove("Next");
        else action["Next"] = items.Count == 1 && document.Resolve(action["Next"]) is not PdfArray ? items[0] : new PdfArray(items);
    }

    private static List<(PdfObject Item, PdfDictionary Action)> Chained(PdfDocument document, PdfDictionary action) => document.Resolve(action["Next"]) switch
    {
        PdfDictionary next => [(action["Next"]!, next)],
        PdfArray list => [.. list.Items.Select(i => (Item: i, Action: document.Resolve(i) as PdfDictionary)).Where(l => l.Action is not null).Select(l => (l.Item, l.Action!))],
        _ => [],
    };

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
