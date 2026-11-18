import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Accessibility/TagEdits.cs (TagPath): where a node of the tag tree is, as the steps from the
// roots, and what it was. The tree on the screen is read from a copy, so a command finds its node again in the open
// document's own tree and only goes on when the same node is there.

struct TagPath: Equatable {
    let steps: [Int]
    let key: String

    static func of(_ tree: StructureTree, _ kid: StructKid) -> TagPath {
        var steps: [Int] = []
        var at: StructKid? = kid
        while let node = at {
            steps.append(indexOf(siblings(tree, node), node))
            at = node.parent
        }
        return TagPath(steps: steps.reversed(), key: keyOf(kid))
    }

    /// What names a node across reads of the file: the object of an element, the page and number of marked content.
    static func keyOf(_ kid: StructKid) -> String {
        switch kid {
        case let element as StructElement:
            return element.reference.map { "E\($0.number)" } ?? "T" + element.type
        case let content as StructContent:
            return "C\(content.pageIndex).\(content.mcid)." + (content.stream.map { String($0.number) } ?? "")
        case let object as StructObject:
            return "O\(object.target.number)"
        default:
            return ""
        }
    }

    func find(_ tree: StructureTree) -> StructKid? {
        var kid: StructKid?
        for step in steps {
            var list: [StructKid]
            if let parent = kid {
                guard let element = parent as? StructElement else { return nil }
                list = element.kids
            } else {
                list = tree.roots
            }
            if step < 0 || step >= list.count { return nil }
            kid = list[step]
        }
        guard let found = kid, Self.keyOf(found) == key else { return nil }
        return found
    }

    static func siblings(_ tree: StructureTree, _ kid: StructKid) -> [StructKid] {
        if let parent = kid.parent { return parent.kids }
        return tree.roots
    }

    static func indexOf(_ list: [StructKid], _ kid: StructKid) -> Int {
        list.firstIndex { $0 === kid } ?? -1
    }
}
