import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Accessibility/TagRulesTests.cs: the same cases.

final class TagRulesTests: XCTestCase {
    func test_placesTypes() {
        let cases: [(String, String, String?)] = [
            ("", "Document", nil),
            ("Div", "Document", TagRules.rootOnly),
            ("Document", "Part", nil),
            ("Part", "Art", nil),
            ("Sect", "Part", TagRules.topLevel),
            ("Document", "Sect", nil),
            ("Sect", "H1", nil),
            ("Div", "H", nil),
            ("Div", "P", nil),
            ("P", "Span", nil),
            ("P", "Link", nil),
            ("P", "Figure", nil),
            ("P", "P", TagRules.textKids),
            ("H2", "P", TagRules.textKids),
            ("H2", "Span", nil),
            ("Span", "Table", TagRules.textKids),
            ("Link", "Span", nil),
            ("Link", "L", TagRules.textKids),
            ("Figure", "Caption", nil),
            ("Figure", "P", nil),
            ("Figure", "TD", TagRules.needsRow),
            ("Div", "Caption", TagRules.needsCaptionParent),
            ("Table", "Caption", nil),
            ("L", "Caption", nil),
            ("Table", "TR", nil),
            ("Table", "THead", nil),
            ("Table", "P", TagRules.tableKids),
            ("Table", "TD", TagRules.needsRow),
            ("THead", "TR", nil),
            ("TBody", "TH", TagRules.needsRow),
            ("TFoot", "TR", nil),
            ("Div", "TR", TagRules.needsTableOrPart),
            ("", "TR", TagRules.needsTableOrPart),
            ("Div", "THead", TagRules.needsTable),
            ("TR", "TH", nil),
            ("TR", "TD", nil),
            ("TR", "P", TagRules.rowKids),
            ("TD", "P", nil),
            ("TD", "L", nil),
            ("TD", "Table", nil),
            ("TH", "Span", nil),
            ("TD", "TD", TagRules.needsRow),
            ("L", "LI", nil),
            ("L", "P", TagRules.listKids),
            ("Div", "LI", TagRules.needsList),
            ("LI", "Lbl", nil),
            ("LI", "LBody", nil),
            ("LI", "P", TagRules.itemKids),
            ("L", "Lbl", TagRules.needsItem),
            ("Lbl", "Span", nil),
            ("Lbl", "P", TagRules.textKids),
            ("LBody", "P", nil),
            ("LBody", "L", nil),
            ("TOC", "TOCI", nil),
            ("TOC", "TOC", nil),
            ("TOC", "P", TagRules.tocKids),
            ("Div", "TOCI", TagRules.needsToc),
            ("TOCI", "Lbl", nil),
            ("TOCI", "LBody", TagRules.needsItem),
            ("TOC", "Caption", nil),
            ("P", "NonStruct", nil),
            ("H2", "Private", nil),
            ("TOCI", "Link", nil),
            ("Ruby", "RB", nil),
            ("Ruby", "Span", TagRules.rubyKids),
            ("Div", "RT", TagRules.needsRuby),
            ("Warichu", "WT", nil),
            ("Warichu", "RT", TagRules.needsRuby),
            ("Warichu", "Span", TagRules.warichuKids),
            ("Div", "WP", TagRules.needsWarichu),
        ]
        for (parent, child, reason) in cases {
            XCTAssertEqual(TagRules.canPlace(parent, child), reason, "\(parent) > \(child)")
        }
    }

    func test_headingsOfAnyLevelAreTextParents() {
        XCTAssertNil(TagRules.canPlace("H3", "Span"))
        XCTAssertEqual(TagRules.canPlace("H6", "Div"), TagRules.textKids)
        XCTAssertNil(TagRules.canPlace("Sect", "H4"))
    }

    func test_typesResolveThroughTheRoleMap() throws {
        let document = try TaggedFile.open()
        let tree = try XCTUnwrap(StructureTree.read(document))
        tree.roleMap["Row"] = "TR"
        tree.roleMap["Loop"] = "Loop2"
        tree.roleMap["Loop2"] = "Loop"
        let table = StructElement("Table")
        let row = StructElement("Row")
        let root = tree.roots[0]

        XCTAssertNil(TagRules.canPlace(tree, table, row))
        XCTAssertEqual(TagRules.canPlace(tree, root, row), TagRules.needsTableOrPart)
        XCTAssertNil(TagRules.canPlace(tree, root, StructElement("Loop")))
        XCTAssertEqual(TagRules.canPlace(tree, root, StructElement("Document")), TagRules.rootOnly)
        XCTAssertNil(TagRules.canPlace(tree, nil, StructElement("Document")))
    }

    func test_settingATypeChecksParentKidsContentAndLinks() throws {
        let document = try TaggedFile.open()
        let tree = try XCTUnwrap(StructureTree.read(document))
        let root = tree.roots[0]
        let h1 = root.children[0]
        let p = root.children[1]

        XCTAssertNil(TagRules.canSetType(tree, p, "H2"))
        XCTAssertEqual(TagRules.canSetType(tree, p, "TD"), TagRules.needsRow)
        XCTAssertEqual(TagRules.canSetType(tree, h1, "L"), TagRules.noContent)
        XCTAssertEqual(TagRules.canSetType(tree, p, "Link"), TagRules.linkObject)
        XCTAssertEqual(TagRules.canSetType(tree, root, "Table"), TagRules.tableKids)
        XCTAssertNil(TagRules.canSetType(tree, root, "Sect"))
        XCTAssertEqual(TagRules.canSetType(tree, p, "Warning", "Weird"), TagRules.unmapped)
        XCTAssertNil(TagRules.canSetType(tree, p, "Warning", "P"))

        try tree.add(p, StructObject(0, PdfReference(99, 0)))
        XCTAssertNil(TagRules.canSetType(tree, p, "Link"))
    }

    func test_reasonsAreMessages() {
        let keys = [
            TagRules.rootOnly, TagRules.topLevel, TagRules.needsTable, TagRules.needsTableOrPart, TagRules.needsRow, TagRules.needsList,
            TagRules.needsItem, TagRules.needsCaptionParent, TagRules.needsToc, TagRules.needsRuby, TagRules.needsWarichu, TagRules.tableKids,
            TagRules.partKids, TagRules.rowKids, TagRules.listKids, TagRules.itemKids, TagRules.tocKids, TagRules.rubyKids,
            TagRules.warichuKids, TagRules.textKids, TagRules.noContent, TagRules.linkObject, TagRules.unmapped,
        ]
        for key in keys { XCTAssertNotEqual(AccessibilityText.placementReason(key), key) }
    }
}
