namespace LazyPDF.Core;

/// <summary>
/// Where one structure type may sit under another (ISO 32000-1 14.8.4, ISO 14289-1 7.4 to 7.6), on standard
/// types: use <see cref="StructureTree.StandardType"/> first. A rule answers null when the placement is fine,
/// otherwise a short key that <see cref="AccessibilityText.PlacementReason"/> turns into a message. The
/// parent is "" for the root of the tree.
/// </summary>
public static class TagRules
{
    public const string RootOnly = "root-only";
    public const string TopLevel = "top-level";
    public const string NeedsTable = "needs-table";
    public const string NeedsTableOrPart = "needs-table-or-part";
    public const string NeedsRow = "needs-row";
    public const string NeedsList = "needs-list";
    public const string NeedsItem = "needs-item";
    public const string NeedsCaptionParent = "needs-caption-parent";
    public const string NeedsToc = "needs-toc";
    public const string NeedsRuby = "needs-ruby";
    public const string NeedsWarichu = "needs-warichu";
    public const string TableKids = "table-kids";
    public const string PartKids = "part-kids";
    public const string RowKids = "row-kids";
    public const string ListKids = "list-kids";
    public const string ItemKids = "item-kids";
    public const string TocKids = "toc-kids";
    public const string RubyKids = "ruby-kids";
    public const string WarichuKids = "warichu-kids";
    public const string TextKids = "text-kids";
    public const string NoContent = "no-content";
    public const string LinkObject = "link-object";
    public const string Unmapped = "unmapped";

    private static readonly HashSet<string> Inline = new(StringComparer.Ordinal)
    {
        "Span", "Quote", "Note", "Reference", "BibEntry", "Code", "Link", "Annot", "Ruby", "Warichu", "Figure", "Formula", "Form",
    };

    private static readonly HashSet<string> NoContentTypes = new(StringComparer.Ordinal)
    {
        "Table", "THead", "TBody", "TFoot", "TR", "L", "LI", "TOC", "Ruby", "Warichu",
    };

    /// <summary>Whether <paramref name="child" /> may be a kid of <paramref name="parent" />; null or the reason it may not.</summary>
    public static string? CanPlace(string parent, string child) => ParentRule(parent, child) ?? KidRule(parent, child);

    /// <summary>The same for elements of a tree, whose types are resolved through the role map. A null parent is the root.</summary>
    public static string? CanPlace(StructureTree tree, StructElement? parent, StructElement child) =>
        CanPlace(parent is null ? "" : tree.StandardType(parent.Type), tree.StandardType(child.Type));

    /// <summary>
    /// Whether <paramref name="element" /> may take <paramref name="type" />: it must fit its parent, its element kids
    /// must fit under it, a type that holds only elements cannot hold marked content, and a Link needs an object
    /// reference. <paramref name="mapsTo" /> is the standard type a new custom type stands for, when the role map has no entry for it.
    /// </summary>
    public static string? CanSetType(StructureTree tree, StructElement element, string type, string? mapsTo = null)
    {
        string? resolved = tree.ResolveNew(element, type, mapsTo);
        if (resolved is null) return Unmapped;
        if (CanPlace(element.Parent is null ? "" : tree.StandardType(element.Parent.Type), resolved) is { } reason) return reason;
        foreach (var kid in element.Kids)
        {
            if (kid is StructElement child)
            {
                if (CanPlace(resolved, tree.StandardType(child.Type)) is { } why) return why;
            }
            else if (NoContentTypes.Contains(resolved))
            {
                return NoContent;
            }
        }
        return resolved == "Link" && !element.Kids.Any(k => k is StructObject) ? LinkObject : null;
    }

    /// <summary>True for the types whose own parent is checked (cells, rows, table sections, list parts).</summary>
    public static bool ChecksOwnParent(string type) =>
        type is "THead" or "TBody" or "TFoot" or "TR" or "TH" or "TD" or "LI" or "Lbl" or "LBody";

    /// <summary>True for the types that hold only the kids they name (tables, their sections and rows, lists and items).</summary>
    public static bool HasFixedKids(string type) => type is "Table" or "THead" or "TBody" or "TFoot" or "TR" or "L" or "LI";

    /// <summary>The rule seen from the child: which parents a type needs.</summary>
    public static string? ParentRule(string parent, string child) => child switch
    {
        "THead" or "TBody" or "TFoot" => parent == "Table" ? null : NeedsTable,
        "TR" => parent is "Table" or "THead" or "TBody" or "TFoot" ? null : NeedsTableOrPart,
        "TH" or "TD" => parent == "TR" ? null : NeedsRow,
        "LI" => parent == "L" ? null : NeedsList,
        "Lbl" or "LBody" => parent == "LI" ? null : NeedsItem,
        "Caption" => parent is "Table" or "L" or "Figure" or "Formula" ? null : NeedsCaptionParent,
        "TOCI" => parent == "TOC" ? null : NeedsToc,
        "RB" or "RT" or "RP" => parent == "Ruby" ? null : NeedsRuby,
        "WT" or "WP" => parent == "Warichu" ? null : NeedsWarichu,
        "Document" => parent.Length == 0 ? null : RootOnly,
        "Part" or "Art" => parent is "" or "Document" or "Part" or "Art" ? null : TopLevel,
        _ => null,
    };

    /// <summary>The rule seen from the parent: which kids a type holds.</summary>
    public static string? KidRule(string parent, string child)
    {
        switch (parent)
        {
            case "Table": return child is "Caption" or "TR" or "THead" or "TBody" or "TFoot" ? null : TableKids;
            case "THead" or "TBody" or "TFoot": return child == "TR" ? null : PartKids;
            case "TR": return child is "TH" or "TD" ? null : RowKids;
            case "L": return child is "LI" or "Caption" ? null : ListKids;
            case "LI": return child is "Lbl" or "LBody" ? null : ItemKids;
            case "TOC": return child is "TOCI" or "TOC" or "Caption" ? null : TocKids;
            case "Ruby": return child is "RB" or "RT" or "RP" ? null : RubyKids;
            case "Warichu": return child is "WT" or "WP" ? null : WarichuKids;
            case "Figure": return child is "Caption" or "P" || Inline.Contains(child) ? null : TextKids;
            case "P" or "H" or "Lbl" or "RB" or "RT" or "RP" or "WT" or "WP":
            case "Span" or "Quote" or "Reference" or "BibEntry" or "Code" or "Link" or "Annot" or "Form":
                return Inline.Contains(child) ? null : TextKids;
            default:
                return IsHeading(parent) ? (Inline.Contains(child) ? null : TextKids) : null;
        }
    }

    private static bool IsHeading(string type) => type.Length >= 2 && type[0] == 'H' && StructureTree.IsStandard(type);
}
