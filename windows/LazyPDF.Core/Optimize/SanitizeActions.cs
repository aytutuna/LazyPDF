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

    /// <summary>Counts, and with the options takes out, JavaScript, launching or leaving actions, and links to a URI; also counts how many of each went.</summary>
    public static (ActionCounts Found, ActionCounts Taken) Run(PdfDocument document, bool removeScripts, bool removeLaunch, bool removeUri)
    {
        var chains = new Chains(document);
        bool Wanted(string kind) => kind switch { "JavaScript" => removeScripts, "URI" => removeUri, _ => removeLaunch };
        void Hang(PdfDictionary holder, string key)
        {
            if (document.Dict(holder, key) is not { } action) return;
            if (chains.Filter(holder[key]!, action, true, Wanted) is { } kept) holder[key] = kept;
            else holder.Remove(key);
        }
        foreach (var dictionary in PdfGraph.AllDictionaries(document))
        {
            if (dictionary.ContainsKey("OnInstantiate"))
            {
                chains.Found[0]++;
                if (removeScripts)
                {
                    chains.Taken[0]++;
                    dictionary.Remove("OnInstantiate");
                }
            }
            foreach (string key in new[] { "A", "OpenAction", "PA", "NA" }) Hang(dictionary, key);
            if (document.Dict(dictionary, "AA") is not { } triggers) continue;
            foreach (var (name, _) in triggers.Entries.ToArray()) Hang(triggers, name);
            if (triggers.Count == 0) dictionary.Remove("AA");
        }

        var names = document.Dict(document.Catalog, "Names");
        // Pages a script can spawn (12.7.6) and slide shows are content only the viewer's scripting or presentation mode reaches.
        foreach (string key in new[] { "JavaScript", "Templates", "Pages", "AlternatePresentations" })
        {
            if (names is null || !names.ContainsKey(key)) continue;
            var entries = PdfNameTree.Read(document, names[key]);
            int n = Math.Max(1, entries.Count);
            chains.Found[0] += n;
            if (removeScripts) chains.Taken[0] += n;
            // What follows an entry is an action too; the entries themselves are counted above.
            foreach (var entry in entries)
            {
                if (document.Resolve(entry.Value) is PdfDictionary action) chains.Filter(entry.Value, action, false, removeScripts ? _ => true : Wanted);
            }
            if (removeScripts) names.Remove(key);
        }
        if (document.Dict(document.Catalog, "AcroForm") is { } form && XfaHasScript(document, form["XFA"]))
        {
            chains.Found[0]++;
            if (removeScripts)
            {
                chains.Taken[0]++;
                form.Remove("XFA");
            }
        }
        if (document.Dict(document.Catalog, "URI") is not null)
        {
            chains.Found[2]++;
            if (removeUri)
            {
                chains.Taken[2]++;
                document.Catalog.Remove("URI");
            }
        }
        return (new ActionCounts(chains.Found[0], chains.Found[1], chains.Found[2]), new ActionCounts(chains.Taken[0], chains.Taken[1], chains.Taken[2]));
    }

    public static string Kind(PdfDocument document, PdfDictionary action)
    {
        string? type = document.Name(action, "S");
        if (type is null || !Known.Contains(type)) return "Other";
        if (type == "Rendition" && action.ContainsKey("JS")) return "JavaScript";
        return type == "JavaScript" ? "JavaScript" : type == "URI" ? "URI" : Leaving.Contains(type) ? "Launch" : "Other";
    }

    // The chain after an action is a graph (/Next may name an action twice or loop), so it is walked with a work list.
    // An action that stays is kept even behind one that goes: it takes the removed one's place in each link, and in the
    // holder when the root goes. A crafted file can make that rewiring quadratic, so the links written share one budget.
    private sealed class Chains(PdfDocument document)
    {
        private const int MaxLinks = 200_000;

        public readonly int[] Found = new int[3];
        public readonly int[] Taken = new int[3];
        private int _budget = MaxLinks;

        /// <summary>
        /// Takes the actions <paramref name="wanted"/> chooses out of the chain that starts at <paramref name="root"/>, which
        /// <paramref name="item"/> is as written. Returns what the holder names now, or null when nothing is left.
        /// A root that is not <paramref name="counted"/> is counted elsewhere and stays.
        /// </summary>
        public PdfObject? Filter(PdfObject item, PdfDictionary root, bool counted, Func<string, bool> wanted)
        {
            var raw = new Dictionary<PdfDictionary, PdfObject>(ReferenceEqualityComparer.Instance) { [root] = item };
            var gone = new HashSet<PdfDictionary>(ReferenceEqualityComparer.Instance);
            var pending = new Stack<PdfDictionary>([root]);
            while (pending.Count > 0)
            {
                var action = pending.Pop();
                string kind = Kind(document, action);
                if (kind != "Other" && (counted || !ReferenceEquals(action, root)))
                {
                    int slot = kind == "JavaScript" ? 0 : kind == "Launch" ? 1 : 2;
                    // A rendition with a script is still a media action, and it goes under either option.
                    bool media = kind == "JavaScript" && document.Name(action, "S") == "Rendition";
                    Found[slot]++;
                    if (media) Found[1]++;
                    if (wanted(kind) || (media && wanted("Launch")))
                    {
                        gone.Add(action);
                        Taken[slot]++;
                        if (media) Taken[1]++;
                    }
                }
                foreach (var (link, next) in Chained(document, action))
                {
                    if (raw.TryAdd(next, link)) pending.Push(next);
                }
            }
            if (gone.Count == 0) return item;

            var known = new Dictionary<PdfDictionary, List<PdfDictionary>>(ReferenceEqualityComparer.Instance);
            foreach (var action in raw.Keys.Where(a => !gone.Contains(a)).ToList())
            {
                var links = Chained(document, action);
                if (links.Any(l => gone.Contains(l.Action))) SetNext(action, links.SelectMany(l => gone.Contains(l.Action) ? Surviving(l.Action, gone, known) : [l.Action]), raw);
            }
            if (!gone.Contains(root)) return item;
            var left = Surviving(root, gone, known);
            if (left.Count == 0) return null;
            if (left.Count == 1) return raw[left[0]];
            // A holder names one action. The first survivor may be named elsewhere too, so a copy carries the others.
            var head = new PdfDictionary();
            foreach (var (key, value) in left[0].Entries) head.Add(key, value);
            SetNext(head, Chained(document, left[0]).Select(l => l.Action).Concat(left.Skip(1)), raw);
            return document.Add(head);
        }

        // The actions that stay among those chained after this one, looking through the ones that go.
        private List<PdfDictionary> Surviving(PdfDictionary from, HashSet<PdfDictionary> gone, Dictionary<PdfDictionary, List<PdfDictionary>> known)
        {
            if (known.TryGetValue(from, out var cached)) return cached;
            var found = new List<PdfDictionary>();
            var listed = new HashSet<PdfDictionary>(ReferenceEqualityComparer.Instance);
            var visited = new HashSet<PdfDictionary>(ReferenceEqualityComparer.Instance) { from };
            var pending = new Stack<PdfDictionary>();
            Expand(from, pending);
            while (pending.Count > 0 && _budget > 0)
            {
                var action = pending.Pop();
                if (!gone.Contains(action))
                {
                    if (listed.Add(action)) found.Add(action);
                }
                else if (visited.Add(action))
                {
                    Expand(action, pending);
                }
            }
            return known[from] = found;
        }

        private void Expand(PdfDictionary action, Stack<PdfDictionary> pending)
        {
            var links = Chained(document, action);
            _budget -= links.Count;
            for (int i = links.Count - 1; i >= 0; i--) pending.Push(links[i].Action);
        }

        private void SetNext(PdfDictionary action, IEnumerable<PdfDictionary> next, Dictionary<PdfDictionary, PdfObject> raw)
        {
            var items = next.Distinct().Take(Math.Max(0, _budget)).Select(n => raw[n]).ToList();
            _budget -= items.Count;
            if (items.Count == 0) action.Remove("Next");
            else action["Next"] = items.Count == 1 && document.Resolve(action["Next"]) is not PdfArray ? items[0] : new PdfArray(items);
        }
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

internal readonly record struct ActionCounts(int JavaScript, int Launch, int Uri);
