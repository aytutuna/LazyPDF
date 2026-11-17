import Foundation

// Twin of windows/LazyPDF.Core/Accessibility/TagRules.cs: where one structure type may sit under another (ISO 32000-1
// 14.8.4, ISO 14289-1 7.4 to 7.6), on standard types: use `StructureTree.standardType` first. A rule answers nil when the
// placement is fine, otherwise a short key that `AccessibilityText.placementReason` turns into a message. The parent is ""
// for the root of the tree.

public enum TagRules {
    public static let rootOnly = "root-only"
    public static let topLevel = "top-level"
    public static let needsTable = "needs-table"
    public static let needsTableOrPart = "needs-table-or-part"
    public static let needsRow = "needs-row"
    public static let needsList = "needs-list"
    public static let needsItem = "needs-item"
    public static let needsCaptionParent = "needs-caption-parent"
    public static let needsToc = "needs-toc"
    public static let needsRuby = "needs-ruby"
    public static let needsWarichu = "needs-warichu"
    public static let tableKids = "table-kids"
    public static let partKids = "part-kids"
    public static let rowKids = "row-kids"
    public static let listKids = "list-kids"
    public static let itemKids = "item-kids"
    public static let tocKids = "toc-kids"
    public static let rubyKids = "ruby-kids"
    public static let warichuKids = "warichu-kids"
    public static let textKids = "text-kids"
    public static let noContent = "no-content"
    public static let linkObject = "link-object"
    public static let unmapped = "unmapped"

    private static let inline: Set<String> = [
        "Span", "Quote", "Note", "Reference", "BibEntry", "Code", "Link", "Annot", "Ruby", "Warichu", "Figure", "Formula", "Form",
    ]

    private static let noContentTypes: Set<String> = ["Table", "THead", "TBody", "TFoot", "TR", "L", "LI", "TOC", "Ruby", "Warichu"]

    /// Whether `child` may be a kid of `parent`; nil or the reason it may not.
    public static func canPlace(_ parent: String, _ child: String) -> String? {
        parentRule(parent, child) ?? kidRule(parent, child)
    }

    /// The same for elements of a tree, whose types are resolved through the role map. A nil parent is the root.
    public static func canPlace(_ tree: StructureTree, _ parent: StructElement?, _ child: StructElement) -> String? {
        canPlace(parent.map { tree.standardType($0.type) } ?? "", tree.standardType(child.type))
    }

    /// Whether `element` may take `type`: it must fit its parent, its element kids must fit under it, a type that holds only
    /// elements cannot hold marked content, and a Link needs an object reference. `mapsTo` is the standard type a new custom
    /// type stands for, when the role map has no entry for it.
    public static func canSetType(_ tree: StructureTree, _ element: StructElement, _ type: String, _ mapsTo: String? = nil) -> String? {
        guard let resolved = tree.resolveNew(element, type, mapsTo) else { return unmapped }
        if let reason = canPlace(element.parent.map { tree.standardType($0.type) } ?? "", resolved) { return reason }
        for kid in element.kids {
            if let child = kid as? StructElement {
                if let why = canPlace(resolved, tree.standardType(child.type)) { return why }
            } else if noContentTypes.contains(resolved) {
                return noContent
            }
        }
        return resolved == "Link" && !element.kids.contains(where: { $0 is StructObject }) ? linkObject : nil
    }

    /// True for the types whose own parent is checked (cells, rows, table sections, list parts).
    public static func checksOwnParent(_ type: String) -> Bool {
        ["THead", "TBody", "TFoot", "TR", "TH", "TD", "LI", "Lbl", "LBody"].contains(type)
    }

    /// True for the types that hold only the kids they name (tables, their sections and rows, lists and items).
    public static func hasFixedKids(_ type: String) -> Bool {
        ["Table", "THead", "TBody", "TFoot", "TR", "L", "LI"].contains(type)
    }

    /// The rule seen from the child: which parents a type needs.
    public static func parentRule(_ parent: String, _ child: String) -> String? {
        switch child {
        case "THead", "TBody", "TFoot": return parent == "Table" ? nil : needsTable
        case "TR": return ["Table", "THead", "TBody", "TFoot"].contains(parent) ? nil : needsTableOrPart
        case "TH", "TD": return parent == "TR" ? nil : needsRow
        case "LI": return parent == "L" ? nil : needsList
        case "Lbl", "LBody": return parent == "LI" ? nil : needsItem
        case "Caption": return ["Table", "L", "Figure", "Formula"].contains(parent) ? nil : needsCaptionParent
        case "TOCI": return parent == "TOC" ? nil : needsToc
        case "RB", "RT", "RP": return parent == "Ruby" ? nil : needsRuby
        case "WT", "WP": return parent == "Warichu" ? nil : needsWarichu
        case "Document": return parent.isEmpty ? nil : rootOnly
        case "Part", "Art": return ["", "Document", "Part", "Art"].contains(parent) ? nil : topLevel
        default: return nil
        }
    }

    /// The rule seen from the parent: which kids a type holds.
    public static func kidRule(_ parent: String, _ child: String) -> String? {
        switch parent {
        case "Table": return ["Caption", "TR", "THead", "TBody", "TFoot"].contains(child) ? nil : tableKids
        case "THead", "TBody", "TFoot": return child == "TR" ? nil : partKids
        case "TR": return child == "TH" || child == "TD" ? nil : rowKids
        case "L": return child == "LI" || child == "Caption" ? nil : listKids
        case "LI": return child == "Lbl" || child == "LBody" ? nil : itemKids
        case "TOC": return ["TOCI", "TOC", "Caption"].contains(child) ? nil : tocKids
        case "Ruby": return ["RB", "RT", "RP"].contains(child) ? nil : rubyKids
        case "Warichu": return child == "WT" || child == "WP" ? nil : warichuKids
        case "Figure": return child == "Caption" || child == "P" || inline.contains(child) ? nil : textKids
        case "P", "H", "Lbl", "RB", "RT", "RP", "WT", "WP", "Span", "Quote", "Reference", "BibEntry", "Code", "Link", "Annot", "Form":
            return inline.contains(child) ? nil : textKids
        default:
            return isHeading(parent) && !inline.contains(child) ? textKids : nil
        }
    }

    private static func isHeading(_ type: String) -> Bool {
        type.utf16.count >= 2 && type.utf16.first == 0x48 && StructureTree.isStandard(type)
    }
}
