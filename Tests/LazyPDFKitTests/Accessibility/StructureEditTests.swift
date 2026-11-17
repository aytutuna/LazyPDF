import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Accessibility/StructureEditTests.cs: the same cases.

final class StructureEditTests: XCTestCase {
    private func kinds(_ element: StructElement) -> String {
        element.kids.map { kid -> String in
            if let e = kid as? StructElement { return e.type }
            if let c = kid as? StructContent { return "mcid\(c.mcid)" }
            return "obj"
        }.joined(separator: ",")
    }

    func test_standardTypeIsWrittenAsIs() throws {
        let document = try TaggedFile.open()
        let tree = try XCTUnwrap(StructureTree.read(document))
        let p = try XCTUnwrap(tree.elements.first { $0.type == "P" })

        XCTAssertTrue(tree.setType(p, "H2"))
        try tree.write(document)

        let again = try AccessKit.reopen(document, rewrite: true)
        let read = try XCTUnwrap(StructureTree.read(again))
        XCTAssertEqual(read.roots[0].children.map { $0.type }, ["H1", "H2", "Figure"])
        XCTAssertEqual(read.roleMap.count, 2)
    }

    func test_customTypeKeepsOrAddsARoleMapEntry() throws {
        let document = try TaggedFile.open()
        let tree = try XCTUnwrap(StructureTree.read(document))
        let p = try XCTUnwrap(tree.elements.first { $0.type == "P" })
        let h1 = try XCTUnwrap(tree.elements.first { $0.type == "H1" })

        XCTAssertTrue(tree.setType(h1, "Heading"))
        XCTAssertEqual(tree.roleMap["Heading"], "H1")
        XCTAssertTrue(tree.setType(p, "Warning"))
        XCTAssertEqual(tree.roleMap["Warning"], "P")
        XCTAssertTrue(tree.setType(p, "Aside", "Div"))
        XCTAssertEqual(tree.roleMap["Aside"], "Div")
        try tree.write(document)

        let again = try AccessKit.reopen(document, rewrite: true)
        let read = try XCTUnwrap(StructureTree.read(again))
        XCTAssertEqual(read.roots[0].children.map { $0.type }, ["Heading", "Aside", "Figure"])
        XCTAssertEqual(read.roleMap["Warning"], "P")
        XCTAssertEqual(read.standardType("Aside"), "Div")
    }

    func test_aTypeThatDoesNotResolveIsRefused() throws {
        let document = try TaggedFile.open { $0[8] = $0[8]!.replacingOccurrences(of: "/Weird /Nope", with: "/Weird /Nope /A /B /B /A") }
        let tree = try XCTUnwrap(StructureTree.read(document))
        let p = try XCTUnwrap(tree.elements.first { $0.type == "P" })

        XCTAssertFalse(tree.setType(p, ""))
        XCTAssertFalse(tree.setType(p, "Weird"))
        XCTAssertFalse(tree.setType(p, "A"))
        XCTAssertFalse(tree.setType(p, "New", "Weird"))
        XCTAssertFalse(tree.setType(p, "New", "New"))
        XCTAssertEqual(p.type, "P")
        XCTAssertFalse(tree.roleMap.containsKey("New"))
    }

    func test_anElementWithoutATypeNeedsAnExplicitTarget() throws {
        let document = try TaggedFile.open { $0[11] = "<</Type /StructElem /P 9 0 R /K 1>>" }
        let tree = try XCTUnwrap(StructureTree.read(document))
        let untyped = tree.roots[0].children[1]

        XCTAssertEqual(untyped.type, "")
        XCTAssertFalse(tree.setType(untyped, "Custom"))
        XCTAssertTrue(tree.setType(untyped, "Custom", "P"))
    }

    func test_textPropertiesSurviveASave() throws {
        let document = try TaggedFile.open()
        let tree = try XCTUnwrap(StructureTree.read(document))
        let p = try XCTUnwrap(tree.elements.first { $0.type == "P" })
        p.title = "Intro"
        p.alt = "Spoken"
        p.actualText = "Written"
        p.lang = "de"
        try tree.write(document)

        let again = try AccessKit.reopen(document, rewrite: false)
        let read = try XCTUnwrap(StructureTree.read(again)?.elements.first { $0.type == "P" })
        XCTAssertEqual([read.title, read.alt, read.actualText, read.lang], ["Intro", "Spoken", "Written", "de"])
    }

    func test_movesUpAndDownAmongAllKids() throws {
        let document = try TaggedFile.open()
        let tree = try XCTUnwrap(StructureTree.read(document))
        let root = tree.roots[0]
        let figure = try XCTUnwrap(root.children.last)
        let h1 = root.children[0]

        XCTAssertTrue(tree.moveUp(figure))
        XCTAssertEqual(kinds(root), "H1,Figure,P")
        XCTAssertFalse(tree.moveUp(h1))
        XCTAssertTrue(tree.moveDown(h1))
        XCTAssertEqual(kinds(root), "Figure,H1,P")
        XCTAssertFalse(tree.moveDown(try XCTUnwrap(root.children.last)))
        XCTAssertFalse(tree.moveUp(StructElement("P")))
        try tree.write(document)

        let again = try AccessKit.reopen(document, rewrite: false)
        let read = try XCTUnwrap(StructureTree.read(again))
        XCTAssertEqual(read.roots[0].children.map { $0.type }, ["Figure", "H1", "P"])
        XCTAssertEqual(read.elementFor(0, 0)?.type, "H1")
        XCTAssertEqual(read.elementFor(0, 2)?.type, "Figure")
    }

    func test_rootsAndContentMoveToo() throws {
        let document = try TaggedFile.open()
        let tree = try XCTUnwrap(StructureTree.read(document))
        let second = StructElement("Document")
        try tree.add(nil, second)
        let h1 = tree.roots[0].children[0]
        let content = try XCTUnwrap(h1.kids.first { $0 is StructContent })
        try tree.add(h1, StructContent(0, 7))

        XCTAssertTrue(tree.moveUp(second))
        assertSame(second, tree.roots[0])
        XCTAssertFalse(tree.moveUp(second))
        XCTAssertTrue(tree.moveDown(content))
        XCTAssertEqual(kinds(h1), "mcid7,mcid0")
    }

    func test_indentGoesIntoThePreviousSibling() throws {
        let document = try TaggedFile.open()
        let tree = try XCTUnwrap(StructureTree.read(document))
        let root = tree.roots[0]
        let h1 = root.children[0]
        let p = root.children[1]

        XCTAssertFalse(try tree.indent(h1))
        XCTAssertTrue(try tree.indent(p))
        XCTAssertEqual(kinds(root), "H1,Figure")
        XCTAssertEqual(kinds(h1), "mcid0,P")
        assertSame(h1, p.parent)
        XCTAssertFalse(try tree.indent(StructElement("P")))
        try tree.write(document)

        let again = try AccessKit.reopen(document, rewrite: true)
        let read = try XCTUnwrap(StructureTree.read(again))
        XCTAssertEqual(read.elementFor(0, 1)?.type, "P")
        XCTAssertEqual(read.elementFor(0, 1)?.parent?.type, "H1")
    }

    func test_indentIsRefusedAfterContent() throws {
        let document = try TaggedFile.open()
        let tree = try XCTUnwrap(StructureTree.read(document))
        let root = tree.roots[0]
        let figure = try XCTUnwrap(root.children.last)
        try tree.add(root, StructContent(0, 9), 2)

        XCTAssertFalse(try tree.indent(figure))
        XCTAssertEqual(kinds(root), "H1,P,mcid9,Figure")
    }

    func test_outdentGoesAfterTheParent() throws {
        let document = try TaggedFile.open()
        let tree = try XCTUnwrap(StructureTree.read(document))
        let root = tree.roots[0]
        let p = root.children[1]
        XCTAssertTrue(try tree.indent(p))
        XCTAssertTrue(try tree.indent(try XCTUnwrap(root.children.last)))
        XCTAssertEqual(kinds(root), "H1")

        let h1 = root.children[0]
        XCTAssertTrue(try tree.outdent(p))
        XCTAssertEqual(kinds(root), "H1,P")
        XCTAssertEqual(kinds(h1), "mcid0,Figure")
        XCTAssertFalse(try tree.outdent(root))
        XCTAssertFalse(try tree.outdent(StructElement("P")))
        try tree.write(document)

        let again = try AccessKit.reopen(document, rewrite: false)
        let read = try XCTUnwrap(StructureTree.read(again))
        XCTAssertEqual(read.elementFor(0, 2)?.parent?.type, "H1")
        XCTAssertEqual(read.elementFor(0, 1)?.parent?.type, "Document")
    }

    func test_outdentFromARootChildMakesARoot() throws {
        let document = try TaggedFile.open()
        let tree = try XCTUnwrap(StructureTree.read(document))
        let p = tree.roots[0].children[1]

        XCTAssertTrue(try tree.outdent(p))
        XCTAssertEqual(tree.roots.count, 2)
        assertSame(p, tree.roots[1])
        XCTAssertNil(p.parent)
        try tree.write(document)

        let again = try AccessKit.reopen(document, rewrite: true)
        XCTAssertEqual(try XCTUnwrap(StructureTree.read(again)).roots.map { $0.type }, ["Document", "P"])
    }

    func test_unwrapKeepsElementsInPlace() throws {
        let document = try TaggedFile.open()
        let tree = try XCTUnwrap(StructureTree.read(document))
        let root = tree.roots[0]
        let div = StructElement("Div")
        try tree.add(root, div, 1)
        try tree.move(try XCTUnwrap(root.children.first { $0.type == "P" }), div, -1)
        try tree.move(try XCTUnwrap(root.children.first { $0.type == "Figure" }), div, -1)
        XCTAssertEqual(kinds(root), "H1,Div")
        try tree.write(document)
        let number = try XCTUnwrap(div.reference).number

        XCTAssertTrue(tree.unwrap(div))
        XCTAssertEqual(kinds(root), "H1,P,Figure")
        XCTAssertNil(div.parent)
        try tree.write(document)

        XCTAssertNil(document.get(number))
        let again = try AccessKit.reopen(document, rewrite: true)
        let read = try XCTUnwrap(StructureTree.read(again))
        XCTAssertEqual(read.roots[0].children.map { $0.type }, ["H1", "P", "Figure"])
        XCTAssertEqual(read.elementFor(0, 1)?.parent?.type, "Document")
    }

    func test_unwrapMovesContentIntoTheParentAtItsPlace() throws {
        let document = try TaggedFile.open()
        let tree = try XCTUnwrap(StructureTree.read(document))
        let root = tree.roots[0]
        let p = root.children[1]
        let number = try XCTUnwrap(p.reference).number
        try tree.add(p, StructObject(0, document.pages[0].reference))

        XCTAssertTrue(tree.unwrap(p))
        XCTAssertEqual(kinds(root), "H1,mcid1,obj,Figure")
        try tree.write(document)

        XCTAssertNil(document.get(number))
        let again = try AccessKit.reopen(document, rewrite: true)
        let read = try XCTUnwrap(StructureTree.read(again))
        XCTAssertEqual(read.elementFor(0, 1)?.type, "Document")
        XCTAssertEqual(read.elementFor(0, 2)?.type, "Figure")
        XCTAssertEqual(read.elementFor(0, 0)?.type, "H1")
        XCTAssertEqual(kinds(read.roots[0]), "H1,mcid1,obj,Figure")
    }

    func test_unwrapOfARootPromotesItsElements() throws {
        let document = try TaggedFile.open()
        let tree = try XCTUnwrap(StructureTree.read(document))

        XCTAssertTrue(tree.unwrap(tree.roots[0]))
        XCTAssertEqual(tree.roots.map { $0.type }, ["H1", "P", "Figure"])
        for r in tree.roots { XCTAssertNil(r.parent) }
        try tree.write(document)

        let again = try AccessKit.reopen(document, rewrite: false)
        let read = try XCTUnwrap(StructureTree.read(again))
        XCTAssertEqual(read.roots.map { $0.type }, ["H1", "P", "Figure"])
        XCTAssertEqual(read.elementFor(0, 1)?.type, "P")
    }

    func test_unwrapRefusesWhatARootCannotHold() throws {
        let document = try TaggedFile.open()
        let tree = try XCTUnwrap(StructureTree.read(document))
        let root = tree.roots[0]
        try tree.add(root, StructContent(0, 5))

        XCTAssertFalse(tree.unwrap(root))
        XCTAssertEqual(tree.roots.count, 1)
        XCTAssertFalse(tree.unwrap(StructElement("P")))
    }

    func test_elementsWithoutKidsEditCleanly() throws {
        let document = try TaggedFile.open { $0[11] = "<</Type /StructElem /S /P /P 9 0 R>>" }
        let tree = try XCTUnwrap(StructureTree.read(document))
        let p = tree.roots[0].children[1]

        XCTAssertTrue(p.kids.isEmpty)
        XCTAssertTrue(try tree.indent(p))
        XCTAssertTrue(try tree.outdent(p))
        XCTAssertTrue(tree.moveUp(p))
        XCTAssertTrue(tree.unwrap(p))
        XCTAssertEqual(kinds(tree.roots[0]), "H1,Figure")
        try tree.write(document)

        let again = try AccessKit.reopen(document, rewrite: true)
        XCTAssertEqual(try XCTUnwrap(StructureTree.read(again)).roots[0].children.map { $0.type }, ["H1", "Figure"])
    }

    func test_aRoleMapLoopDoesNotStopEditing() throws {
        let document = try TaggedFile.open { $0[8] = $0[8]!.replacingOccurrences(of: "/Weird /Nope", with: "/A /B /B /A") }
        let tree = try XCTUnwrap(StructureTree.read(document))
        let p = tree.roots[0].children[1]

        XCTAssertTrue(tree.setType(p, "H2"))
        XCTAssertTrue(try tree.indent(p))
        try tree.write(document)
        XCTAssertEqual(try XCTUnwrap(StructureTree.read(document)).roleMap["A"], "B")
    }

    func test_anIdTheTreeLacksIsAddedToTheIdTree() throws {
        let document = try TaggedFile.open()
        let tree = try XCTUnwrap(StructureTree.read(document))
        tree.roots[0].children[0].id = "intro"
        try tree.write(document)

        let again = try AccessKit.reopen(document, rewrite: true)
        let read = try XCTUnwrap(StructureTree.read(again))
        let entries = PdfNameTree.read(again, read.dictionary["IDTree"])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(PdfNameTree.textOf(entries[0].key), "intro")
        XCTAssertEqual((entries[0].value as? PdfReference)?.number, read.roots[0].children[0].reference?.number)

        read.roots[0].children[0].id = nil
        try read.write(again)
        XCTAssertTrue(PdfNameTree.read(again, read.dictionary["IDTree"]).isEmpty)
    }

    func test_theIdTreeKeepsTheBytesOfAnId() throws {
        let raw: [UInt8] = [0xFE, 0xFF, 0x00, 0x74, 0x00, 0x68, 0x00, 0x31]
        let document = try TaggedFile.open()
        let tree = try XCTUnwrap(StructureTree.read(document))
        let first = tree.roots[0].children[0]
        first.id = "th1"
        first.dictionary["ID"] = PdfString(bytes: raw, isHex: true)
        try tree.write(document)

        let again = try AccessKit.reopen(document, rewrite: true)
        let read = try XCTUnwrap(StructureTree.read(again))
        read.roots[0].children[1].title = "second"
        try read.write(again)

        let entries = PdfNameTree.read(again, read.dictionary["IDTree"])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(Latin1.bytes(entries[0].key), raw)
        XCTAssertEqual((again.resolve(read.roots[0].children[0].dictionary["ID"]) as? PdfString)?.bytes, raw)
    }

    func test_anIdTreeThatIsNotADictionaryIsReplaced() throws {
        let document = try TaggedFile.open()
        let tree = try XCTUnwrap(StructureTree.read(document))
        tree.dictionary["IDTree"] = PdfNumber(7)
        tree.roots[0].children[0].id = "intro"
        try tree.write(document)

        XCTAssertTrue(document.resolve(tree.dictionary["IDTree"]) is PdfDictionary)
        let entries = PdfNameTree.read(document, tree.dictionary["IDTree"])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(PdfNameTree.textOf(entries[0].key), "intro")
    }
}
