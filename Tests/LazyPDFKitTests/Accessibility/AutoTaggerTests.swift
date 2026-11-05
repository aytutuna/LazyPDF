import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Accessibility/AutoTaggerTests.cs: the same cases, except that
// RoundTripKeepsEverySequenceInTheParentTree does not compare the words PdfPig reads from the saved file before and after
// (the rest of it is there), and the cancelled tag runs in a task that is cancelled before it starts.

final class AutoTaggerTests: XCTestCase {
    private static func shape(_ e: StructElement) -> String {
        e.type + (e.children.isEmpty ? "" : "(" + e.children.map { shape($0) }.joined(separator: ",") + ")")
    }

    func test_reportPageGetsHeadingsParagraphsListTableAndFigure() throws {
        let document = try PdfDocument.open(AccessKit.report(1))
        let result = try AutoTagger.tag(document)

        XCTAssertEqual([result.pages, result.skippedPages, result.headings, result.paragraphs, result.lists, result.tables, result.figures],
                       [1, 0, 1, 3, 1, 1, 1])
        let tree = try XCTUnwrap(StructureTree.read(document))
        XCTAssertEqual(
            Self.shape(tree.roots[0]),
            "Document(P,H1,P,P,L(LI(Lbl,LBody),LI(Lbl,LBody),LI(Lbl,LBody)),Table(TR(TH,TH,TH),TR(TD,TD,TD),TR(TD,TD,TD)),Figure)")
        XCTAssertTrue(document.isTagged)
        XCTAssertEqual(document.name(document.pages[0].dictionary, "Tabs"), "S")
    }

    func test_roundTripKeepsEverySequenceInTheParentTree() throws {
        let document = try PdfDocument.open(AccessKit.report(3))
        let before = (0..<3).map { AccessKit.plain(document, $0) }
        _ = try AutoTagger.tag(document)

        for rewrite in [false, true] {
            let bytes = rewrite ? try document.saveRewrite() : try document.saveIncremental()
            let again = try PdfDocument.open(bytes)
            let tree = try XCTUnwrap(StructureTree.read(again))
            XCTAssertFalse(tree.isTruncated)
            for p in 0..<3 {
                XCTAssertEqual(before[p], AccessKit.plain(again, p))
                XCTAssertTrue(AccessKit.isBalanced(again, p))

                let inContent = AccessKit.sequences(again, p).filter { $0.mcid >= 0 }
                let inTree = tree.contents.filter { $0.pageIndex == p }
                XCTAssertEqual(inContent.map { $0.mcid }.sorted(), inTree.map { $0.mcid }.sorted())
                XCTAssertEqual(inContent.count, Set(inContent.map { $0.mcid }).count)

                let key = try XCTUnwrap(again.integer(again.pages[p].dictionary, "StructParents"))
                for (tag, mcid) in inContent {
                    let owner = try XCTUnwrap(tree.elementFor(key, mcid))
                    XCTAssertEqual(tag, owner.type)
                    XCTAssertTrue(owner.kids.contains { kid in
                        guard let content = kid as? StructContent else { return false }
                        return content.pageIndex == p && content.mcid == mcid
                    })
                }
            }
        }
    }

    func test_headerFooterAndPageNumbersBecomeArtifacts() throws {
        let document = try PdfDocument.open(AccessKit.report(3))
        _ = try AutoTagger.tag(document)

        let read = ReadingOrder.export(document)
        XCTAssertFalse(read.contains("ACME"))
        XCTAssertFalse(read.contains("Page 2"))
        XCTAssertTrue(read.contains("Introduction"))
        let content = ContentParser.parse(document.pages[1].contents())
        let artifacts = content.filter { $0.operator == "BMC" && ($0.operands.first as? PdfName)?.value == "Artifact" }
        XCTAssertEqual(artifacts.count, 3)
    }

    func test_rotatedPagesAreTagged() throws {
        let document = try PdfDocument.open(AccessKit.build(3, AccessKit.reportPage, pageEntries: "/Rotate 90"))
        let before = AccessKit.plain(document, 1)
        let result = try AutoTagger.tag(document)

        XCTAssertEqual([result.pages, result.headings, result.lists, result.tables], [3, 3, 3, 3])
        XCTAssertEqual(before, AccessKit.plain(document, 1))
    }

    func test_aSinglePageKeepsItsHeaderButNotItsNumber() throws {
        let document = try PdfDocument.open(AccessKit.report(1))
        _ = try AutoTagger.tag(document)

        let read = ReadingOrder.export(document)
        XCTAssertTrue(read.contains("ACME Quarterly Report"))
        XCTAssertFalse(read.contains("Page 1"))
    }

    func test_headingLevelsFollowSizeAndNeverSkip() throws {
        let page: (Int) -> String = { _ in
            AccessKit.text(72, 720, "Chapter One", 24, bold: true) +
            AccessKit.text(72, 690, "Section A", 16, bold: true) +
            AccessKit.text(72, 660, "Body text goes here and runs long enough to be the body.") +
            AccessKit.text(72, 640, "More body text follows on the next line of the page.") +
            AccessKit.text(72, 600, "Detail", 11, bold: true) +
            AccessKit.text(72, 580, "Body text again, a sentence that is not bold at all.")
        }
        let document = try PdfDocument.open(AccessKit.build(1, page))
        _ = try AutoTagger.tag(document)

        let types = try XCTUnwrap(StructureTree.read(document)).elements.map { $0.type }.filter { $0.hasPrefix("H") }
        XCTAssertEqual(types, ["H1", "H2", "H3"])
    }

    func test_numberedListsAreRecognised() throws {
        let page: (Int) -> String = { _ in
            AccessKit.text(72, 700, "1. Open the file") + AccessKit.text(72, 686, "2. Choose a name") + AccessKit.text(72, 672, "3. Save it") +
            AccessKit.text(72, 600, "Plain text that is not a list at all, only a sentence.")
        }
        let document = try PdfDocument.open(AccessKit.build(1, page))
        let result = try AutoTagger.tag(document)

        XCTAssertEqual(result.lists, 1)
        let list = try XCTUnwrap(StructureTree.read(document)?.elements.first { $0.type == "L" })
        XCTAssertEqual(list.children.count, 3)
        for li in list.children { XCTAssertEqual(li.children.map { $0.type }, ["LBody"]) }
    }

    func test_aSeparateLabelBecomesLbl() throws {
        let page: (Int) -> String = { _ in
            "BT /F1 11 Tf 72 700 Td (1.) Tj 14 0 Td (Open the file) Tj ET BT /F1 11 Tf 72 686 Td (2.) Tj 14 0 Td (Choose a name) Tj ET"
        }
        let document = try PdfDocument.open(AccessKit.build(1, page))
        _ = try AutoTagger.tag(document)

        let list = try XCTUnwrap(StructureTree.read(document)?.elements.first { $0.type == "L" })
        for li in list.children { XCTAssertEqual(li.children.map { $0.type }, ["Lbl", "LBody"]) }
    }

    func test_aLoneNumberedLineIsNotAList() throws {
        let document = try PdfDocument.open(AccessKit.build(1) { _ in AccessKit.text(72, 700, "1. Only one such line in this text") })
        let result = try AutoTagger.tag(document)

        XCTAssertEqual(result.lists, 0)
        XCTAssertEqual(result.paragraphs, 1)
    }

    func test_rowsOfUnequalWidthAreNotATable() throws {
        let page: (Int) -> String = { _ in
            AccessKit.text(72, 700, "Aa") + AccessKit.text(222, 700, "Bb") + AccessKit.text(372, 700, "Cc") +
            AccessKit.text(72, 684, "Dd") + AccessKit.text(222, 684, "Ee") +
            AccessKit.text(72, 668, "Ff") + AccessKit.text(222, 668, "Gg") + AccessKit.text(372, 668, "Hh")
        }
        let document = try PdfDocument.open(AccessKit.build(1, page))
        let result = try AutoTagger.tag(document)

        XCTAssertEqual(result.tables, 0)
        let elements = try XCTUnwrap(StructureTree.read(document)).elements
        XCTAssertFalse(elements.contains { $0.type == "Table" || $0.type == "TR" })
    }

    func test_figuresWithoutAltAreReported() throws {
        let document = try PdfDocument.open(AccessKit.report(2))
        let result = try AutoTagger.tag(document)

        XCTAssertEqual(result.figuresWithoutAlt.count, 2)
        let tree = try XCTUnwrap(StructureTree.read(document))
        for figure in result.figuresWithoutAlt {
            let element = try XCTUnwrap(tree.elements.first { $0.reference?.number == figure.reference.number })
            XCTAssertEqual(element.type, "Figure")
            XCTAssertNil(element.alt)
            XCTAssertEqual(figure.pageIndex, element.pageIndex)
        }
    }

    func test_aTaggedDocumentIsLeftAlone() throws {
        let document = try PdfDocument.open(TaggedFile.build())
        let result = try AutoTagger.tag(document)

        XCTAssertTrue(result.alreadyTagged)
        XCTAssertTrue(document.changedObjects().isEmpty)
    }

    func test_languageIsSetOnlyWhenMissing() throws {
        let document = try PdfDocument.open(AccessKit.report(1))
        _ = try AutoTagger.tag(document, AutoTagOptions("tr-TR"))
        XCTAssertEqual(PdfText.read(document, document.catalog, "Lang"), "tr-TR")

        let other = try PdfDocument.open(AccessKit.build(1, AccessKit.reportPage, catalog: "/Lang (de)"))
        _ = try AutoTagger.tag(other, AutoTagOptions("tr-TR"))
        XCTAssertEqual(PdfText.read(other, other.catalog, "Lang"), "de")
    }

    func test_existingArtifactsAndOptionalContentAreKept() throws {
        let page: (Int) -> String = { _ in
            "/Artifact BMC 0.5 g 0 0 612 20 re f EMC\n" +
            "/OC /MC0 BDC " + AccessKit.text(72, 700, "Layered text inside optional content") + "EMC\n" +
            "/Artifact <</Type /Pagination>> BDC " + AccessKit.text(72, 760, "Stamped words") + "EMC\n" +
            AccessKit.text(72, 650, "Ordinary text of the page, a full sentence.")
        }
        let document = try PdfDocument.open(AccessKit.build(1, page))
        let before = AccessKit.plain(document, 0)
        _ = try AutoTagger.tag(document)

        XCTAssertEqual(before, AccessKit.plain(document, 0))
        XCTAssertTrue(AccessKit.isBalanced(document, 0))
        let read = ReadingOrder.export(document)
        XCTAssertTrue(read.contains("Layered text inside optional content"))
        XCTAssertTrue(read.contains("Ordinary text"))
        XCTAssertFalse(read.contains("Stamped"))
        let sequences = AccessKit.sequences(document, 0)
        XCTAssertEqual(sequences.filter { $0.tag == "Artifact" }.count, 2)
        XCTAssertTrue(sequences.contains { $0.tag == "OC" })
    }

    func test_contentSplitOverSeveralStreamsStaysSplit() throws {
        let document = try PdfDocument.open(AccessKit.build(1) { _ in AccessKit.text(72, 700, "First stream opens the page with a sentence.") })
        let page = document.pages[0]

        let second = try document.add(PdfStream(PdfDictionary(), data: TestPdf.latin(AccessKit.text(72, 300, "Text from the second stream of the page."))))
        page.dictionary["Contents"] = PdfArray([try XCTUnwrap(page.dictionary["Contents"]), second])
        let before = AccessKit.plain(document, 0)

        let result = try AutoTagger.tag(document)

        XCTAssertEqual(result.pages, 1)
        XCTAssertEqual((document.resolve(page.dictionary["Contents"]) as? PdfArray)?.items.count, 2)
        XCTAssertEqual(before, AccessKit.plain(document, 0))
        XCTAssertTrue(AccessKit.isBalanced(document, 0))
        XCTAssertTrue(ReadingOrder.export(document).contains("second stream"))
    }

    func test_anOperatorInALaterStreamThanItsOperandsIsJoined() throws {
        let document = try PdfDocument.open(AccessKit.build(1) { _ in "BT /F1 12 Tf 72 700 Td (Split text of a sentence)" })
        let page = document.pages[0]
        let second = try document.add(PdfStream(PdfDictionary(), data: TestPdf.latin(" Tj ET\n" + AccessKit.text(72, 600, "A later sentence."))))
        page.dictionary["Contents"] = PdfArray([try XCTUnwrap(page.dictionary["Contents"]), second])
        let before = AccessKit.plain(document, 0)

        let result = try AutoTagger.tag(document)

        XCTAssertEqual(result.pages, 1)
        XCTAssertTrue(page.dictionary["Contents"] is PdfReference)
        XCTAssertEqual(before, AccessKit.plain(document, 0))
        XCTAssertEqual(AccessKit.sequences(document, 0).filter { $0.mcid >= 0 }.count, 2)
        XCTAssertTrue(ReadingOrder.export(document).contains("Split text of a sentence"))
    }

    func test_textInAFormIsTaggedAroundItsDo() throws {
        let document = try PdfDocument.open(AccessKit.build(1,
            { _ in AccessKit.text(72, 700, "Page level words in a sentence.") + "/Fm1 Do\n" },
            more: { pdf in
                pdf.stream(8, "/Type /XObject /Subtype /Form /BBox [0 0 612 792] /Resources <</Font <</F1 5 0 R>>>>", AccessKit.text(72, 500, "Words drawn by a form object."))
            }))
        let page = document.pages[0]
        try XCTUnwrap(document.dict(page.resources, "XObject"))["Fm1"] = PdfReference(8, 0)
        let before = AccessKit.plain(document, 0)

        _ = try AutoTagger.tag(document)

        XCTAssertEqual(before, AccessKit.plain(document, 0))
        XCTAssertTrue(ReadingOrder.export(document).contains("Words drawn by a form object."))
        XCTAssertTrue(AccessKit.isBalanced(document, 0))
    }

    func test_aSharedContentStreamLeavesBothPagesUntagged() throws {
        let bytes = AccessKit.build(2, { _ in "" }, more: nil)
        let document = try PdfDocument.open(bytes)
        document.pages[1].dictionary["Contents"] = try XCTUnwrap(document.pages[0].dictionary["Contents"])
        try XCTUnwrap(document.resolve(document.pages[0].dictionary["Contents"]) as? PdfStream).data = TestPdf.latin(AccessKit.text(72, 700, "Shared words."))

        let result = try AutoTagger.tag(document)

        XCTAssertEqual([result.pages, result.skippedPages], [0, 2])
        XCTAssertFalse(document.isTagged)
    }

    func test_brokenContentDoesNotStopTheTagger() throws {
        let page: (Int) -> String = { _ in
            "q q q 1 0 0 1 0 0 cm\n" + AccessKit.text(72, 700, "Text after open saves, one sentence.") + "EMC EMC Q\n/Span BMC " +
            AccessKit.text(72, 650, "Text in marked content that never ends.") + "[(unclosed"
        }
        let document = try PdfDocument.open(AccessKit.build(1, page))
        let before = AccessKit.plain(document, 0)
        let result = try AutoTagger.tag(document)

        XCTAssertEqual(before, AccessKit.plain(document, 0))
        XCTAssertEqual(result.pages + result.skippedPages, 1)
    }

    func test_blankAndEmptyPagesAreTaggedWithoutContent() throws {
        let document = try PdfDocument.open(AccessKit.build(2) { i in i == 0 ? "" : "0.9 g 0 0 612 792 re f\n" })
        let result = try AutoTagger.tag(document)

        XCTAssertEqual([result.pages, result.skippedPages], [2, 0])
        XCTAssertTrue(document.isTagged)
        XCTAssertEqual(result.artifacts, 1)
    }

    func test_linksAndWidgetsGetElementsWithObjectReferences() throws {
        let page = AccessKit.text(72, 700, "Visit the Lazy site for more.") + AccessKit.text(72, 600, "Name:")
        let document = try PdfDocument.open(AccessKit.build(1, { _ in page }, pageEntries: "/Annots [8 0 R 9 0 R]", more: { pdf in
            pdf.obj(8, "<</Type /Annot /Subtype /Link /Rect [114 695 138 711] /Border [0 0 0] /A <</S /URI /URI (https://example.org/)>>>>")
            pdf.obj(9, "<</Type /Annot /Subtype /Widget /FT /Tx /T (name) /Rect [120 590 220 612]>>")
        }))
        _ = try AutoTagger.tag(document)

        let tree = try XCTUnwrap(StructureTree.read(document))
        let link = try XCTUnwrap(tree.elements.first { $0.type == "Link" })
        XCTAssertEqual(link.alt, "Lazy")
        XCTAssertEqual(link.kids.count, 1)
        XCTAssertEqual((link.kids[0] as? StructObject)?.target.number, 8)
        let annotation = try XCTUnwrap(document.get(8) as? PdfDictionary)
        XCTAssertEqual(PdfText.read(document, annotation, "Contents"), "Lazy")
        let form = try XCTUnwrap(tree.elements.first { $0.type == "Form" })
        XCTAssertEqual(form.kids.count, 1)
        XCTAssertEqual((form.kids[0] as? StructObject)?.target.number, 9)
        XCTAssertEqual(tree.elementFor(try XCTUnwrap(document.integer(annotation, "StructParent")), -1)?.type, "Link")
    }

    func test_aLinkWithoutTextUnderItFallsBackToItsAddress() throws {
        let document = try PdfDocument.open(AccessKit.build(1, { _ in "" }, pageEntries: "/Annots [8 0 R]", more: { pdf in
            pdf.obj(8, "<</Type /Annot /Subtype /Link /Rect [10 10 50 50] /A <</S /URI /URI (https://example.org/)>>>>")
        }))
        _ = try AutoTagger.tag(document)

        XCTAssertEqual(try XCTUnwrap(StructureTree.read(document)).elements.first { $0.type == "Link" }?.alt, "https://example.org/")
    }

    func test_manyPagesGetAWholeParentTree() throws {
        let document = try PdfDocument.open(AccessKit.build(70) { i in AccessKit.text(72, 700, "Page body \(i) with a sentence of words.") })
        let result = try AutoTagger.tag(document)

        XCTAssertEqual(result.pages, 70)
        let again = try AccessKit.reopen(document, rewrite: true)
        let tree = try XCTUnwrap(StructureTree.read(again))
        XCTAssertEqual(tree.parentTree.count, 70)
        XCTAssertEqual(tree.contents.count, 70)
    }

    func test_anEncryptedFileIsTaggedAndSavedEncrypted() throws {
        let plain = try PdfDocument.open(AccessKit.report(2))
        let id = [UInt8](repeating: 0, count: 16)
        let security = PdfSecurity.create(userPassword: "user", ownerPassword: "owner", permissions: .all, strength: .aes256, firstId: id)
        let encrypted = try plain.saveRewrite(PdfSaveOptions(security: security, documentId: id))

        let document = try PdfDocument.open(encrypted, password: "user")
        let result = try AutoTagger.tag(document)
        let saved = try document.saveIncremental()

        XCTAssertEqual(result.pages, 2)
        let again = try PdfDocument.open(saved, password: "user")
        XCTAssertTrue(again.isTagged)
        XCTAssertTrue(ReadingOrder.export(again).contains("Introduction"))
    }

    func test_cancellationIsHonoured() async throws {
        let document = try PdfDocument.open(AccessKit.report(3))
        let task = Task { () throws -> AutoTagResult in
            while !Task.isCancelled { await Task.yield() }
            return try AutoTagger.tag(document)
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected a cancellation")
        } catch is CancellationError {
        }
        XCTAssertFalse(document.isTagged)
    }

    func test_writingTheTreeMakesNoSecondTreeWhenTaggedTwice() throws {
        let document = try PdfDocument.open(AccessKit.report(1))
        _ = try AutoTagger.tag(document)
        let objects = document.objectNumbers.count

        XCTAssertTrue(try AutoTagger.tag(document).alreadyTagged)
        XCTAssertEqual(objects, document.objectNumbers.count)
    }
}
