import Foundation

// Twin of windows/LazyPDF.Core/Standards/PdfAChecker.Structure.cs. Level A: the logical structure (ISO 19005-1 6.8,
// 19005-2 and -3 6.7). Word breaks, which the standard also names, cannot be told from the file. The type names are compared
// as UTF-8, as the C# compares them ordinally.

private func nameSet(_ names: [String]) -> Set<[UInt8]> { Set(names.map { Array($0.utf8) }) }

// The types of PDF 1.4 (part 1); PDF 1.5 added the table sections, Annot and the East Asian types (parts 2 and 3).
private let types14 = nameSet([
    "Document", "Part", "Art", "Sect", "Div", "BlockQuote", "Caption", "TOC", "TOCI", "Index", "NonStruct", "Private",
    "P", "H", "H1", "H2", "H3", "H4", "H5", "H6", "L", "LI", "Lbl", "LBody", "Table", "TR", "TH", "TD",
    "Span", "Quote", "Note", "Reference", "BibEntry", "Code", "Link", "Figure", "Formula", "Form",
])

private let types17 = types14.union(nameSet(["THead", "TBody", "TFoot", "Annot", "Ruby", "RB", "RT", "RP", "Warichu", "WT", "WP"]))

extension PdfAChecker {
    private func addStructure(_ clause: String, _ place: @autoclosure () -> String, _ message: @autoclosure () -> String) {
        let before = issues.count
        add(clause, place(), message())
        if issues.count > before { structureIssues.append(issues[issues.count - 1]) }
    }

    func checkStructure() {
        if !level.needsTags() { return }
        if document.bool(document.dict(document.catalog, "MarkInfo"), "Marked") != true {
            addStructure(c("6.8.2.2", "6.7.2"), PdfAText.catalog, PdfAText.noMarkInfo)
        }
        guard let tree = StructureTree.read(document) else {
            addStructure(c("6.8.3.1", "6.7.2"), PdfAText.catalog, PdfAText.noStructTree)
            return
        }
        if tree.roots.isEmpty { addStructure(c("6.8.3.1", "6.7.2"), PdfAText.catalog, PdfAText.emptyStructTree) }
        if tree.isTruncated {
            addStructure(c("6.8.3.1", "6.7.2"), PdfAText.catalog, PdfAText.structTreeTooBig)
            return
        }

        let typeClause = c("6.8.3.4", "6.7.3.2")
        var seenTypes = Set<[UInt8]>()
        let part1 = isPart1
        for element in tree.elements {
            let type = Self.standardType(tree, element.type, part1)
            let place = element.reference.map { PdfAText.structureElement($0.number) } ?? PdfAText.catalog
            if !Self.isStandardType(type, part1) {
                if seenTypes.insert(Array(element.type.utf8)).inserted { addStructure(typeClause, place, PdfAText.nonStandardType(element.type)) }
            } else if (type == "Figure" || type == "Formula") && DotNetText.isNullOrWhiteSpace(element.alt) && DotNetText.isNullOrWhiteSpace(element.actualText) {
                addStructure(c("6.8.4", "6.7.5"), place, PdfAText.noAlternateText(type))
            }
        }

        let language = !DotNetText.isNullOrWhiteSpace(PdfText.read(document, document.catalog, "Lang"))
            || (!tree.roots.isEmpty && tree.roots.allSatisfy { !DotNetText.isNullOrWhiteSpace($0.lang) })
        if !language { addStructure(c("6.8.5", "6.7.4"), PdfAText.catalog, PdfAText.noLanguage) }

        // Only a cancelled task throws here, and the checker is not given one.
        if let content = try? AccessibilityChecker.taggedContent(document, tree), content.status == .failed {
            let clause = c("6.8.3.3", "6.7.3.1")
            if content.where.isEmpty { addStructure(clause, PdfAText.catalog, PdfAText.contentOutsideTree) }
            for place in content.where { addStructure(clause, PdfAText.pageName(place.pageIndex + 1), PdfAText.contentOutsideTree) }
        }
    }

    private static func isStandardType(_ type: String, _ part1: Bool) -> Bool { (part1 ? types14 : types17).contains(Array(type.utf8)) }

    // The role map followed to a standard type; a cycle or a chain past 16 stops where it is.
    private static func standardType(_ tree: StructureTree, _ type: String, _ part1: Bool) -> String {
        var type = type
        var i = 0
        while i < 16 && !isStandardType(type, part1) {
            guard let next = tree.roleMap[type], next != type else { break }
            type = next
            i += 1
        }
        return type
    }
}
