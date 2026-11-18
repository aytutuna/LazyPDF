import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Accessibility/TagEdits.cs: what the tag tree editor changes in a document, kept apart
// from the views.

public enum TagCommand: CaseIterable {
    case moveUp, moveDown, indent, outdent, delete, deleteAsArtifact, markAsArtifact, makeHeaderRow
}

extension TagCommand {
    /// The words on the button of the command.
    public var text: String { TagEdits.buttonText(self) }
}

public enum DropZone {
    case before, into, after
}

enum TagResult {
    case done, unchanged, refused, gone, failed
}

struct TagOutcome {
    let result: TagResult
    var reason: String?

    init(_ result: TagResult, _ reason: String? = nil) {
        self.result = result
        self.reason = reason
    }
}

/// The fields of the element editor.
struct TagProperties: Equatable {
    var type: String
    var title: String
    var alt: String
    var actualText: String
    var lang: String
    var table: TableAttributes?
}

enum TagEdits {
    private static let common = [
        "Document", "Part", "Art", "Sect", "Div", "BlockQuote", "H", "H1", "H2", "H3", "H4", "H5", "H6", "P", "L", "LI", "Lbl", "LBody",
        "Table", "THead", "TBody", "TFoot", "TR", "TH", "TD", "Caption", "Figure", "Formula", "Span", "Link", "Note", "Quote", "Code",
        "Reference", "BibEntry", "TOC", "TOCI", "Index", "Form", "NonStruct", "Private",
    ]

    /// The types the editor offers: the standard ones, then the types of the file's role map.
    static func types(_ tree: StructureTree) -> [String] {
        let mapped = tree.roleMap.entries.map(\.key).filter { !common.contains($0) }
        return common + mapped.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }

    /// Why nothing may be changed in the tags of this file; nil when it may.
    @MainActor
    static func readOnlyReason(_ document: PdfDocument, _ tree: StructureTree?) -> String? {
        if document.isEncrypted { return L10n.t("The file is encrypted, so its tags cannot be changed here.") }
        if let problem = ChangeGate.refusal(document) { return problem.text }
        if let tree, tree.isTruncated { return L10n.t("The tree is too large to edit, so it is read-only.") }
        return nil
    }

    /// The name of the undo step.
    static func label(_ command: TagCommand) -> String {
        switch command {
        case .moveUp: return L10n.t("Move tag up")
        case .moveDown: return L10n.t("Move tag down")
        case .indent: return L10n.t("Indent tag")
        case .outdent: return L10n.t("Outdent tag")
        case .delete: return L10n.t("Delete tag")
        case .deleteAsArtifact: return L10n.t("Delete tag as artifact")
        case .markAsArtifact: return L10n.t("Mark as artifact")
        case .makeHeaderRow: return L10n.t("Make header row")
        }
    }

    /// The words on the button of the command.
    static func buttonText(_ command: TagCommand) -> String {
        switch command {
        case .moveUp: return L10n.t("Move up")
        case .moveDown: return L10n.t("Move down")
        case .indent: return L10n.t("Indent")
        case .outdent: return L10n.t("Outdent")
        case .delete: return L10n.t("Delete")
        case .deleteAsArtifact: return L10n.t("Delete as artifact")
        case .markAsArtifact: return L10n.t("Mark as artifact")
        case .makeHeaderRow: return L10n.t("Make header row")
        }
    }

    /// Whether the command means anything for the node where it stands; false greys its button.
    static func applies(_ tree: StructureTree, _ kid: StructKid, _ command: TagCommand) -> Bool {
        let siblings = TagPath.siblings(tree, kid)
        let at = TagPath.indexOf(siblings, kid)
        if at < 0 { return false }
        switch command {
        case .moveUp: return at > 0
        case .moveDown: return at < siblings.count - 1
        case .indent: return kid is StructElement && at > 0 && siblings[at - 1] is StructElement
        case .outdent: return kid is StructElement && kid.parent != nil
        case .delete, .deleteAsArtifact: return kid is StructElement
        case .markAsArtifact: return kid is StructContent
        case .makeHeaderRow:
            guard let row = kid as? StructElement else { return false }
            return tree.standardType(row.type) == "TR"
        }
    }

    /// Why the command would break the structure; nil when it fits. Moves inside one parent never do.
    static func refusal(_ tree: StructureTree, _ kid: StructKid, _ command: TagCommand) -> String? {
        let siblings = TagPath.siblings(tree, kid)
        let at = TagPath.indexOf(siblings, kid)
        switch command {
        case .indent:
            guard at > 0, let previous = siblings[at - 1] as? StructElement else { return nil }
            return placeRefusal(tree, kid, previous)
        case .outdent:
            guard let parent = kid.parent else { return nil }
            return placeRefusal(tree, kid, parent.parent)
        case .delete:
            guard let element = kid as? StructElement else { return nil }
            for inner in element.kids {
                if let reason = placeRefusal(tree, inner, element.parent) { return reason }
            }
            return nil
        default:
            return nil
        }
    }

    /// Why `kid` may not sit under `parent` (nil: the top of the tree); nil when it may.
    static func placeRefusal(_ tree: StructureTree, _ kid: StructKid, _ parent: StructElement?) -> String? {
        var up = parent
        while let p = up {
            if p === kid { return L10n.t("An element cannot go into itself.") }
            up = p.parent
        }
        if let element = kid as? StructElement { return reason(TagRules.canPlace(tree, parent, element)) }
        guard let parent else { return L10n.t("Only an element can sit at the root.") }
        return TagRules.hasFixedKids(tree.standardType(parent.type)) ? reason(TagRules.noContent) : nil
    }

    /// Why `element` may not take `type`; nil when it may.
    static func typeRefusal(_ tree: StructureTree, _ element: StructElement, _ type: String) -> String? {
        let name = type.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? L10n.t("The type is empty.") : reason(TagRules.canSetType(tree, element, name))
    }

    private static func reason(_ key: String?) -> String? {
        key.map { AccessibilityText.placementReason($0) }
    }

    /// Runs one edit on the open document's own tree as a single undo step: reads the tree again, finds the node `path`
    /// names (none when it is nil), lets `edit` change it, writes the tree and commits. An edit answers nil or the reason it
    /// was refused, and a refusal changes nothing.
    @MainActor
    static func apply(_ tab: DocumentTab, _ path: TagPath?, _ label: String, _ edit: (StructureTree, StructKid?) throws -> String?) -> TagOutcome {
        let document = tab.document
        do {
            guard let tree = StructureTree.read(document) else { return TagOutcome(.gone) }
            if let why = readOnlyReason(document, tree) { return TagOutcome(.refused, why) }
            var kid: StructKid?
            if let path {
                kid = path.find(tree)
                if kid == nil { return TagOutcome(.gone) }
            }
            if let reason = try edit(tree, kid) {
                try? tab.session.discard()
                return TagOutcome(.refused, reason)
            }
            try tree.write(document)
            return TagOutcome(try tab.commit(label) ? .done : .unchanged)
        } catch {
            try? tab.session.discard()
            return TagOutcome(.failed)
        }
    }

    static func run(_ tree: StructureTree, _ kid: StructKid, _ command: TagCommand) throws -> String? {
        if !applies(tree, kid, command) { return L10n.t("That cannot be done to this tag.") }
        if let reason = refusal(tree, kid, command) { return reason }
        let done: Bool
        switch command {
        case .moveUp: done = tree.moveUp(kid)
        case .moveDown: done = tree.moveDown(kid)
        case .indent: done = try tree.indent(kid as! StructElement)
        case .outdent: done = try tree.outdent(kid as! StructElement)
        case .delete: done = tree.unwrap(kid as! StructElement)
        case .makeHeaderRow: done = tree.makeHeaderRow(kid as! StructElement) > 0
        case .deleteAsArtifact, .markAsArtifact:
            return tree.markAsArtifact(kid).map { AccessibilityText.contentReason($0) }
        }
        return done ? nil : L10n.t("That cannot be done to this tag.")
    }

    /// The place a drop on `target` gives `kid`; the index counts after the kid left its old place.
    static func dropAt(_ tree: StructureTree, _ kid: StructKid, _ target: StructKid, _ zone: DropZone) -> (parent: StructElement?, index: Int) {
        if zone == .into, let into = target as? StructElement { return (into, -1) }
        let siblings = TagPath.siblings(tree, target).filter { $0 !== kid }
        let at = siblings.firstIndex { $0 === target } ?? -1
        return (target.parent, zone == .before ? at : at + 1)
    }

    /// Why a drop would break the structure, or nil; `apply` moves the node when it would not.
    static func drop(_ tree: StructureTree, _ kid: StructKid, _ target: StructKid, _ zone: DropZone, apply: Bool) throws -> String? {
        if kid === target { return L10n.t("That cannot be done to this tag.") }
        let place = dropAt(tree, kid, target, zone)
        if let reason = placeRefusal(tree, kid, place.parent) { return reason }
        if apply { try tree.move(kid, place.parent, place.index) }
        return nil
    }

    static func setProperties(_ tree: StructureTree, _ element: StructElement, _ p: TagProperties) -> String? {
        let type = p.type.trimmingCharacters(in: .whitespacesAndNewlines)
        let lang = p.lang.trimmingCharacters(in: .whitespacesAndNewlines)
        if !lang.isEmpty && !AccessibilityChecker.isLanguageTag(lang) { return L10n.t("Write the language as a tag such as en-US or tr-TR.") }
        if type != element.type {
            if let reason = typeRefusal(tree, element, type) { return reason }
            tree.setType(element, type)
        }
        element.title = text(p.title.trimmingCharacters(in: .whitespacesAndNewlines))
        element.alt = text(p.alt.trimmingCharacters(in: .whitespacesAndNewlines))
        element.actualText = text(p.actualText)
        element.lang = text(lang)
        if let table = p.table, ["TH", "TD"].contains(tree.standardType(element.type)), !showsAlready(tree.tableAttributes(element), table) {
            tree.setTableAttributes(element, table)
        }
        return nil
    }

    // The editor shows the header IDs as one text, so IDs with a comma in them come back split; a cell whose fields still show what it has is left as it is.
    private static func showsAlready(_ current: TableAttributes, _ fields: TableAttributes) -> Bool {
        current.scope == fields.scope && current.rowSpan == fields.rowSpan && current.colSpan == fields.colSpan
            && ids(current.headers.joined(separator: ", ")) == fields.headers
    }

    private static func ids(_ headers: String) -> [String] {
        headers.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private static func text(_ value: String) -> String? { value.isEmpty ? nil : value }

    /// The table attributes the editor's four fields stand for; nil with the reason when a span is not a whole number from 1.
    static func tableOf(scope: String, rowSpan: String, colSpan: String, headers: String) -> (attributes: TableAttributes?, problem: String?) {
        var bad: String?
        func span(_ value: String) -> Int? {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return nil }
            if let n = Int(trimmed), n >= 1 { return n }
            bad = L10n.t("A span is a whole number from 1.")
            return nil
        }
        let rows = span(rowSpan)
        let columns = span(colSpan)
        if bad != nil { return (nil, bad) }
        return (TableAttributes(scope: TableScope(rawValue: scope), headers: ids(headers), rowSpan: rows, colSpan: columns), nil)
    }

    /// The element the new tag goes under: the node itself, or the element holding it.
    private static func parentFor(_ kid: StructKid?) -> StructElement? {
        kid as? StructElement ?? kid?.parent
    }

    static func tagSelection(_ tree: StructureTree, _ kid: StructKid?, _ type: String, _ runs: [SelectedRun]) throws -> String? {
        if runs.isEmpty { return AccessibilityText.contentReason(TagContent.emptySelection) }
        let name = type.trimmingCharacters(in: .whitespacesAndNewlines)
        for (page, group) in byPage(runs) {
            let result = try tree.tagSelection(page, group.map(\.range), name, parentFor(kid))
            if let key = result.reason { return AccessibilityText.contentReason(key) }
        }
        return nil
    }

    static func tagArea(_ tree: StructureTree, _ kid: StructKid?, _ type: String, _ page: Int, _ area: PdfRect) throws -> String? {
        let name = type.trimmingCharacters(in: .whitespacesAndNewlines)
        return try tree.tagArea(page, area, name, parentFor(kid)).reason.map { AccessibilityText.contentReason($0) }
    }

    /// Marks what the viewer has selected as an artifact: it is tagged as a span at the end of the tree and that span is marked at once.
    static func selectionAsArtifact(_ tree: StructureTree, _ runs: [SelectedRun]) throws -> String? {
        if runs.isEmpty { return AccessibilityText.contentReason(TagContent.emptySelection) }
        for (page, group) in byPage(runs) {
            let result = try tree.tagSelection(page, group.map(\.range), "Span", nil)
            if let key = result.reason { return AccessibilityText.contentReason(key) }
            if let why = tree.markAsArtifact(result.element!) { return AccessibilityText.contentReason(why) }
        }
        return nil
    }

    private static func byPage(_ runs: [SelectedRun]) -> [(Int, [SelectedRun])] {
        Dictionary(grouping: runs, by: \.page).sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }
}
