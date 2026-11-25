import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Accessibility/TagFilter.cs: the elements of the tag tree whose type or text has the words
// typed in the filter box, with everything above them.

struct TagFilter {
    static let limit = 500

    let shown: Set<ObjectIdentifier>
    let matches: Int
    let isCapped: Bool

    static func of(_ tree: StructureTree, _ text: String) -> TagFilter? {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if words.isEmpty { return nil }
        var shown = Set<ObjectIdentifier>()
        var matches = 0
        var capped = false
        for element in tree.elements where hit(tree, element, words) {
            if matches == limit {
                capped = true
                break
            }
            matches += 1
            var up: StructElement? = element
            while let p = up, shown.insert(ObjectIdentifier(p)).inserted { up = p.parent }
        }
        return TagFilter(shown: shown, matches: matches, isCapped: capped)
    }

    func shows(_ element: StructElement) -> Bool {
        shown.contains(ObjectIdentifier(element))
    }

    private static func hit(_ tree: StructureTree, _ element: StructElement, _ words: String) -> Bool {
        has(element.type, words) || has(tree.standardType(element.type), words) || has(element.title, words) || has(element.alt, words)
            || has(element.actualText, words) || has(element.id, words)
    }

    private static func has(_ value: String?, _ words: String) -> Bool {
        value?.range(of: words, options: [.caseInsensitive, .literal]) != nil
    }
}
