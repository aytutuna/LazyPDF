import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Accessibility/TagLabels.cs.

/// How an element of the tag tree reads in the tree view.
public enum TagLabels {
    public static func of(_ element: StructElement, _ tree: StructureTree) -> String {
        let standard = tree.standardType(element.type)
        var name = standard == element.type || standard.isEmpty ? element.type : element.type + " (" + standard + ")"
        if name.isEmpty { name = L10n.t("Untitled tag") }
        let text = note(element)
        let page = FigureFinder.pageOf(element)
        let at = page >= 0 ? L10n.t(", page {0}", page + 1) : ""
        return text.isEmpty ? name + at : name + at + ": " + text
    }

    private static func note(_ element: StructElement) -> String {
        for text in [element.alt, element.actualText, element.title] {
            guard let text else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed.count > 60 ? String(trimmed.prefix(60)) + "..." : trimmed }
        }
        return ""
    }
}

/// The lines of the reading order, and what a voice should say for each.
public enum ReadingLines {
    public static func of(_ order: String) -> [String] {
        order.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// The line without the marks that only show structure: heading hashes, figure brackets, tabs between cells.
    public static func spoken(_ line: String) -> String {
        var text = String(line.drop { $0 == "#" }).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count >= 2, text.hasPrefix("["), text.hasSuffix("]") { text = String(text.dropFirst().dropLast()) }
        return text.replacingOccurrences(of: "\t", with: ",")
    }
}

/// One element of the tag tree as the tree view lists it. Children are made when the row is first asked for them, so a large
/// tree costs only what is looked at; past `shown` of them the rest are one disabled row that says how many.
public final class TagNode: Identifiable {
    static let shown = 200

    public let id = UUID()
    public let element: StructElement?
    private let tree: StructureTree
    private let text: String?

    init(_ element: StructElement, _ tree: StructureTree) {
        self.element = element
        self.tree = tree
        text = nil
    }

    init(more count: Int, _ tree: StructureTree) {
        element = nil
        self.tree = tree
        text = L10n.t("{0} more", count)
    }

    public private(set) lazy var label: String = text ?? TagLabels.of(element!, tree)

    public private(set) lazy var children: [TagNode]? = makeChildren()

    private func makeChildren() -> [TagNode]? {
        guard let element else { return nil }
        let kids = element.children
        if kids.isEmpty { return nil }
        var nodes = kids.prefix(Self.shown).map { TagNode($0, tree) }
        if kids.count > Self.shown { nodes.append(TagNode(more: kids.count - Self.shown, tree)) }
        return nodes
    }

    public var isMore: Bool { element == nil }

    public static func roots(_ tree: StructureTree) -> [TagNode] {
        tree.roots.prefix(shown).map { TagNode($0, tree) }
    }
}
