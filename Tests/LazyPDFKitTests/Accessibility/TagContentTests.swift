import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Accessibility/TagContentTests.cs: the same cases.

final class TagContentTests: XCTestCase {
    private let words = "BT /F1 11 Tf 72 700 Td (Hello world) Tj ET\nBT /F1 11 Tf 72 650 Td (Second line) Tj ET\n"

    // Object 3 is the page, 4 the font, 5 an image, 6 a form that draws "Label", streams are 20 and up, the tree 30 and up.
    private func make(_ streams: [String], _ tree: ((TestPdf) -> Void)? = nil, pages: Int = 1, structure: Bool = false) -> [UInt8] {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R \(structure ? "/StructTreeRoot 30 0 R /MarkInfo <</Marked true>>" : "") /Lang (en-US)>>")
        let kids = (0..<pages).map { "\(3 + 40 * $0) 0 R" }.joined(separator: " ")
        pdf.obj(2, "<</Type /Pages /Kids [\(kids)] /Count \(pages) /MediaBox [0 0 612 792]>>")
        let contents = streams.indices.map { "\(20 + $0) 0 R" }.joined(separator: " ")
        for p in 0..<pages {
            pdf.obj(3 + 40 * p, "<</Type /Page /Parent 2 0 R /Contents [\(contents)] /Resources <</Font <</F1 4 0 R>> /XObject <</Im1 5 0 R /Fm1 6 0 R>> /Properties <</MC0 <</MCID 0 /Subtype /Footer /Type /Pagination>>>>>>\(structure && p == 0 ? " /StructParents 0" : "")>>")
        }
        pdf.obj(4, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding>>")
        pdf.stream(5, "/Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceGray /BitsPerComponent 8", [0, 80, 160, 255])
        pdf.stream(6, "/Type /XObject /Subtype /Form /BBox [0 0 612 792] /Resources <</Font <</F1 4 0 R>>>>", "BT /F1 11 Tf 300 300 Td (Label) Tj ET")
        for (i, s) in streams.enumerated() { pdf.stream(20 + i, "", s) }
        tree?(pdf)
        return pdf.finish()
    }

    // Root 30 holds Document 31 with the given kids (object 32 on); /K of each is written by the caller.
    private func tree(_ elements: String...) -> (TestPdf) -> Void {
        return { pdf in
            pdf.obj(30, "<</Type /StructTreeRoot /K 31 0 R /ParentTree 29 0 R>>")
            let kids = elements.indices.map { "\(32 + $0) 0 R" }.joined(separator: " ")
            pdf.obj(31, "<</Type /StructElem /S /Document /P 30 0 R /K [\(kids)]>>")
            for (i, e) in elements.enumerated() {
                pdf.obj(32 + i, e.replacingOccurrences(of: "PARENT", with: "31 0 R").replacingOccurrences(of: "PAGE", with: "3 0 R"))
            }
            pdf.obj(29, "<</Nums []>>")
        }
    }

    private func drawing(_ document: PdfDocument, _ page: Int = 0) -> String {
        ContentParser.parse(document.pages[page].contents())
            .filter { $0.operator != "BMC" && $0.operator != "BDC" && $0.operator != "EMC" }.map { $0.description }.joined(separator: "\n")
    }

    private func kinds(_ element: StructElement) -> String {
        element.kids.map { kid -> String in
            if let e = kid as? StructElement { return "\(e.type)(\(kinds(e)))" }
            if let c = kid as? StructContent { return "mcid\(c.mcid)" }
            return "obj"
        }.joined(separator: ",")
    }

    private func tags(_ document: PdfDocument, _ page: Int = 0) -> String {
        AccessKit.sequences(document, page).map { $0.mcid < 0 ? $0.tag : "\($0.tag):\($0.mcid)" }.joined(separator: " ")
    }

    private func open(_ bytes: [UInt8]) throws -> PdfDocument { try PdfDocument.open(bytes) }

    func test_markingAnElementAsArtifactRewritesItsSequenceAndDropsIt() throws {
        let document = try TaggedFile.open()
        let before = drawing(document)
        let tree = try XCTUnwrap(StructureTree.read(document))
        let p = try XCTUnwrap(AccessKit.find(tree, "P"))

        XCTAssertNil(tree.markAsArtifact(p))
        try tree.write(document)

        XCTAssertEqual(tags(document), "H1:0 Artifact Figure:2")
        XCTAssertEqual(drawing(document), before)
        XCTAssertTrue(AccessKit.isBalanced(document, 0))
        let again = try AccessKit.reopen(document, rewrite: true)
        let read = try XCTUnwrap(StructureTree.read(again))
        XCTAssertEqual(read.roots[0].children.map { $0.type }, ["H1", "Figure"])
        XCTAssertFalse(ReadingOrder.export(again).contains("Body"))
        XCTAssertEqual(read.parentTree.count, 1)
        let array = try XCTUnwrap(again.resolve(read.parentTree[0].value) as? PdfArray)
        XCTAssertEqual(array.items.count, 3)
        XCTAssertTrue(array.items[1] is PdfNull)
    }

    func test_anElementLeftEmptyIsDroppedButNotTheRoot() throws {
        let document = try TaggedFile.open()
        let tree = try XCTUnwrap(StructureTree.read(document))
        let content = try XCTUnwrap(AccessKit.find(tree, "P")?.kids.compactMap { $0 as? StructContent }.first)

        XCTAssertNil(tree.markAsArtifact(content))

        XCTAssertEqual(tree.roots[0].children.map { $0.type }, ["H1", "Figure"])
        for element in tree.roots[0].children { XCTAssertNil(tree.markAsArtifact(element)) }
        XCTAssertEqual(tree.roots.count, 1)
        XCTAssertTrue(tree.roots[0].kids.isEmpty)
        XCTAssertEqual(tags(document), "Artifact Artifact Artifact")
    }

    func test_anElementWithSeveralContentsAndNestedElementsTakesAllOfThem() throws {
        let content = "/P <</MCID 0>> BDC BT /F1 11 Tf 72 700 Td (A) Tj ET EMC /Span <</MCID 1>> BDC BT /F1 11 Tf 72 650 Td (B) Tj ET EMC /P <</MCID 2>> BDC BT /F1 11 Tf 72 600 Td (C) Tj ET EMC"
        let document = try open(make([content], tree(
            "<</Type /StructElem /S /Div /P PARENT /Pg PAGE /K [0 33 0 R]>>",
            "<</Type /StructElem /S /Span /P 32 0 R /Pg PAGE /K 1>>",
            "<</Type /StructElem /S /P /P PARENT /Pg PAGE /K 2>>"), structure: true))
        let before = drawing(document)
        let tree = try XCTUnwrap(StructureTree.read(document))

        XCTAssertNil(tree.markAsArtifact(try XCTUnwrap(AccessKit.find(tree, "Div"))))

        XCTAssertEqual(tags(document), "Artifact Artifact P:2")
        XCTAssertEqual(drawing(document), before)
        XCTAssertEqual(tree.roots[0].children.map { $0.type }, ["P"])
    }

    func test_artifactPropertiesSurviveAndOtherKeysGo() throws {
        let content = "/Span /MC0 BDC BT /F1 11 Tf 72 700 Td (Footer) Tj ET EMC /P <</MCID 1 /Lang (en)>> BDC BT /F1 11 Tf 72 650 Td (B) Tj ET EMC"
        let document = try open(make([content], tree(
            "<</Type /StructElem /S /Span /P PARENT /Pg PAGE /K 0>>",
            "<</Type /StructElem /S /P /P PARENT /Pg PAGE /K 1>>"), structure: true))
        let tree = try XCTUnwrap(StructureTree.read(document))

        XCTAssertNil(tree.markAsArtifact(tree.roots[0].children[0]))
        XCTAssertNil(tree.markAsArtifact(tree.roots[0].children[0]))

        let text = TestPdf.text(document.pages[0].contents())
        XCTAssertTrue(text.contains("/Artifact <</Type /Pagination /Subtype /Footer>> BDC"))
        XCTAssertTrue(text.contains("/Artifact BMC"))
        XCTAssertFalse(text.contains("MCID"))
    }

    func test_taggedContentInsideTheSequenceRefusesAndChangesNothing() throws {
        let content = "/P <</MCID 0>> BDC BT /F1 11 Tf 72 700 Td (A) Tj /Span <</MCID 1>> BDC (B) Tj EMC ET EMC"
        let document = try open(make([content], tree(
            "<</Type /StructElem /S /P /P PARENT /Pg PAGE /K 0>>",
            "<</Type /StructElem /S /Span /P PARENT /Pg PAGE /K 1>>"), structure: true))
        let tree = try XCTUnwrap(StructureTree.read(document))
        let before = document.pages[0].contents()

        XCTAssertEqual(tree.markAsArtifact(tree.roots[0].children[0]), TagContent.nestedTagged)

        XCTAssertEqual(document.pages[0].contents(), before)
        XCTAssertEqual(tree.roots[0].children.count, 2)
    }

    func test_contentOfSeveralStreamsIsRewrittenInPlace() throws {
        let streams = [
            "/H1 <</MCID 0>> BDC BT /F1 11 Tf 72 700 Td (Head) Tj ET EMC\n",
            "/P <</MCID 1>> BDC BT /F1 11 Tf 72 650 Td (Body) Tj ET\n",
            " EMC\n/P <</MCID 2>> BDC BT /F1 11 Tf 72 600 Td (Tail) Tj ET EMC\n",
        ]
        let document = try open(make(streams, tree(
            "<</Type /StructElem /S /H1 /P PARENT /Pg PAGE /K 0>>",
            "<</Type /StructElem /S /P /P PARENT /Pg PAGE /K 1>>",
            "<</Type /StructElem /S /P /P PARENT /Pg PAGE /K 2>>"), structure: true))
        let before = drawing(document)
        let tree = try XCTUnwrap(StructureTree.read(document))
        let parts = TagSession.streams(document, document.pages[0])
        let first = try document.data(parts[0])

        XCTAssertNil(tree.markAsArtifact(tree.roots[0].children[1]))

        XCTAssertEqual(tags(document), "H1:0 Artifact P:2")
        XCTAssertEqual(try document.data(parts[0]), first)
        XCTAssertEqual(drawing(document), before)
        XCTAssertTrue(AccessKit.isBalanced(document, 0))
    }

    func test_aSharedStreamAndFormContentAreRefused() throws {
        let content = "/P <</MCID 0>> BDC BT /F1 11 Tf 72 700 Td (A) Tj ET EMC"
        let elements = tree("<</Type /StructElem /S /P /P PARENT /Pg PAGE /K 0>>")
        let shared = try open(make([content], elements, pages: 2, structure: true))
        let sharedTree = try XCTUnwrap(StructureTree.read(shared))

        XCTAssertEqual(sharedTree.markAsArtifact(sharedTree.roots[0].children[0]), TagContent.sharedStream)

        let alone = try open(make([content], elements, structure: true))
        let other = try XCTUnwrap(StructureTree.read(alone))
        let inForm = StructElement("P")
        inForm.pageIndex = 0
        try other.add(other.roots[0], inForm)
        try other.add(inForm, StructContent(0, 0, PdfReference(6, 0)))

        XCTAssertEqual(other.markAsArtifact(inForm), TagContent.formContent)
        XCTAssertEqual(other.markAsArtifact(StructObject(0, PdfReference(3, 0))), TagContent.notContent)
    }

    func test_aSelectionInAFileWithoutTagsMakesADocumentAndAnElement() throws {
        let document = try open(make([words]))
        let before = drawing(document)
        let tree = StructureTree.read(document) ?? StructureTree.create(document)
        let line = TextPage.create(document, document.pages[0]).lines[0].range

        let result = try tree.tagSelection(0, [line], "P", nil)

        XCTAssertNil(result.reason)
        XCTAssertEqual(kinds(tree.roots[0]), "P(mcid0)")
        XCTAssertEqual(tags(document), "P:0")
        XCTAssertEqual(drawing(document), before)
        try tree.write(document)

        let again = try AccessKit.reopen(document, rewrite: true)
        XCTAssertNotNil(again.pages[0].dictionary["StructParents"])
        XCTAssertEqual(ReadingOrder.export(again), "Hello world")
        XCTAssertEqual(StructureTree.read(again)?.roots.map { $0.type }, ["Document"])
    }

    func test_aRoleMappedTypeWithASpaceAndALatinByteIsWrittenAsOneName() throws {
        let document = try open(make([words]))
        let tree = StructureTree.create(document)
        tree.roleMap["Body T\u{E9}xt"] = "P"
        let line = TextPage.create(document, document.pages[0]).lines[0].range

        XCTAssertNil(try tree.tagSelection(0, [line], "Body T\u{E9}xt", nil).reason)

        let begin = try XCTUnwrap(ContentParser.parse(document.pages[0].contents()).first { $0.operator == "BDC" })
        XCTAssertEqual(begin.operands.count, 2)
        XCTAssertEqual((begin.operands[0] as? PdfName)?.value, "Body T\u{E9}xt")
        XCTAssertEqual(tags(document), "Body T\u{E9}xt:0")
    }

    func test_aSelectionThatCutsAStringIsRefusedWithTheContentUntouched() throws {
        let document = try open(make([words]))
        let tree = StructureTree.create(document)
        let before = document.pages[0].contents()
        let word = TextPage.create(document, document.pages[0]).words[0].range

        let result = try tree.tagSelection(0, [word], "P", nil)

        XCTAssertEqual(result.reason, TagContent.splitOperation)
        XCTAssertEqual(document.pages[0].contents(), before)
        XCTAssertTrue(tree.roots.isEmpty)
    }

    func test_twoLinesOfOneTextObjectShareOneSequence() throws {
        let content = "BT /F1 11 Tf 72 700 Td (One) Tj 0 -14 Td (Two) Tj 0 -14 Td (Three) Tj ET\n"
        let document = try open(make([content]))
        let before = drawing(document)
        let tree = StructureTree.create(document)
        let lines = TextPage.create(document, document.pages[0]).lines

        let result = try tree.tagSelection(0, [lines[0].range, lines[1].range], "P", nil)

        XCTAssertNil(result.reason)
        XCTAssertEqual(tags(document), "P:0")
        XCTAssertEqual(drawing(document), before)
        XCTAssertTrue(AccessKit.isBalanced(document, 0))
    }

    func test_anAreaTakesTheTextAndThePictureInsideItAndSkipsTheRest() throws {
        let content = words + "q 50 0 0 50 72 560 cm /Im1 Do Q\n"
        let document = try open(make([content]))
        let before = drawing(document)
        let tree = StructureTree.create(document)

        let result = try tree.tagArea(0, PdfRect(60, 545, 200, 665), "Figure", nil)

        XCTAssertNil(result.reason)
        XCTAssertEqual(tags(document), "Figure:0 Figure:1")
        XCTAssertEqual(drawing(document), before)
        XCTAssertEqual(kinds(tree.roots[0]), "Figure(mcid0,mcid1)")
        try tree.write(document)
        let again = try AccessKit.reopen(document, rewrite: true)
        XCTAssertEqual(ReadingOrder.export(again), "[Figure: Second line]")
    }

    func test_anAreaCuttingAnInlineImageIsRefused() throws {
        let content = "q 40 0 0 40 72 600 cm BI /W 2 /H 2 /CS /G /BPC 8 ID \u{00}\u{50}\u{A0}\u{FF} EI Q\n"
        let document = try open(make([content]))
        let tree = StructureTree.create(document)

        XCTAssertEqual(try tree.tagArea(0, PdfRect(0, 590, 90, 700), "Figure", nil).reason, TagContent.splitOperation)
        XCTAssertEqual(try tree.tagArea(0, PdfRect(300, 100, 400, 200), "Figure", nil).reason, TagContent.emptySelection)
        XCTAssertNil(try tree.tagArea(0, PdfRect(60, 590, 120, 700), "Figure", nil).reason)
    }

    func test_aWholeTaggedSequenceMovesToTheNewElementAndItsOldElementGoes() throws {
        let document = try TaggedFile.open()
        let before = drawing(document)
        let tree = try XCTUnwrap(StructureTree.read(document))
        let content = try XCTUnwrap(TextPage.create(document, document.pages[0]).lines.first { $0.text == "Body text" }).range

        let result = try tree.tagSelection(0, [content], "BlockQuote", tree.roots[0], 0)

        XCTAssertNil(result.reason)
        XCTAssertEqual(kinds(tree.roots[0]), "BlockQuote(mcid1),H1(mcid0),Figure(mcid2)")
        XCTAssertEqual(tags(document), "H1:0 P:1 Figure:2")
        XCTAssertEqual(drawing(document), before)
        try tree.write(document)
        let again = try AccessKit.reopen(document, rewrite: true)
        XCTAssertEqual(StructureTree.read(again)?.roots[0].children.map { $0.type }, ["BlockQuote", "H1", "Figure"])
    }

    func test_partOfATaggedSequenceIsRefused() throws {
        let content = "/P <</MCID 0>> BDC BT /F1 11 Tf 72 700 Td (One) Tj 0 -14 Td (Two) Tj ET EMC\n"
        let document = try open(make([content], tree("<</Type /StructElem /S /P /P PARENT /Pg PAGE /K 0>>"), structure: true))
        let tree = try XCTUnwrap(StructureTree.read(document))
        let before = document.pages[0].contents()
        let first = TextPage.create(document, document.pages[0]).lines[0].range

        let result = try tree.tagSelection(0, [first], "Quote", tree.roots[0])

        XCTAssertEqual(result.reason, TagContent.partialMarked)
        XCTAssertEqual(document.pages[0].contents(), before)
        XCTAssertEqual(tree.roots[0].children.map { $0.type }, ["P"])
    }

    func test_anArtifactSequenceTakesAFreshNumberWhenPickedWhole() throws {
        let content = "/P <</MCID 0>> BDC BT /F1 11 Tf 72 700 Td (Body) Tj ET EMC\n/Artifact <</Type /Pagination>> BDC BT /F1 9 Tf 72 30 Td (Page 1) Tj ET EMC\n/Artifact BMC BT /F1 9 Tf 72 20 Td (Other) Tj ET EMC\n"
        let document = try open(make([content], tree("<</Type /StructElem /S /P /P PARENT /Pg PAGE /K 0>>"), structure: true))
        let before = drawing(document)
        let tree = try XCTUnwrap(StructureTree.read(document))
        let footer = try XCTUnwrap(TextPage.create(document, document.pages[0]).lines.first { $0.text == "Page 1" }).range

        let result = try tree.tagSelection(0, [footer], "P", tree.roots[0])

        XCTAssertNil(result.reason)
        XCTAssertEqual(tags(document), "P:0 P:1 Artifact")
        XCTAssertEqual(drawing(document), before)
        XCTAssertTrue(AccessKit.isBalanced(document, 0))
        XCTAssertEqual(kinds(tree.roots[0]), "P(mcid0),P(mcid1)")
    }

    func test_anOpenSequenceTheTreeDoesNotNameIsClaimedAndNewNumbersSkipUsedOnes() throws {
        let content = "/P <</MCID 3>> BDC BT /F1 11 Tf 72 700 Td (Stray) Tj ET EMC\nBT /F1 11 Tf 72 650 Td (Loose) Tj ET\n"
        let document = try open(make([content]))
        let tree = StructureTree.create(document)
        let lines = TextPage.create(document, document.pages[0]).lines

        let result = try tree.tagSelection(0, [lines[0].range, lines[1].range], "Div", nil)

        XCTAssertNil(result.reason)
        XCTAssertEqual(tags(document), "Div:1 Div:0")
        XCTAssertEqual(kinds(tree.roots[0]), "Div(mcid1,mcid0)")
    }

    func test_looseContentInsideAnOpenLayerKeepsTheLayerBalanced() throws {
        let content = "/OC <</Layer 1>> BDC BT /F1 11 Tf 72 700 Td (Inside) Tj ET EMC\n"
        let document = try open(make([content]))
        let before = drawing(document)
        let tree = StructureTree.create(document)

        XCTAssertNil(try tree.tagSelection(0, [TextRange(0, 6)], "P", nil).reason)

        XCTAssertEqual(tags(document), "OC P:0")
        XCTAssertEqual(drawing(document), before)
        XCTAssertTrue(AccessKit.isBalanced(document, 0))
    }

    func test_contentOfALaterStreamIsTaggedThere() throws {
        let streams = ["BT /F1 11 Tf 72 700 Td (Head) Tj ET\n", "BT /F1 11 Tf 72 650 Td (Tail) Tj ET\n"]
        let document = try open(make(streams))
        let before = drawing(document)
        let tree = StructureTree.create(document)
        let parts = TagSession.streams(document, document.pages[0])
        let first = try document.data(parts[0])
        let tail = try XCTUnwrap(TextPage.create(document, document.pages[0]).lines.first { $0.text == "Tail" }).range

        XCTAssertNil(try tree.tagSelection(0, [tail], "P", nil).reason)

        XCTAssertEqual(try document.data(parts[0]), first)
        XCTAssertEqual(tags(document), "P:0")
        XCTAssertEqual(drawing(document), before)
    }

    func test_formContentAndSharedStreamsAreRefusedForASelection() throws {
        let content = "q 1 0 0 1 0 0 cm /Fm1 Do Q\n"
        let document = try open(make([content]))
        let tree = StructureTree.create(document)
        let all = TextRange(0, TextPage.create(document, document.pages[0]).chars.count)

        XCTAssertEqual(try tree.tagSelection(0, [all], "P", nil).reason, TagContent.formContent)
        XCTAssertNil(try tree.tagArea(0, PdfRect(0, 0, 612, 792), "P", nil).reason)

        let shared = try open(make([words], pages: 2))
        XCTAssertEqual(try StructureTree.create(shared).tagArea(0, PdfRect(0, 0, 612, 792), "P", nil).reason, TagContent.sharedStream)
    }

    func test_aTypeThatCannotHoldContentOrFitItsParentIsRefused() throws {
        let cases = [("TR", TagRules.needsTableOrPart), ("Table", TagRules.noContent), ("Link", TagRules.linkObject), ("Nonsense", TagRules.unmapped)]
        for (type, reason) in cases {
            let document = try open(make([words]))
            let tree = StructureTree.create(document)
            let before = document.pages[0].contents()

            XCTAssertEqual(try tree.tagArea(0, PdfRect(0, 0, 612, 792), type, nil).reason, reason)
            XCTAssertEqual(document.pages[0].contents(), before)
        }
    }

    func test_aParentOrElementOutsideTheTreeIsRefused() throws {
        let document = try TaggedFile.open()
        let tree = try XCTUnwrap(StructureTree.read(document))

        XCTAssertEqual(try tree.tagArea(0, PdfRect(0, 0, 612, 792), "P", StructElement("Div")).reason, TagContent.notInTree)
        XCTAssertEqual(tree.markAsArtifact(StructElement("P")), TagContent.notInTree)
    }

    func test_boxesFollowWhatTheSequencesDraw() throws {
        let document = try TaggedFile.open()
        let tree = try XCTUnwrap(StructureTree.read(document))

        let body = tree.boxes(try XCTUnwrap(AccessKit.find(tree, "P")))
        let figure = tree.boxes(try XCTUnwrap(AccessKit.find(tree, "Figure")))
        let all = tree.boxes(tree.roots[0])

        XCTAssertEqual(body.boxes.count, 1)
        let box = body.boxes[0].rect
        XCTAssertTrue(box.left > 71 && box.left < 73)
        XCTAssertTrue(box.bottom < 670 && box.top > 670 && box.right > 110)
        XCTAssertEqual(figure.boxes.count, 1)
        XCTAssertEqual(figure.boxes[0].rect, PdfRect(72, 600, 122, 650))
        XCTAssertEqual(all.boxes.count, 3)
        XCTAssertFalse(all.isCapped)
        XCTAssertTrue(all.boxes.allSatisfy { $0.pageIndex == 0 })
    }

    func test_boxesIncludeFormsDrawnInsideASequenceAndAnnotationRects() throws {
        let content = "/P <</MCID 0>> BDC /Fm1 Do EMC"
        let document = try open(make([content], tree("<</Type /StructElem /S /P /P PARENT /Pg PAGE /K 0>>"), structure: true))
        let tree = try XCTUnwrap(StructureTree.read(document))
        let annot = PdfDictionary()
        annot["Type"] = PdfName("Annot")
        annot["Subtype"] = PdfName("Link")
        annot["Rect"] = PdfRect(10, 20, 110, 40).toArray()
        let annotation = try document.add(annot)
        let link = StructElement("Link")
        link.pageIndex = 0
        try tree.add(tree.roots[0], link)
        try tree.add(link, StructObject(0, annotation))

        let boxes = tree.boxes(tree.roots[0]).boxes

        XCTAssertEqual(boxes.count, 2)
        XCTAssertTrue(boxes[0].rect.left > 299 && boxes[0].rect.left < 301)
        XCTAssertEqual(boxes[1].rect, PdfRect(10, 20, 110, 40))
    }

    func test_boxesStopAtTheCap() throws {
        let content = (0..<600).map { "/Span <</MCID \($0)>> BDC BT /F1 6 Tf 10 \(700 - $0) Td (x) Tj ET EMC\n" }.joined()
        let document = try open(make([content], tree("<</Type /StructElem /S /P /P PARENT /Pg PAGE>>"), structure: true))
        let tree = try XCTUnwrap(StructureTree.read(document))
        for i in 0..<600 { try tree.add(tree.roots[0].children[0], StructContent(0, i)) }

        let boxes = tree.boxes(tree.roots[0])

        XCTAssertEqual(boxes.boxes.count, 500)
        XCTAssertTrue(boxes.isCapped)
    }
}
