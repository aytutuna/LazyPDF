namespace LazyPDF.Core;

// Level A: the logical structure (ISO 19005-1 6.8, 19005-2 and -3 6.7). Word breaks, which the standard also names, cannot
// be told from the file.
internal sealed partial class PdfAChecker
{
    // The types of PDF 1.4 (part 1); PDF 1.5 added the table sections, Annot and the East Asian types (parts 2 and 3).
    private static readonly HashSet<string> Types14 = new(StringComparer.Ordinal)
    {
        "Document", "Part", "Art", "Sect", "Div", "BlockQuote", "Caption", "TOC", "TOCI", "Index", "NonStruct", "Private",
        "P", "H", "H1", "H2", "H3", "H4", "H5", "H6", "L", "LI", "Lbl", "LBody", "Table", "TR", "TH", "TD",
        "Span", "Quote", "Note", "Reference", "BibEntry", "Code", "Link", "Figure", "Formula", "Form",
    };

    private static readonly HashSet<string> Types17 = new(Types14, StringComparer.Ordinal)
    {
        "THead", "TBody", "TFoot", "Annot", "Ruby", "RB", "RT", "RP", "Warichu", "WT", "WP",
    };

    /// <summary>The issues of the level A rules, which the converter turns into a refusal when tagging could not settle them.</summary>
    internal List<PdfAIssue> StructureIssues { get; } = [];

    private readonly HashSet<string> _structureSeen = new(StringComparer.Ordinal);

    private void AddStructure(string clause, string where, string message)
    {
        // Kept even past the report cap, or the converter would not see that tagging cannot settle these.
        if (_structureSeen.Add($"{clause}|{where}|{message}")) StructureIssues.Add(new PdfAIssue(clause, where, message));
        Add(clause, where, message);
    }

    private void CheckStructure()
    {
        if (!level.NeedsTags()) return;
        if (_doc.Bool(_doc.Dict(_doc.Catalog, "MarkInfo"), "Marked") != true) AddStructure(C("6.8.2.2", "6.7.2"), PdfAText.Catalog, PdfAText.NoMarkInfo);
        var tree = StructureTree.Read(_doc);
        if (tree is null)
        {
            AddStructure(C("6.8.3.1", "6.7.2"), PdfAText.Catalog, PdfAText.NoStructTree);
            return;
        }
        if (tree.Roots.Count == 0) AddStructure(C("6.8.3.1", "6.7.2"), PdfAText.Catalog, PdfAText.EmptyStructTree);
        if (tree.IsTruncated)
        {
            AddStructure(C("6.8.3.1", "6.7.2"), PdfAText.Catalog, PdfAText.StructTreeTooBig);
            return;
        }

        string typeClause = C("6.8.3.4", "6.7.3.2");
        var seen = new HashSet<string>();
        bool part1 = IsPart1;
        foreach (var element in tree.Elements)
        {
            string type = StandardType(tree, element.Type, part1);
            string where = element.Reference is { } reference ? PdfAText.StructureElement(reference.Number) : PdfAText.Catalog;
            if (!IsStandardType(type, part1))
            {
                if (seen.Add(element.Type)) AddStructure(typeClause, where, PdfAText.NonStandardType(element.Type));
            }
            else if (type is "Figure" or "Formula" && string.IsNullOrWhiteSpace(element.Alt) && string.IsNullOrWhiteSpace(element.ActualText))
            {
                AddStructure(C("6.8.4", "6.7.5"), where, PdfAText.NoAlternateText(type));
            }
        }

        bool language = !string.IsNullOrWhiteSpace(PdfText.Read(_doc, _doc.Catalog, "Lang"))
            || tree.Roots.Count > 0 && tree.Roots.All(r => !string.IsNullOrWhiteSpace(r.Lang));
        if (!language) AddStructure(C("6.8.5", "6.7.4"), PdfAText.Catalog, PdfAText.NoLanguage);

        CheckParentTree(tree);

        // Reading the content again is not charged to the budget, so it is left undone once the budget is gone.
        if (OverBudget)
        {
            AddStructure(C("6.8.3.3", "6.7.3.1"), PdfAText.Catalog, PdfAText.TooMuchContent);
            return;
        }
        var content = AccessibilityChecker.TaggedContent(_doc, tree);
        if (content.Status == AccessibilityStatus.Failed)
        {
            string clause = C("6.8.3.3", "6.7.3.1");
            if (content.Where.Count == 0) AddStructure(clause, PdfAText.Catalog, PdfAText.ContentOutsideTree);
            foreach (var place in content.Where) AddStructure(clause, PdfAText.PageName(place.PageIndex + 1), PdfAText.ContentOutsideTree);
        }
    }

    // 14.7.4.4 of ISO 32000-1: a page whose content the tree holds names its key in /StructParents, and the parent tree leads
    // each sequence back to the element that holds it. Content of forms is not followed.
    private void CheckParentTree(StructureTree tree)
    {
        string clause = C("6.8.3.1", "6.7.2");
        foreach (var group in tree.Contents.Where(c => c.Stream is null).GroupBy(c => c.PageIndex))
        {
            if (group.Key < 0 || group.Key >= _doc.Pages.Count) continue;
            string where = PdfAText.PageName(group.Key + 1);
            if (_doc.Integer(_doc.Pages[group.Key].Dictionary, "StructParents") is not { } key)
            {
                AddStructure(clause, where, PdfAText.NoStructParents);
            }
            else if (group.Any(c => !ReferenceEquals(tree.ElementFor(key, c.Mcid), c.Parent)))
            {
                AddStructure(clause, where, PdfAText.ParentTreeMismatch);
            }
        }
    }

    private static bool IsStandardType(string type, bool part1) => (part1 ? Types14 : Types17).Contains(type);

    // The role map followed to a standard type; a cycle or a chain past 16 stops where it is.
    private static string StandardType(StructureTree tree, string type, bool part1)
    {
        for (int i = 0; i < 16 && !IsStandardType(type, part1); i++)
        {
            if (!tree.RoleMap.TryGetValue(type, out var next) || next == type) break;
            type = next;
        }
        return type;
    }
}
