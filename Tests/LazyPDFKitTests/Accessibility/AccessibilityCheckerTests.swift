import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Accessibility/AccessibilityCheckerTests.cs: the same cases. A [Theory] is one test that
// loops over its cases; the cancelled check runs in a task that is cancelled before it starts.

final class AccessibilityCheckerTests: XCTestCase {
    private static func check(_ edit: ((inout [Int: String]) -> Void)? = nil, catalog: String = "/Lang (en-US)", content: String? = nil) throws -> AccessibilityReport {
        try AccessibilityChecker.check(PdfDocument.open(TaggedFile.build(edit, catalog: catalog, content: content ?? TaggedFile.content)))
    }

    private func assertRule(_ report: AccessibilityReport, _ rule: AccessibilityRule, _ status: AccessibilityStatus, file: StaticString = #filePath, line: UInt = #line) {
        let item = report[rule]
        XCTAssertTrue(item.status == status, "\(rule): \(item.status) - \(item.message)", file: file, line: line)
        XCTAssertFalse(DotNetText.isNullOrWhiteSpace(item.message), file: file, line: line)
        XCTAssertEqual(AccessibilityText.name(rule), item.name, file: file, line: line)
    }

    func test_aGoodTaggedFilePassesEverythingButTheTitleAndContrast() throws {
        let report = try Self.check()

        for item in report.items {
            let expected: AccessibilityStatus
            switch item.rule {
            case .title: expected = .failed
            case .contrast: expected = .needsPerson
            default: expected = .passed
            }
            XCTAssertTrue(item.status == expected, "\(item.rule): \(item.status) - \(item.message)")
        }
        XCTAssertEqual(report.items.count, AccessibilityRule.allCases.count)
        XCTAssertEqual([report.failed, report.needsPerson], [1, 1])
    }

    func test_anUntaggedFileFailsTheBasicsAndLeavesStructureToAPerson() throws {
        let report = try AccessibilityChecker.check(PdfDocument.open(AccessKit.report(1)))

        assertRule(report, .tagged, .failed)
        assertRule(report, .title, .failed)
        assertRule(report, .language, .failed)
        assertRule(report, .taggedContent, .needsPerson)
        for rule in [AccessibilityRule.figureAlt, .tableHeaders, .listStructure, .headingOrder, .links] {
            assertRule(report, rule, .needsPerson)
        }
        assertRule(report, .searchable, .passed)
        assertRule(report, .encoding, .passed)
    }

    func test_aSuspectMarkFailsTheTaggedRule() throws {
        let document = try PdfDocument.open(TaggedFile.build())
        assertRule(try AccessibilityChecker.check(document), .tagged, .passed)

        try XCTUnwrap(document.dict(document.catalog, "MarkInfo"))["Suspects"] = PdfBoolean(true)
        assertRule(try AccessibilityChecker.check(document), .tagged, .failed)
    }

    func test_titleAndLanguageFixesMakeTheirRulesPass() throws {
        let document = try PdfDocument.open(TaggedFile.build(catalog: ""))
        let report = try AccessibilityChecker.check(document)
        XCTAssertEqual(report[.title].fix, .setTitle)
        XCTAssertEqual(report[.language].fix, .setLanguage)

        XCTAssertTrue(try AccessibilityChecker.fix(document, .setTitle, "Annual plan"))
        XCTAssertTrue(try AccessibilityChecker.fix(document, .setLanguage, "tr-TR"))

        let again = try AccessKit.reopen(document, rewrite: false)
        let fixedReport = try AccessibilityChecker.check(again)
        assertRule(fixedReport, .title, .passed)
        assertRule(fixedReport, .language, .passed)
        XCTAssertEqual(DocumentMetadata.read(again).title, "Annual plan")
    }

    func test_aTitleThatTheWindowDoesNotShowOffersTheShowFix() throws {
        let document = try PdfDocument.open(TaggedFile.build())
        var metadata = DocumentMetadata.read(document)
        metadata.title = "Has a title"
        try metadata.write(document)

        let item = try AccessibilityChecker.check(document)[.title]
        XCTAssertEqual(item.status, .failed)
        XCTAssertEqual(item.fix, .showTitle)
        XCTAssertTrue(try AccessibilityChecker.fix(document, .showTitle))
        XCTAssertFalse(try AccessibilityChecker.fix(document, .showTitle))
        assertRule(try AccessibilityChecker.check(document), .title, .passed)
    }

    func test_fixesRefuseMissingValues() throws {
        let document = try PdfDocument.open(TaggedFile.build())

        XCTAssertThrowsError(try AccessibilityChecker.fix(document, .setTitle, "  ")) { XCTAssertTrue($0 is ArgumentException) }
        XCTAssertThrowsError(try AccessibilityChecker.fix(document, .setLanguage, "not a tag")) { XCTAssertTrue($0 is ArgumentException) }
        XCTAssertThrowsError(try AccessibilityChecker.fix(document, .setLanguage)) { XCTAssertTrue($0 is ArgumentException) }
        XCTAssertFalse(try AccessibilityChecker.fix(document, .none))
        XCTAssertFalse(try AccessibilityChecker.fix(document, .showTitle))
    }

    func test_tabOrderFailsOnPagesWithAnnotationsUntilFixed() throws {
        let document = try PdfDocument.open(AccessKit.build(2, { _ in "" }, pageEntries: "", more: nil))
        let annotation = PdfDictionary()
        annotation["Subtype"] = PdfName("Text")
        annotation["Rect"] = PdfArray([PdfNumber(0), PdfNumber(0), PdfNumber(9), PdfNumber(9)])
        let reference = try document.add(annotation)
        document.pages[1].dictionary["Annots"] = PdfArray([reference])

        let item = try AccessibilityChecker.check(document)[.tabOrder]
        XCTAssertEqual(item.status, .failed)
        XCTAssertEqual(item.fix, .setTabOrder)
        XCTAssertEqual(item.where.count, 1)
        XCTAssertEqual(item.where[0].pageIndex, 1)
        XCTAssertTrue(item.message.contains("page 2"))

        XCTAssertTrue(try AccessibilityChecker.fix(document, .setTabOrder))
        XCTAssertFalse(try AccessibilityChecker.fix(document, .setTabOrder))
        XCTAssertEqual(document.name(document.pages[1].dictionary, "Tabs"), "S")
        XCTAssertNil(document.name(document.pages[0].dictionary, "Tabs"))
        assertRule(try AccessibilityChecker.check(document), .tabOrder, .passed)
    }

    func test_longDocumentsNeedBookmarks() throws {
        let page: (Int) -> String = { _ in AccessKit.text(72, 700, "A page.") }
        assertRule(try AccessibilityChecker.check(PdfDocument.open(AccessKit.build(20, page))), .bookmarks, .passed)
        assertRule(try AccessibilityChecker.check(PdfDocument.open(AccessKit.build(21, page))), .bookmarks, .failed)

        let outlined = AccessKit.build(21, page, catalog: "/Outlines 48 0 R", more: { pdf in
            pdf.obj(48, "<</Type /Outlines /First 49 0 R /Last 49 0 R /Count 1>>")
            pdf.obj(49, "<</Title (Start) /Parent 48 0 R /Dest [3 0 R /Fit]>>")
        })
        assertRule(try AccessibilityChecker.check(PdfDocument.open(outlined)), .bookmarks, .passed)
    }

    func test_securityMustAllowAccessibilityExtraction() throws {
        let cases: [(PdfPermissions, AccessibilityStatus)] = [(.all, .passed), ([.print, .copy], .failed)]
        for (permissions, expected) in cases {
            let plain = try PdfDocument.open(AccessKit.report(1))
            let id = [UInt8](repeating: 0, count: 16)
            let security = PdfSecurity.create(userPassword: "", ownerPassword: "owner", permissions: permissions, strength: .aes128, firstId: id)
            let document = try PdfDocument.open(try plain.saveRewrite(PdfSaveOptions(security: security, documentId: id)))

            assertRule(try AccessibilityChecker.check(document), .security, expected)
        }
    }

    func test_imageOnlyPagesAreNamed() throws {
        let bytes = AccessKit.build(2) { i in i == 1 ? "q 600 0 0 700 0 0 cm /Im1 Do Q" : AccessKit.text(72, 700, "Some text.") }
        let item = try AccessibilityChecker.check(PdfDocument.open(bytes))[.searchable]

        XCTAssertEqual(item.status, .failed)
        XCTAssertEqual(item.where.count, 1)
        XCTAssertEqual(item.where[0].pageIndex, 1)
    }

    func test_aFontThatGivesNoTextIsFound() throws {
        let bytes = AccessKit.build(1, { _ in "BT /F3 12 Tf 72 700 Td (ABC) Tj ET" }, more: { pdf in
            pdf.obj(8, "<</Type /Font /Subtype /Type1 /BaseFont /Odd /FirstChar 65 /LastChar 67 /Widths [500 500 500] /Encoding <</Type /Encoding /Differences [65 /g1 /g2 /g3]>>>>")
        }, fontEntries: "/F3 8 0 R")
        let item = try AccessibilityChecker.check(PdfDocument.open(bytes))[.encoding]

        XCTAssertEqual(item.status, .failed)
        XCTAssertTrue(item.message.contains("Fonts that give no text: 1"))
    }

    func test_contentOutsideTheTagsIsFound() throws {
        let item = try Self.check(content: TaggedFile.content + AccessKit.text(72, 500, "Loose words"))[.taggedContent]
        XCTAssertEqual(item.status, .failed)

        let unknown = try Self.check(content: TaggedFile.content + "/P <</MCID 9>> BDC " + AccessKit.text(72, 500, "Unlisted") + " EMC")[.taggedContent]
        XCTAssertEqual(unknown.status, .failed)

        let artifact = try Self.check(content: TaggedFile.content + "/Artifact BMC 0 0 10 10 re f EMC")[.taggedContent]
        XCTAssertEqual(artifact.status, .passed)

        let rule = try Self.check(content: TaggedFile.content + "0 0 10 10 re f")[.taggedContent]
        XCTAssertEqual(rule.status, .failed)
    }

    func test_figuresNeedAltTextAndSayWhere() throws {
        let report = try Self.check { o in o[12] = "<</Type /StructElem /S /Figure /P 9 0 R /Pg 3 0 R /K 2>>" }
        let item = report[.figureAlt]

        XCTAssertEqual(item.status, .failed)
        XCTAssertEqual(item.where.count, 1)
        let place = item.where[0]
        XCTAssertEqual(place.pageIndex, 0)
        XCTAssertEqual(place.element?.number, 12)
        XCTAssertTrue(item.message.contains("page 1"))
        assertRule(try Self.check { o in o[12] = "<</Type /StructElem /S /Figure /P 9 0 R /Pg 3 0 R /K 2 /ActualText (x)>>" }, .figureAlt, .passed)
    }

    func test_headingsMustStartAtOneAndNotSkip() throws {
        assertRule(try Self.check { o in o[11] = "<</Type /StructElem /S /H3 /P 9 0 R /Pg 3 0 R /K 1>>" }, .headingOrder, .failed)
        assertRule(try Self.check { o in o[10] = "<</Type /StructElem /S /H2 /P 9 0 R /Pg 3 0 R /K 0>>" }, .headingOrder, .failed)
        assertRule(try Self.check { o in o[11] = "<</Type /StructElem /S /H /P 9 0 R /Pg 3 0 R /K 1>>" }, .headingOrder, .failed)
        assertRule(try Self.check { o in o[11] = "<</Type /StructElem /S /H2 /P 9 0 R /Pg 3 0 R /K 1>>" }, .headingOrder, .passed)
        assertRule(try Self.check { o in o[10] = "<</Type /StructElem /S /Heading /P 9 0 R /Pg 3 0 R /K 0>>" }, .headingOrder, .passed)
    }

    func test_customTypesMustMapToStandardOnes() throws {
        assertRule(try Self.check { o in o[11] = "<</Type /StructElem /S /Weird /P 9 0 R /Pg 3 0 R /K 1>>" }, .roleMap, .failed)
        assertRule(try Self.check { o in o[11] = "<</Type /StructElem /S /Unmapped /P 9 0 R /Pg 3 0 R /K 1>>" }, .roleMap, .failed)
        assertRule(try Self.check { o in o[11] = "<</Type /StructElem /S /Heading /P 9 0 R /Pg 3 0 R /K 1>>" }, .roleMap, .passed)
    }

    private static func withBlock(_ o: inout [Int: String], _ kind: String, _ kids: [String], _ objects: [String]) {
        o[9] = "<</Type /StructElem /S /Document /P 8 0 R /K [10 0 R 11 0 R 12 0 R 14 0 R]>>"
        o[14] = "<</Type /StructElem /S /\(kind) /P 9 0 R /Pg 3 0 R /K [\(kids.joined(separator: " "))]>>"
        for i in 0..<objects.count { o[20 + i] = objects[i] }
    }

    private static func elem(_ type: String, _ parent: String, _ kids: String = "") -> String {
        "<</Type /StructElem /S /\(type) /P \(parent) 0 R /Pg 3 0 R \(kids)>>"
    }

    func test_listsNeedItemsLabelsAndBodiesInPlace() throws {
        let elem = Self.elem

        assertRule(try Self.check { o in Self.withBlock(&o, "L", ["20 0 R"], [elem("P", "14", "")]) }, .listStructure, .failed)
        assertRule(try Self.check { o in Self.withBlock(&o, "L", ["20 0 R"], [elem("LI", "14", "/K [21 0 R]"), elem("P", "20", "")]) }, .listStructure, .failed)
        assertRule(try Self.check { o in
            Self.withBlock(&o, "L", ["20 0 R"], [elem("LI", "14", "/K [21 0 R 22 0 R]"), elem("Lbl", "20", ""), elem("LBody", "20", "")])
        }, .listStructure, .passed)
        assertRule(try Self.check { o in Self.withBlock(&o, "LBody", ["20 0 R"], [elem("P", "14", "")]) }, .listStructure, .failed)
    }

    func test_tablesNeedRowsOfCellsOfOneWidthAndHeaders() throws {
        let elem = Self.elem
        let regular = [
            elem("TR", "14", "/K [22 0 R 23 0 R]"), elem("TR", "14", "/K [24 0 R 25 0 R]"),
            elem("TH", "20", ""), elem("TH", "20", ""), elem("TD", "21", ""), elem("TD", "21", ""),
        ]
        let good = try Self.check { o in Self.withBlock(&o, "Table", ["20 0 R", "21 0 R"], regular) }
        assertRule(good, .tableStructure, .passed)
        assertRule(good, .tableHeaders, .passed)

        var noHeaders = regular
        noHeaders[2] = elem("TD", "20", "")
        noHeaders[3] = elem("TD", "20", "")
        let plain = try Self.check { o in Self.withBlock(&o, "Table", ["20 0 R", "21 0 R"], noHeaders) }
        assertRule(plain, .tableStructure, .passed)
        assertRule(plain, .tableHeaders, .failed)

        var ragged = regular
        ragged[1] = elem("TR", "14", "/K [24 0 R]")
        assertRule(try Self.check { o in Self.withBlock(&o, "Table", ["20 0 R", "21 0 R"], ragged) }, .tableStructure, .failed)

        var spanned = ragged
        spanned[4] = "<</Type /StructElem /S /TD /P 21 0 R /Pg 3 0 R /A <</O /Table /ColSpan 2>>>>"
        assertRule(try Self.check { o in Self.withBlock(&o, "Table", ["20 0 R", "21 0 R"], spanned) }, .tableStructure, .passed)

        assertRule(try Self.check { o in Self.withBlock(&o, "Table", ["20 0 R"], [elem("P", "14", "")]) }, .tableStructure, .failed)
        let sections = [elem("TBody", "14", "/K [22 0 R]"), elem("THead", "14", "/K [23 0 R]"), elem("TR", "20", "/K [24 0 R]"), elem("TR", "21", "/K [25 0 R]"), elem("TH", "22", ""), elem("TD", "23", "")]
        assertRule(try Self.check { o in Self.withBlock(&o, "Table", ["20 0 R", "21 0 R"], sections) }, .tableStructure, .passed)
    }

    func test_linksMustBeTaggedAndHaveText() throws {
        func open(_ linkElement: String, _ annotation: String = "/Border [0 0 0]") throws -> PdfDocument {
            try PdfDocument.open(AccessKit.build(1, { _ in TaggedFile.content }, catalog: "/StructTreeRoot 8 0 R /MarkInfo <</Marked true>> /Lang (en)",
                                                 pageEntries: "/StructParents 0 /Tabs /S /Annots [20 0 R]", more: { pdf in
                for (n, body) in TaggedFile.objects().sorted(by: { $0.key < $1.key }) where n != 9 { pdf.obj(n, body) }
                pdf.obj(9, "<</Type /StructElem /S /Document /P 8 0 R /K [10 0 R 11 0 R 12 0 R\(!linkElement.isEmpty ? " 21 0 R" : "")]>>")
                pdf.obj(20, "<</Type /Annot /Subtype /Link /Rect [0 0 9 9] \(annotation) /StructParent 1>>")
                if !linkElement.isEmpty { pdf.obj(21, linkElement) }
            }))
        }

        assertRule(try AccessibilityChecker.check(open("")), .links, .failed)
        assertRule(try AccessibilityChecker.check(open("<</S /Link /P 9 0 R /Pg 3 0 R /K <</Type /OBJR /Pg 3 0 R /Obj 20 0 R>>>>")), .links, .failed)
        assertRule(try AccessibilityChecker.check(open("<</S /Link /P 9 0 R /Pg 3 0 R /Alt (Site) /K <</Type /OBJR /Pg 3 0 R /Obj 20 0 R>>>>")), .links, .passed)
        assertRule(try AccessibilityChecker.check(open("<</S /Link /P 9 0 R /Pg 3 0 R /K <</Type /OBJR /Pg 3 0 R /Obj 20 0 R>>>>", "/Contents (Site)")), .links, .passed)
    }

    func test_formFieldsNeedNamesTooltipsAndTags() throws {
        func open(_ field: String) throws -> PdfDocument {
            try PdfDocument.open(AccessKit.build(1, { _ in TaggedFile.content },
                catalog: "/StructTreeRoot 8 0 R /MarkInfo <</Marked true>> /Lang (en) /AcroForm <</Fields [20 0 R]>>",
                pageEntries: "/StructParents 0 /Tabs /S /Annots [20 0 R]", more: { pdf in
                for (n, body) in TaggedFile.objects().sorted(by: { $0.key < $1.key }) where n != 9 { pdf.obj(n, body) }
                pdf.obj(9, "<</Type /StructElem /S /Document /P 8 0 R /K [10 0 R 11 0 R 12 0 R 21 0 R]>>")
                pdf.obj(20, "<</Type /Annot /Subtype /Widget /FT /Tx /Rect [100 100 200 120] /P 3 0 R \(field)>>")
                pdf.obj(21, "<</S /Form /P 9 0 R /Pg 3 0 R /K <</Type /OBJR /Pg 3 0 R /Obj 20 0 R>>>>")
            }))
        }

        let good = try AccessibilityChecker.check(open("/T (name) /TU (Your name)"))
        assertRule(good, .formNames, .passed)
        assertRule(good, .formTagged, .passed)
        let item = try AccessibilityChecker.check(open("/T (name)"))[.formNames]
        XCTAssertEqual(item.status, .failed)
        XCTAssertEqual(item.where[0].element?.number, 20)
    }

    func test_aFormFieldOutsideTheTagsIsFound() throws {
        let bytes = AccessKit.build(1, { _ in TaggedFile.content },
            catalog: "/StructTreeRoot 8 0 R /MarkInfo <</Marked true>> /Lang (en) /AcroForm <</Fields [20 0 R]>>",
            pageEntries: "/StructParents 0 /Tabs /S /Annots [20 0 R]", more: { pdf in
            for (n, body) in TaggedFile.objects().sorted(by: { $0.key < $1.key }) { pdf.obj(n, body) }
            pdf.obj(20, "<</Type /Annot /Subtype /Widget /FT /Tx /T (a) /TU (A) /Rect [100 100 200 120] /P 3 0 R>>")
        })

        assertRule(try AccessibilityChecker.check(PdfDocument.open(bytes)), .formTagged, .failed)
    }

    func test_autoTaggedFilesPassOnceTheyAreDescribed() throws {
        let document = try PdfDocument.open(AccessKit.report(3))
        let result = try AutoTagger.tag(document, AutoTagOptions("en-US"))
        let first = try AccessibilityChecker.check(document)
        assertRule(first, .tagged, .passed)
        assertRule(first, .taggedContent, .passed)
        assertRule(first, .language, .passed)
        assertRule(first, .figureAlt, .failed)
        assertRule(first, .title, .failed)

        let tree = try XCTUnwrap(StructureTree.read(document))
        for figure in result.figuresWithoutAlt {
            try XCTUnwrap(tree.elements.first { $0.reference?.number == figure.reference.number }).alt = "A grey square"
        }
        try tree.write(document)
        _ = try AccessibilityChecker.fix(document, .setTitle, "Quarterly report")

        let again = try AccessKit.reopen(document, rewrite: true)
        let report = try AccessibilityChecker.check(again)
        for item in report.items where item.rule != .contrast {
            XCTAssertTrue(item.status == .passed, "\(item.rule): \(item.status) - \(item.message)")
        }
        XCTAssertEqual(report.needsPerson, 1)
    }

    func test_locationsAreCappedButCounted() throws {
        let bytes = AccessKit.build(60) { _ in "q 600 0 0 700 0 0 cm /Im1 Do Q" }
        let item = try AccessibilityChecker.check(PdfDocument.open(bytes))[.searchable]

        XCTAssertEqual(item.where.count, 50)
        XCTAssertTrue(item.message.contains("60"))
    }

    func test_cancellationStopsTheCheck() async throws {
        let task = Task { () throws -> AccessibilityReport in
            let document = try PdfDocument.open(AccessKit.report(2))
            while !Task.isCancelled { await Task.yield() }
            return try AccessibilityChecker.check(document)
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected a cancellation")
        } catch is CancellationError {
        }
    }
}
