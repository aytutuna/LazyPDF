namespace LazyPDF.Core;

// The tags: role map, nesting, headings, alternate text and notes (ISO 14289-1 7.1 to 7.9).
internal sealed partial class PdfUaChecker
{
    private static readonly string[] TableParts = ["THead", "TBody", "TFoot"];

    // Types whose own parent is checked, so a wrong child is not reported a second time from the parent.
    private static readonly string[] Placed = ["THead", "TBody", "TFoot", "TR", "TH", "TD", "LI", "Lbl", "LBody"];

    private void CheckStructure()
    {
        if (_tree is null) return;
        var elements = _tree.Elements.ToList();
        string Type(StructElement e) => _tree.StandardType(e.Type);
        CheckRoleMap(elements);
        CheckNesting(elements, Type);
        CheckHeadings(elements, Type);

        var notes = new HashSet<string>();
        foreach (var element in elements)
        {
            cancel.ThrowIfCancellationRequested();
            string type = Type(element);
            if (type is "Figure" or "Formula" && string.IsNullOrWhiteSpace(element.Alt) && string.IsNullOrWhiteSpace(element.ActualText))
                Add(type == "Figure" ? "13-004" : "17-002", type == "Figure" ? "7.3" : "7.7", Place(element), PdfUaText.NoAlt(type));
            if (element.Lang is { } lang && !AccessibilityChecker.LanguageTagPattern.IsMatch(lang)) Add("11-007", "7.2", Place(element), PdfUaText.BadLanguage(lang));
            if (type != "Note") continue;
            if (string.IsNullOrEmpty(element.Id)) Add("19-003", "7.9", Place(element), PdfUaText.NoteId);
            else if (!notes.Add(element.Id)) Add("19-004", "7.9", Place(element), PdfUaText.NoteIdTwice(element.Id));
        }
    }

    // 7.1: a type that is not standard leads to one that is, through a role map without loops, and a standard type is not remapped.
    private void CheckRoleMap(List<StructElement> elements)
    {
        var tree = _tree!;
        foreach (var (key, value) in tree.RoleMap.OrderBy(e => e.Key, StringComparer.Ordinal).Take(MaxEntries))
        {
            if (StructureTree.IsStandard(key) && key != value) Add("02-003", "7.1", PdfAText.Catalog, PdfUaText.StandardRemapped(key, value));
        }
        var first = new Dictionary<string, StructElement>(StringComparer.Ordinal);
        foreach (var element in elements) first.TryAdd(element.Type, element);
        var types = new HashSet<string>(tree.RoleMap.Keys.Take(MaxEntries).Concat(first.Keys));
        foreach (string type in types.OrderBy(t => t, StringComparer.Ordinal))
        {
            cancel.ThrowIfCancellationRequested();
            if (_truncated) break;
            if (StructureTree.IsStandard(type)) continue;
            bool loop = Loops(type);
            if (loop) Add("02-002", "7.1", PdfAText.Catalog, PdfUaText.RoleMapCircular(type));
            else if (!StructureTree.IsStandard(tree.StandardType(type)) && first.TryGetValue(type, out var element))
                Add("02-001", "7.1", Place(element), PdfUaText.NotMapped(type));
        }
    }

    // The chain never reaches a standard type or an end: it comes back to a type it met, or runs past 16 steps.
    private bool Loops(string type)
    {
        var met = new HashSet<string>();
        while (!StructureTree.IsStandard(type) && _tree!.RoleMap.TryGetValue(type, out var next))
        {
            if (!met.Add(type) || met.Count > 16) return true;
            type = next;
        }
        return false;
    }

    // 7.5 and 7.6: rows hold cells, sections hold rows, items hold a label and a body.
    private void CheckNesting(List<StructElement> elements, Func<StructElement, string> type)
    {
        foreach (var element in elements)
        {
            cancel.ThrowIfCancellationRequested();
            string t = type(element);
            string parent = element.Parent is { } p ? type(p) : "";
            bool table = t is "THead" or "TBody" or "TFoot" or "TR" or "TH" or "TD" or "Table";
            bool list = t is "L" or "LI" or "Lbl" or "LBody";
            if (!table && !list) continue;
            string checkpoint = table ? "09-004" : "09-005", clause = "7.2";

            bool placed = t switch
            {
                "THead" or "TBody" or "TFoot" => parent == "Table",
                "TR" => parent == "Table" || TableParts.Contains(parent),
                "TH" or "TD" => parent == "TR",
                "LI" => parent == "L",
                "Lbl" or "LBody" => parent == "LI",
                _ => true,
            };
            if (!placed) Add(checkpoint, clause, Place(element), element.Parent is null ? PdfUaText.MisnestedTop(t) : PdfUaText.Misnested(t, parent));

            string[]? allowed = t switch
            {
                "Table" => ["Caption", "TR", "THead", "TBody", "TFoot"],
                "THead" or "TBody" or "TFoot" => ["TR"],
                "TR" => ["TH", "TD"],
                "L" => ["LI", "Caption"],
                "LI" => ["Lbl", "LBody"],
                _ => null,
            };
            if (allowed is null) continue;
            foreach (var child in element.Children)
            {
                string c = type(child);
                if (!allowed.Contains(c) && !Placed.Contains(c)) Add(checkpoint, clause, Place(child), PdfUaText.Misnested(c, t));
            }
        }
    }

    // 7.4: H1 comes first, a level is not skipped going down, and H is not mixed with numbered headings.
    private void CheckHeadings(List<StructElement> elements, Func<StructElement, string> type)
    {
        int previous = 0;
        bool plain = false, numbered = false;
        foreach (var element in elements)
        {
            string t = type(element);
            if (t == "H") plain = true;
            if (t.Length < 2 || t[0] != 'H' || !int.TryParse(t.AsSpan(1), out int level)) continue;
            numbered = true;
            if (previous == 0 && level != 1) Add("14-002", "7.4.2", Place(element), PdfUaText.FirstHeading(level));
            else if (level > previous + 1) Add("14-003", "7.4.2", Place(element), PdfUaText.HeadingSkipped(level, previous));
            previous = level;
        }
        if (plain && numbered) Add("14-007", "7.4.4", PdfAText.Catalog, PdfUaText.HeadingMixed);
    }
}
