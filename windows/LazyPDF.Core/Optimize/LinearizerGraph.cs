namespace LazyPDF.Core;

// The object graph of a linearization: what the trailer reaches, who uses what, and the sections
// the objects fall into (Annex F.3). An object only one page reaches goes in that page's section;
// one that several pages reach goes in the shared section, or in the first page's when page one
// is among them. Page objects end a walk, so a link to another page does not pull it in.
internal sealed partial class Linearizer
{
    // The cap on object visits over all walks. A page's walk sees everything it uses, shared or not,
    // so the total is about the size of the hint tables.
    private const long MaxVisits = 100_000_000;
    private const int MaxDepth = 256;

    // Page tree attributes a page takes from its ancestors (7.7.3.4). Hint tables describe a page by
    // the objects it reaches, so they have to be on the page itself.
    private static readonly string[] Inherited = ["Resources", "MediaBox", "CropBox", "Rotate"];

    private static readonly string[] OpenKeys = ["ViewerPreferences", "PageMode", "Threads", "OpenAction", "AcroForm"];

    private readonly List<PdfObject> _items = [];
    private readonly List<int> _oldNumbers = [];
    private readonly List<int[]> _children = [];
    private readonly Dictionary<int, int> _index = [];
    private readonly HashSet<int> _pageNumbers = [];
    private readonly Dictionary<int, PdfObject> _made = [];
    private readonly Dictionary<PdfObject, PdfReference> _promoted = new(ReferenceEqualityComparer.Instance);
    private readonly List<int> _stack = [];
    private int _followed;
    private int _nextMade;
    private long _visits;

    private int[] _pageItem = [];
    private int _root;
    private int _info = -1;
    private int _encrypt = -1;
    private List<int> _part4 = [];
    private readonly List<int> _outlines = [];
    private readonly List<int> _part6 = [];
    private readonly List<int> _part8 = [];
    private readonly List<int> _part9 = [];
    private List<int>[] _pageObjects = [];
    private List<int>[] _pageShared = [];

    private PdfObject? Load(int number) => _made.TryGetValue(number, out var made) ? made : document.Get(number);

    private void Collect()
    {
        _nextMade = document.NextObjectNumber;
        var pages = new List<PdfReference>();
        var distinct = new List<PdfPage>();
        foreach (var page in document.Pages)
        {
            if (!_pageNumbers.Add(page.Reference.Number)) continue;
            pages.Add(page.Reference);
            distinct.Add(page);
            PushDown(page);
        }
        if (pages.Count == 0) throw new InvalidOperationException("The document has no pages.");
        if (!TreeIsClean(pages)) Flatten(distinct);

        _root = Intern(document.Trailer["Root"]);
        if (_root < 0 || _items[_root] is not PdfDictionary) throw PdfReadException.Damaged("The catalog is missing.");
        if (document.Info is not null) _info = Intern(document.Trailer["Info"]);
        Follow();
        _pageItem = [.. pages.Select(Intern).Where(i => i >= 0)];
        Follow();
        if (options.Security is { } security)
        {
            _encrypt = _items.Count;
            _items.Add(security.Dictionary);
            _oldNumbers.Add(-1);
            _children.Add([]);
        }
    }

    /// <summary>The index of the object <paramref name="entry"/> names or is; -1 for nothing there.</summary>
    private int Intern(PdfObject? entry)
    {
        if (entry is PdfReference reference)
        {
            if (_index.TryGetValue(reference.Number, out int known)) return known;
            if (Load(reference.Number) is not { } value || value is PdfNull) return -1;
            _items.Add(value);
            _oldNumbers.Add(reference.Number);
            return _index[reference.Number] = _items.Count - 1;
        }
        if (document.Resolve(entry) is not { } direct) return -1;
        _items.Add(direct);
        _oldNumbers.Add(-1);
        return _items.Count - 1;
    }

    private void Follow()
    {
        for (; _followed < _items.Count; _followed++)
        {
            var item = _items[_followed];
            var edges = new List<int>();
            bool page = IsPage(_followed);
            if (item is PdfStream stream) VisitEntries(stream.Dictionary, true, page, edges);
            else if (item is PdfDictionary dictionary) VisitEntries(dictionary, false, page, edges);
            else Visit(item, edges);
            _children.Add([.. edges]);
        }
    }

    /// <summary>
    /// A page keeps its /Parent out of the edges (the tree above is not the page's) and so does its
    /// thumbnail (F.3.3 sets thumbnails apart), and it lists /Contents first, so that the content
    /// streams come right after the page object.
    /// </summary>
    private void VisitEntries(PdfDictionary dictionary, bool stream, bool page, List<int> edges)
    {
        if (page)
        {
            foreach (var (key, item) in dictionary.Entries)
            {
                if (key == "Contents") Visit(item, edges);
            }
        }
        foreach (var (key, item) in dictionary.Entries)
        {
            if (stream && key == "Length") continue;
            if (page && key == "Contents") continue;
            // Interned all the same, so that the reference written for it has an object behind it.
            Visit(item, page && key is "Parent" or "Thumb" ? [] : edges);
        }
    }

    private void Visit(PdfObject value, List<int> edges)
    {
        switch (value)
        {
            case PdfReference:
                int child = Intern(value);
                if (child >= 0 && !IsPage(child)) edges.Add(child);
                break;
            case PdfArray array:
                foreach (var item in array.Items) Visit(item, edges);
                break;
            case PdfDictionary dictionary:
                foreach (var (_, item) in dictionary.Entries) Visit(item, edges);
                break;
        }
    }

    private PdfDictionary PageDictionary(int item) => _items[item] as PdfDictionary ?? ((PdfStream)_items[item]).Dictionary;

    private bool IsPage(int item) => _oldNumbers[item] is var old and >= 0 && _pageNumbers.Contains(old);

    private void PushDown(PdfPage page)
    {
        var dictionary = page.Dictionary;
        PdfDictionary? copy = null;
        var link = dictionary["Parent"];
        for (int depth = 0; depth < MaxDepth && link is PdfReference reference; depth++)
        {
            if (document.Get(reference.Number) is not PdfDictionary node) break;
            foreach (string key in Inherited)
            {
                if (node[key] is not { } value || (copy ?? dictionary).ContainsKey(key)) continue;
                copy ??= dictionary.Copy();
                copy[key] = Promote(value);
            }
            if (Inherited.Any(node.ContainsKey))
            {
                var stripped = _made.GetValueOrDefault(reference.Number) as PdfDictionary ?? node.Copy();
                foreach (string key in Inherited) stripped.Remove(key);
                _made[reference.Number] = stripped;
            }
            link = node["Parent"];
        }
        // Resources are required (7.7.3.3); a page that has none is given an empty set rather than left for a reader to repair.
        if (!(copy ?? dictionary).ContainsKey("Resources"))
        {
            copy ??= dictionary.Copy();
            copy["Resources"] = new PdfDictionary();
        }
        if (copy is not null) _made[page.Reference.Number] = copy;
    }

    /// <summary>
    /// The tree under the catalog reaches exactly these pages, once each, with the right /Count in
    /// every node. The hint tables count pages the way a strict reader counts them from the tree.
    /// </summary>
    private bool TreeIsClean(List<PdfReference> pages)
    {
        var leaves = new List<int>();
        var seen = new HashSet<int>();
        bool Node(PdfObject? link, int depth, out int count)
        {
            count = 0;
            if (depth > MaxDepth || link is not PdfReference reference || !seen.Add(reference.Number)) return false;
            if (document.Get(reference.Number) is not PdfDictionary node) return false;
            if (_pageNumbers.Contains(reference.Number))
            {
                leaves.Add(reference.Number);
                count = 1;
                return true;
            }
            if (node["Kids"] is not PdfArray kids) return false;
            foreach (var kid in kids.Items)
            {
                if (!Node(kid, depth + 1, out int below)) return false;
                count += below;
            }
            return document.Integer(node, "Count") == count;
        }
        return Node(document.Catalog["Pages"], 0, out _) && leaves.SequenceEqual(pages.Select(p => p.Number));
    }

    /// <summary>One node over all the pages, for a tree that is not clean.</summary>
    private void Flatten(List<PdfPage> pages)
    {
        if (document.Catalog["Pages"] is not PdfReference root) return;
        var node = new PdfDictionary();
        node.Add("Type", new PdfName("Pages"));
        node.Add("Kids", new PdfArray([.. pages.Select(p => p.Reference)]));
        node.Add("Count", new PdfNumber(pages.Count));
        _made[root.Number] = node;
        foreach (var page in pages)
        {
            var copy = _made.GetValueOrDefault(page.Reference.Number) as PdfDictionary ?? page.Dictionary.Copy();
            copy["Parent"] = root;
            _made[page.Reference.Number] = copy;
        }
    }

    /// <summary>A direct dictionary (the resources of a node) becomes one object, so that the pages inheriting it share it.</summary>
    private PdfObject Promote(PdfObject value)
    {
        if (value is not PdfDictionary) return value;
        if (_promoted.TryGetValue(value, out var known)) return known;
        var reference = new PdfReference(_nextMade++, 0);
        _made[reference.Number] = value;
        return _promoted[value] = reference;
    }

    private void Classify()
    {
        int count = _pageItem.Length;
        var catalog = (PdfDictionary)_items[_root];
        var mark = new int[_items.Count];
        int token = 0;

        // What the document-level keys reach belongs to the first section whichever page uses it: a
        // viewer reads that before anything else, so no page's hint entry lists it (the rule qpdf's check applies).
        var open = new bool[_items.Count];
        open[_root] = true;
        foreach (var (key, value) in catalog.Entries)
        {
            if (!OpenKeys.Contains(key)) continue;
            var starts = new List<int>();
            References(value, starts);
            foreach (int start in starts)
            {
                Walk(start, mark, ++token, o =>
                {
                    if (open[o]) return false;
                    open[o] = true;
                    return true;
                });
            }
        }

        // What a page's thumbnail reaches. An object only that page and its thumbnail use goes with the thumbnails.
        var thumbs = new bool[_items.Count];
        foreach (int pageItem in _pageItem)
        {
            var starts = new List<int>();
            References(PageDictionary(pageItem)["Thumb"], starts);
            foreach (int start in starts)
            {
                Walk(start, mark, ++token, o =>
                {
                    if (thumbs[o]) return false;
                    thumbs[o] = true;
                    return true;
                });
            }
        }

        var owner = new int[_items.Count];
        Array.Fill(owner, -1);
        var shared = new bool[_items.Count];
        for (int p = 0; p < count; p++)
        {
            int page = p;
            Walk(_pageItem[p], mark, ++token, o =>
            {
                if (open[o]) return false;
                if (owner[o] < 0) owner[o] = page;
                else if (owner[o] != page) shared[o] = true;
                return true;
            });
        }

        var placed = new bool[_items.Count];
        _pageObjects = new List<int>[count];
        _pageShared = new List<int>[count];
        for (int p = 0; p < count; p++)
        {
            int page = p;
            var own = _pageObjects[p] = p == 0 ? _part6 : [];
            var uses = _pageShared[p] = [];
            Walk(_pageItem[p], mark, ++token, o =>
            {
                if (open[o]) return false;
                if (!shared[o] && thumbs[o]) return true;
                if (page == 0 || !shared[o])
                {
                    placed[o] = true;
                    own.Add(o);
                }
                else
                {
                    if (owner[o] != 0 && !placed[o])
                    {
                        placed[o] = true;
                        _part8.Add(o);
                    }
                    uses.Add(o);
                }
                return true;
            });
        }

        // The bookmarks are kept together, in the first page's section when the file opens on them (F.3.3).
        var bookmarks = new List<int>();
        References(catalog["Outlines"], bookmarks);
        foreach (int start in bookmarks)
        {
            Walk(start, mark, ++token, o =>
            {
                if (open[o] || placed[o] || owner[o] >= 0) return false;
                placed[o] = true;
                _outlines.Add(o);
                return true;
            });
        }
        if (document.Name(catalog, "PageMode") == "UseOutlines") _part6.AddRange(_outlines);
        else _part9.AddRange(_outlines);

        _part4 = [_root];
        if (_encrypt >= 0) _part4.Add(_encrypt);
        for (int o = 0; o < _items.Count; o++)
        {
            if (open[o] && o != _root) _part4.Add(o);
        }
        foreach (int o in _part4) placed[o] = true;
        for (int o = 0; o < _items.Count; o++)
        {
            if (!placed[o]) _part9.Add(o);
        }
    }

    private void References(PdfObject? value, List<int> into)
    {
        switch (value)
        {
            case PdfReference reference when _index.TryGetValue(reference.Number, out int item) && !IsPage(item):
                into.Add(item);
                break;
            case PdfArray array:
                foreach (var entry in array.Items) References(entry, into);
                break;
            case PdfDictionary dictionary:
                foreach (var (_, entry) in dictionary.Entries) References(entry, into);
                break;
        }
    }

    /// <summary>A depth-first walk in the order the objects are written; <paramref name="visit"/> says whether to go on below an object.</summary>
    private void Walk(int start, int[] mark, int token, Func<int, bool> visit)
    {
        _stack.Clear();
        _stack.Add(start);
        while (_stack.Count > 0)
        {
            int o = _stack[^1];
            _stack.RemoveAt(_stack.Count - 1);
            if (mark[o] == token) continue;
            mark[o] = token;
            if (++_visits > MaxVisits) throw new PdfReadException(PdfReadProblem.Unsupported, "The file is too large to linearize.");
            if (!visit(o)) continue;
            var below = _children[o];
            for (int i = below.Length - 1; i >= 0; i--)
            {
                if (mark[below[i]] != token) _stack.Add(below[i]);
            }
        }
    }
}
