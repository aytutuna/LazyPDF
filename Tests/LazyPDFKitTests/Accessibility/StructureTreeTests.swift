import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Accessibility/StructureTreeTests.cs: the same cases. A save is read back by
// PdfDocument only; the PdfPig check in the C# `Reopen` has no twin.

final class StructureTreeTests: XCTestCase {
    func test_readsElementsAndMaps() throws {
        let document = try TaggedFile.open()
        let tree = try XCTUnwrap(StructureTree.read(document))

        XCTAssertEqual(tree.roots.count, 1)
        let root = tree.roots[0]
        XCTAssertEqual(root.type, "Document")
        XCTAssertEqual(root.children.map { $0.type }, ["H1", "P", "Figure"])
        let h1 = try XCTUnwrap(root.children.first)
        XCTAssertEqual(h1.title, "Head")
        XCTAssertEqual(h1.lang, "tr")
        XCTAssertEqual(h1.pageIndex, 0)
        XCTAssertEqual(h1.kids.count, 1)
        XCTAssertEqual((h1.kids[0] as? StructContent)?.mcid, 0)
        XCTAssertEqual(tree.elements.first { $0.type == "P" }?.actualText, "Body text")
        XCTAssertEqual(tree.elements.first { $0.type == "Figure" }?.alt, "A picture")
        XCTAssertEqual(tree.roleMap["Heading"], "H1")
        XCTAssertTrue(tree.classMap.containsKey("Fancy"))
        assertSame(root, h1.parent)
        XCTAssertFalse(tree.isTruncated)
    }

    func test_parentTreeFindsTheElementOfASequence() throws {
        let document = try TaggedFile.open()
        let tree = try XCTUnwrap(StructureTree.read(document))

        XCTAssertEqual(tree.elementFor(0, 1)?.type, "P")
        XCTAssertEqual(tree.elementFor(0, 2)?.type, "Figure")
        XCTAssertNil(tree.elementFor(0, 9))
        XCTAssertNil(tree.elementFor(5, 0))
    }

    func test_standardTypeFollowsTheRoleMap() throws {
        let document = try TaggedFile.open()
        let tree = try XCTUnwrap(StructureTree.read(document))

        XCTAssertEqual(tree.standardType("Heading"), "H1")
        XCTAssertEqual(tree.standardType("Weird"), "Nope")
        XCTAssertEqual(tree.standardType("P"), "P")
        tree.roleMap["A"] = "B"
        tree.roleMap["B"] = "A"
        XCTAssertFalse(StructureTree.isStandard(tree.standardType("A")))
        XCTAssertTrue(StructureTree.isStandard("H3"))
        XCTAssertFalse(StructureTree.isStandard("H0"))
        XCTAssertFalse(StructureTree.isStandard("Hx"))
    }

    func test_noTreeReadsAsNull() throws {
        let document = try PdfDocument.open(AccessKit.build(1) { _ in "" })
        XCTAssertNil(StructureTree.read(document))
    }

    func test_writingWhatWasReadChangesNothing() throws {
        let document = try PdfDocument.open(TaggedFile.build())
        try XCTUnwrap(StructureTree.read(document)).write(document)

        XCTAssertTrue(document.changedObjects().isEmpty)
    }

    func test_retagAltAndLanguageSurviveASave() throws {
        let document = try TaggedFile.open()
        let tree = try XCTUnwrap(StructureTree.read(document))
        let figure = try XCTUnwrap(tree.elements.first { $0.type == "Figure" })
        figure.type = "Formula"
        figure.alt = "x squared"
        figure.lang = "en"
        try XCTUnwrap(tree.elements.first { $0.type == "P" }).type = "Div"
        try tree.write(document)

        for rewrite in [false, true] {
            let again = try AccessKit.reopen(document, rewrite: rewrite)
            let read = try XCTUnwrap(StructureTree.read(again))
            XCTAssertEqual(read.roots[0].children.map { $0.type }, ["H1", "Div", "Formula"])
            let formula = try XCTUnwrap(read.elements.first { $0.type == "Formula" })
            XCTAssertEqual(formula.alt, "x squared")
            XCTAssertEqual(formula.lang, "en")
            XCTAssertEqual(read.elementFor(0, 2)?.type, "Formula")
        }
    }

    func test_unknownKeysStay() throws {
        let document = try TaggedFile.open()
        let tree = try XCTUnwrap(StructureTree.read(document))
        let h1 = try XCTUnwrap(tree.elements.first { $0.type == "H1" })
        h1.alt = "changed"
        try tree.write(document)

        let again = try AccessKit.reopen(document, rewrite: true)
        let read = try XCTUnwrap(StructureTree.read(again)?.elements.first { $0.type == "H1" })
        XCTAssertEqual(again.name(read.dictionary, "C"), "Fancy")
        XCTAssertEqual(again.name(again.dict(read.dictionary, "A"), "O"), "Layout")
        XCTAssertEqual(again.name(again.dict(read.dictionary, "A"), "Placement"), "Block")
    }

    func test_reorderKeepsTheParentTreeRight() throws {
        let document = try TaggedFile.open()
        let tree = try XCTUnwrap(StructureTree.read(document))
        let figure = try XCTUnwrap(tree.elements.first { $0.type == "Figure" })
        try tree.move(figure, tree.roots[0], 0)
        try tree.write(document)

        let again = try AccessKit.reopen(document, rewrite: false)
        let read = try XCTUnwrap(StructureTree.read(again))
        XCTAssertEqual(read.roots[0].children.map { $0.type }, ["Figure", "H1", "P"])
        XCTAssertEqual(read.elementFor(0, 2)?.type, "Figure")
        XCTAssertEqual(read.elementFor(0, 0)?.type, "H1")
    }

    func test_moveInsideItselfIsRefused() throws {
        let document = try TaggedFile.open()
        let tree = try XCTUnwrap(StructureTree.read(document))
        let root = tree.roots[0]
        let child = try XCTUnwrap(root.children.first)

        XCTAssertThrowsError(try tree.move(root, child, 0)) { XCTAssertTrue($0 is ArgumentException) }
        XCTAssertThrowsError(try tree.add(child, child)) { XCTAssertTrue($0 is ArgumentException) }
        XCTAssertThrowsError(try tree.add(nil, StructContent(0, 3))) { XCTAssertTrue($0 is ArgumentException) }
    }

    func test_removeFreesTheObjectsAndEmptiesTheParentTreeSlot() throws {
        let document = try TaggedFile.open()
        let tree = try XCTUnwrap(StructureTree.read(document))
        let p = try XCTUnwrap(tree.elements.first { $0.type == "P" })
        let number = try XCTUnwrap(p.reference).number
        tree.remove(p)
        try tree.write(document)

        XCTAssertNil(document.get(number))
        let read = try XCTUnwrap(StructureTree.read(document))
        XCTAssertEqual(read.roots[0].children.map { $0.type }, ["H1", "Figure"])
        XCTAssertNil(read.elementFor(0, 1))
        XCTAssertEqual(read.elementFor(0, 2)?.type, "Figure")
    }

    func test_addedElementsGetObjectsAndParentTreeEntries() throws {
        let document = try PdfDocument.open(AccessKit.build(2) { i in "BT /F1 12 Tf 72 700 Td (page \(i)) Tj ET" })
        let tree = StructureTree.create(document)
        let root = StructElement("Document")
        try tree.add(nil, root)
        let first = StructElement("P")
        first.pageIndex = 0
        let second = StructElement("P")
        second.pageIndex = 1
        try tree.add(root, first)
        try tree.add(root, second)
        try tree.add(first, StructContent(0, 0))
        try tree.add(second, StructContent(1, 0))
        try tree.write(document)

        XCTAssertTrue(document.isTagged)
        XCTAssertNotNil(first.reference)
        let keys = document.pages.map { document.integer($0.dictionary, "StructParents") }
        for key in keys { XCTAssertNotNil(key) }
        XCTAssertNotEqual(keys[0], keys[1])

        let again = try AccessKit.reopen(document, rewrite: true)
        let read = try XCTUnwrap(StructureTree.read(again))
        XCTAssertEqual(read.roots[0].children.count, 2)
        XCTAssertEqual(read.elementFor(try XCTUnwrap(again.integer(again.pages[0].dictionary, "StructParents")), 0)?.pageIndex, 0)
        XCTAssertEqual(read.elementFor(try XCTUnwrap(again.integer(again.pages[1].dictionary, "StructParents")), 0)?.pageIndex, 1)
    }

    func test_contentOnAnotherPageThanTheElementsIsWrittenAsMcr() throws {
        let document = try PdfDocument.open(AccessKit.build(2) { i in "/P <</MCID 0>> BDC BT /F1 12 Tf 72 700 Td (page \(i)) Tj ET EMC" })
        let tree = StructureTree.create(document)
        let p = StructElement("P")
        p.pageIndex = 0
        try tree.add(nil, p)
        try tree.add(p, StructContent(0, 0))
        try tree.add(p, StructContent(1, 0))
        try tree.write(document)

        let again = try AccessKit.reopen(document, rewrite: false)
        let read = try XCTUnwrap(StructureTree.read(again)).roots[0]
        XCTAssertEqual(read.kids.compactMap { ($0 as? StructContent)?.pageIndex }, [0, 1])
    }

    func test_objectReferencesGetAStructParent() throws {
        let document = try PdfDocument.open(AccessKit.build(1, { _ in "" }, pageEntries: "/Annots [8 0 R]", more: { pdf in
            pdf.obj(8, "<</Type /Annot /Subtype /Link /Rect [72 700 144 712] /Border [0 0 0]>>")
        }))
        let tree = StructureTree.create(document)
        let link = StructElement("Link")
        link.pageIndex = 0
        try tree.add(nil, link)
        try tree.add(link, StructObject(0, PdfReference(8, 0)))
        try tree.write(document)

        XCTAssertNotNil(document.integer(try XCTUnwrap(document.get(8) as? PdfDictionary), "StructParent"))
        let again = try AccessKit.reopen(document, rewrite: true)
        let read = try XCTUnwrap(StructureTree.read(again))
        XCTAssertEqual(read.roots[0].kids.count, 1)
        let target = try XCTUnwrap(read.roots[0].kids[0] as? StructObject)
        let annotation = try XCTUnwrap(again.resolve(target.target) as? PdfDictionary)
        XCTAssertEqual(read.elementFor(try XCTUnwrap(again.integer(annotation, "StructParent")), -1)?.type, "Link")
    }

    func test_parentTreeOfManyPagesIsSplitAndStillFindsEverything() throws {
        let document = try PdfDocument.open(AccessKit.build(70) { i in "BT /F1 12 Tf 72 700 Td (page \(i)) Tj ET" })
        let tree = StructureTree.create(document)
        let root = StructElement("Document")
        try tree.add(nil, root)
        for i in 0..<70 {
            let p = StructElement("P")
            p.pageIndex = i
            try tree.add(root, p)
            try tree.add(p, StructContent(i, 0))
        }
        try tree.write(document)

        let again = try AccessKit.reopen(document, rewrite: true)
        let read = try XCTUnwrap(StructureTree.read(again))
        XCTAssertEqual(read.parentTree.count, 70)
        for i in 0..<70 {
            XCTAssertEqual(read.elementFor(try XCTUnwrap(again.integer(again.pages[i].dictionary, "StructParents")), 0)?.pageIndex, i)
        }
    }

    func test_loopsJunkAndMissingTypesAreTolerated() throws {
        let document = try TaggedFile.open { o in
            o[9] = "<</Type /StructElem /S /Document /P 8 0 R /K [10 0 R 9 0 R -3 (junk) null 14 0 R <</S /Span /Pg 3 0 R /K 5>> 11 0 R 12 0 R 99 0 R]>>"
            o[14] = "<</Type /StructElem /P 9 0 R /K 15 0 R>>"
            o[15] = "<</Type /StructElem /S /Span /P 14 0 R /K [15 0 R 3 4]>>"
        }
        let tree = try XCTUnwrap(StructureTree.read(document))

        let root = tree.roots[0]
        XCTAssertEqual(root.children.map { $0.type }, ["H1", "", "Span", "P", "Figure"])
        let span = try XCTUnwrap(tree.elements.first { e in e.type == "Span" && e.kids.contains { ($0 as? StructContent)?.mcid == 3 } })
        XCTAssertEqual(span.kids.compactMap { ($0 as? StructContent)?.mcid }, [3, 4])
        XCTAssertFalse(tree.isTruncated)
    }

    func test_aDeepChainIsCutAndRefusesToBeWritten() throws {
        let document = try TaggedFile.open { o in
            o[9] = "<</Type /StructElem /S /Document /P 8 0 R /K 100 0 R>>"
            for i in 100..<400 { o[i] = "<</Type /StructElem /S /Div /K \(i + 1) 0 R>>" }
        }
        let tree = try XCTUnwrap(StructureTree.read(document))

        XCTAssertTrue(tree.isTruncated)
        XCTAssertLessThan(tree.elements.count, 200)
        XCTAssertThrowsError(try tree.write(document)) { XCTAssertTrue($0 is InvalidOperationException) }
    }

    func test_kidsAreReadWithTheirPageFromMcrAndObjr() throws {
        let document = try PdfDocument.open(AccessKit.build(2, { _ in "" }, catalog: "/StructTreeRoot 8 0 R", more: { pdf in
            pdf.obj(8, "<</Type /StructTreeRoot /K 9 0 R>>")
            pdf.obj(9, "<</S /Document /K [<</Type /MCR /Pg 4 0 R /MCID 7>> <</Type /OBJR /Pg 3 0 R /Obj 10 0 R>> <</Type /MCR /Pg 3 0 R /Stm 11 0 R /MCID 2>>]>>")
            pdf.obj(10, "<</Type /Annot /Subtype /Widget /Rect [0 0 1 1]>>")
            pdf.obj(11, "<</Type /XObject /Subtype /Form /BBox [0 0 1 1]>>")
        }))
        let kids = try XCTUnwrap(StructureTree.read(document)).roots[0].kids

        let mcr = try XCTUnwrap(kids[0] as? StructContent)
        XCTAssertEqual([mcr.pageIndex, mcr.mcid], [1, 7])
        let objr = try XCTUnwrap(kids[1] as? StructObject)
        XCTAssertEqual([objr.pageIndex, objr.target.number], [0, 10])
        XCTAssertEqual((kids[2] as? StructContent)?.stream?.number, 11)
    }

    func test_aRemovedElementMovedBackKeepsItsObject() throws {
        let document = try TaggedFile.open()
        let tree = try XCTUnwrap(StructureTree.read(document))
        let p = try XCTUnwrap(tree.elements.first { $0.type == "P" })
        let number = try XCTUnwrap(p.reference).number
        tree.remove(p)
        try tree.move(p, tree.roots[0], -1)
        try tree.write(document)

        XCTAssertNotNil(document.get(number))
        let read = try XCTUnwrap(StructureTree.read(document))
        XCTAssertEqual(read.roots[0].children.map { $0.type }, ["H1", "Figure", "P"])
        XCTAssertEqual(read.elementFor(0, 1)?.type, "P")
    }
}
