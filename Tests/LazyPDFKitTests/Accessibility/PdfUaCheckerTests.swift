import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Accessibility/PdfUaCheckerTests.cs: the same cases.

final class PdfUaCheckerTests: XCTestCase {
    private func fails(_ condition: String, _ file: [UInt8], line: UInt = #line) throws {
        let report = try PdfUaKit.check(file)
        XCTAssertTrue(report.issues.contains { $0.condition == condition }, "\(condition) not found in:\n\(PdfUaKit.describe(report))", line: line)
    }

    private func passes(_ file: [UInt8], line: UInt = #line) throws {
        let report = try PdfUaKit.check(file)
        XCTAssertTrue(report.isValid, PdfUaKit.describe(report), line: line)
    }

    private func lacks(_ condition: String, _ file: [UInt8], line: UInt = #line) throws {
        XCTAssertFalse(try PdfUaKit.conditions(file).contains(condition), line: line)
    }

    func test_aGoodFilePasses() throws { try passes(PdfUaKit.build()) }

    func test_issuesCarryTheCheckpointAndTheClause() throws {
        let issues = try PdfUaKit.check(PdfUaKit.build(viewer: "")).issues
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues[0].condition, "07-001")
        XCTAssertEqual(issues[0].checkpoint, "07")
        XCTAssertEqual(issues[0].clause, "7.1")
        XCTAssertFalse(DotNetText.isNullOrWhiteSpace(issues[0].message))
    }

    func test_theCatalogMustBeMarkedAndHoldATree() throws {
        try fails("01-001", PdfUaKit.build(markInfo: ""))
        try fails("01-007", PdfUaKit.build(markInfo: "/MarkInfo <</Marked true /Suspects true>>"))
        try fails("01-002", PdfUaKit.build(tree: false))
    }

    func test_contentIsTaggedOrAnArtifact() throws {
        try fails("01-005", PdfUaKit.build(content: PdfUaKit.figure + " 1 0 0 rg 0 0 5 5 re f"))
        try passes(PdfUaKit.build(content: PdfUaKit.figure + " /Artifact BMC 1 0 0 rg 0 0 5 5 re f EMC"))
        try fails("01-003", PdfUaKit.build(content: "/Figure <</MCID 0>> BDC /Artifact BMC 0 0 1 rg 20 20 100 100 re f EMC EMC"))
        try fails("01-004", PdfUaKit.build(content: "/Artifact BMC /Figure <</MCID 0>> BDC 0 0 1 rg 20 20 100 100 re f EMC EMC"))
    }

    func test_aSequenceThatTheTreeDoesNotNameIsNotTagged() throws {
        try fails("01-005", PdfUaKit.build(content: "/Figure <</MCID 7>> BDC 0 0 1 rg 20 20 100 100 re f EMC"))
    }

    func test_theRoleMapLeadsToStandardTypes() throws {
        try fails("02-001", PdfUaKit.build(edit: { $0[10] = "<</Type /StructElem /S /Weird /P 9 0 R /K 11 0 R>>" }))
        try passes(PdfUaKit.build(edit: { o in
            o[9] = "<</Type /StructTreeRoot /K 10 0 R /ParentTree 12 0 R /RoleMap <</Weird /Sect>>>>"
            o[10] = "<</Type /StructElem /S /Weird /P 9 0 R /K 11 0 R>>"
        }))

        let loop = PdfUaKit.build(edit: { o in
            o[9] = "<</Type /StructTreeRoot /K 10 0 R /ParentTree 12 0 R /RoleMap <</A /B /B /A>>>>"
            o[10] = "<</Type /StructElem /S /A /P 9 0 R /K 11 0 R>>"
        })
        try fails("02-003", loop)
        try lacks("02-001", loop)
    }

    func test_manyUnmappedTypesAreReportedUpToTheLimit() throws {
        let file = PdfUaKit.build(edit: { o in
            let kids = (13..<3013).map { "\($0) 0 R" }.joined(separator: " ")
            o[10] = "<</Type /StructElem /S /Document /P 9 0 R /K [11 0 R \(kids)]>>"
            for n in 13..<3013 { o[n] = "<</Type /StructElem /S /T\(n) /P 10 0 R>>" }
        })

        let report = try PdfUaKit.check(file)

        XCTAssertTrue(report.truncated)
        XCTAssertEqual(report.issues.filter { $0.condition == "02-001" }.count, 1000)
    }

    func test_aStandardTypeIsNotRemapped() throws {
        try fails("02-004", PdfUaKit.build(edit: { $0[9] = "<</Type /StructTreeRoot /K 10 0 R /ParentTree 12 0 R /RoleMap <</P /Span>>>>" }))
    }

    func test_theMetadataNamesPdfUaAndHoldsATitle() throws {
        try fails("06-001", PdfUaKit.build(xmp: ""))
        try fails("06-001", PdfUaKit.build(xmp: "<x:xmpmeta"))
        try fails("06-002", PdfUaKit.build(xmp: PdfUaKit.packet(ua: false)))
        try fails("06-003", PdfUaKit.build(xmp: PdfUaKit.packet(title: false)))
    }

    func test_theWindowShowsTheTitle() throws {
        try fails("07-001", PdfUaKit.build(viewer: ""))
        try fails("07-001", PdfUaKit.build(viewer: "/ViewerPreferences <</Direction /L2R>>"))
        try fails("07-002", PdfUaKit.build(viewer: "/ViewerPreferences <</DisplayDocTitle false>>"))
    }

    func test_tablesAndListsNestAsTheStandardSays() throws {
        try fails("09-004", PdfUaKit.build(edit: { o in
            o[11] = "<</Type /StructElem /S /Table /P 10 0 R /K 13 0 R>>"
            o[13] = "<</Type /StructElem /S /TD /P 11 0 R /Pg 3 0 R /K 0>>"
        }))
        try fails("09-004", PdfUaKit.build(edit: { o in
            o[11] = "<</Type /StructElem /S /Table /P 10 0 R /K 13 0 R>>"
            o[13] = "<</Type /StructElem /S /TR /P 11 0 R /K 14 0 R>>"
            o[14] = "<</Type /StructElem /S /P /P 13 0 R /Pg 3 0 R /K 0>>"
        }))
        try fails("09-005", PdfUaKit.build(edit: { o in
            o[11] = "<</Type /StructElem /S /L /P 10 0 R /K 13 0 R>>"
            o[13] = "<</Type /StructElem /S /Lbl /P 11 0 R /Pg 3 0 R /K 0>>"
        }))
        try fails("09-005", PdfUaKit.build(edit: { $0[11] = "<</Type /StructElem /S /LI /P 10 0 R /Pg 3 0 R /K 0>>" }))
    }

    func test_aWellFormedTableAndListPass() throws {
        try passes(PdfUaKit.build(edit: { o in
            o[10] = "<</Type /StructElem /S /Document /P 9 0 R /K [11 0 R 18 0 R]>>"
            o[11] = "<</Type /StructElem /S /Table /P 10 0 R /K [13 0 R 15 0 R]>>"
            o[13] = "<</Type /StructElem /S /TR /P 11 0 R /K 14 0 R>>"
            o[14] = "<</Type /StructElem /S /TH /P 13 0 R /Pg 3 0 R /K 0>>"
            o[15] = "<</Type /StructElem /S /TBody /P 11 0 R /K 16 0 R>>"
            o[16] = "<</Type /StructElem /S /TR /P 15 0 R /K 17 0 R>>"
            o[17] = "<</Type /StructElem /S /TD /P 16 0 R>>"
            o[18] = "<</Type /StructElem /S /L /P 10 0 R /K 19 0 R>>"
            o[19] = "<</Type /StructElem /S /LI /P 18 0 R /K [20 0 R 21 0 R]>>"
            o[20] = "<</Type /StructElem /S /Lbl /P 19 0 R>>"
            o[21] = "<</Type /StructElem /S /LBody /P 19 0 R>>"
            o[12] = "<</Nums [0 [14 0 R]]>>"
        }))
    }

    func test_theLanguageCanBeTold() throws {
        let conditions = try PdfUaKit.conditions(PdfUaKit.build(lang: ""))
        XCTAssertTrue(conditions.contains("11-006"))
        XCTAssertTrue(conditions.contains("11-001"))
        try fails("11-006", PdfUaKit.build(lang: "/Lang (not a tag)"))
        try fails("11-007", PdfUaKit.build(edit: { $0[10] = "<</Type /StructElem /S /Document /P 9 0 R /K 11 0 R /Lang (x y)>>" }))
    }

    func test_topElementsWithALanguageStandInForTheCatalogs() throws {
        let conditions = try PdfUaKit.conditions(PdfUaKit.build(lang: "", edit: { $0[10] = "<</Type /StructElem /S /Document /P 9 0 R /K 11 0 R /Lang (tr)>>" }))

        XCTAssertFalse(conditions.contains("11-001"))
        XCTAssertTrue(conditions.contains("11-006"))
    }

    func test_figuresAndFormulasNeedAlternateText() throws {
        for (type, condition) in [("Figure", "13-004"), ("Formula", "17-002")] {
            try fails(condition, PdfUaKit.build(edit: { $0[11] = "<</Type /StructElem /S /\(type) /P 10 0 R /Pg 3 0 R /K 0>>" }))
            try fails(condition, PdfUaKit.build(edit: { $0[11] = "<</Type /StructElem /S /\(type) /P 10 0 R /Pg 3 0 R /K 0 /Alt ( )>>" }))
            try passes(PdfUaKit.build(edit: { $0[11] = "<</Type /StructElem /S /\(type) /P 10 0 R /Pg 3 0 R /K 0 /ActualText (x)>>" }))
        }
    }

    private func withHeadings(_ types: [String]) -> [UInt8] {
        PdfUaKit.build(edit: { o in
            o[10] = "<</Type /StructElem /S /Document /P 9 0 R /K [11 0 R \(types.indices.map { "\(20 + $0) 0 R" }.joined(separator: " "))]>>"
            for (i, type) in types.enumerated() { o[20 + i] = "<</Type /StructElem /S /\(type) /P 10 0 R>>" }
        })
    }

    func test_headingsAreInOrder() throws {
        try passes(withHeadings(["H1", "H2", "H3", "H2", "H1"]))
        try fails("14-002", withHeadings(["H2"]))
        try fails("14-003", withHeadings(["H1", "H3"]))
        try fails("14-007", withHeadings(["H", "H1"]))
        try lacks("14-003", withHeadings(["H1", "H2", "H1", "H2"]))
    }

    func test_notesHaveUniqueIds() throws {
        func with(_ second: String) -> [UInt8] {
            PdfUaKit.build(edit: { o in
                o[10] = "<</Type /StructElem /S /Document /P 9 0 R /K [11 0 R 13 0 R 14 0 R]>>"
                o[13] = "<</Type /StructElem /S /Note /P 10 0 R /ID (n1)>>"
                o[14] = "<</Type /StructElem /S /Note /P 10 0 R \(second)>>"
            })
        }

        try passes(with("/ID (n2)"))
        try fails("19-003", with(""))
        try fails("19-004", with("/ID (n1)"))
    }

    func test_optionalContentConfigurationsAreNamedAndStatic() throws {
        try fails("20-001", PdfUaKit.build(catalog: "/OCProperties <</OCGs [] /D <</Name (View)>> /Configs [<</Order []>>]>>"))
        try fails("20-002", PdfUaKit.build(catalog: "/OCProperties <</OCGs [] /D <</Order []>>>>"))
        try fails("20-003", PdfUaKit.build(catalog: "/OCProperties <</OCGs [] /D <</Name (View) /AS []>>>>"))
        try passes(PdfUaKit.build(catalog: "/OCProperties <</OCGs [] /D <</Name (View)>>>>"))
    }

    func test_embeddedFilesNameThemselvesTwice() throws {
        func with(_ spec: String) -> [UInt8] {
            PdfUaKit.build(catalog: "/Names <</EmbeddedFiles <</Names [(a) 13 0 R]>>>>", extra: { $0.obj(13, spec) })
        }

        try fails("21-001", with("<</Type /Filespec /F (a.txt)>>"))
        try passes(with("<</Type /Filespec /F (a.txt) /UF (a.txt)>>"))
    }

    func test_onlyADynamicXfaFormFails() throws {
        try fails("25-001", PdfUaKit.build(catalog: "/NeedsRendering true /AcroForm <</Fields [] /XFA []>>"))
        try passes(PdfUaKit.build(catalog: "/AcroForm <</Fields [] /XFA []>>"))
    }

    func test_securityMustAllowAccessibilityExtraction() throws {
        let cases: [(PdfPermissions, Bool)] = [(.all, true), ([.print, .copy], false)]
        for (permissions, allowed) in cases {
            let plain = try PdfDocument.open(PdfUaKit.build())
            let id = [UInt8](repeating: 0, count: 16)
            let security = PdfSecurity.create(userPassword: "", ownerPassword: "owner", permissions: permissions, strength: .aes128, firstId: id)
            let document = try PdfDocument.open(try plain.saveRewrite(PdfSaveOptions(security: security, documentId: id)))

            XCTAssertEqual(!(try PdfUaValidator.validate(document).issues.contains { $0.condition == "26-002" }), allowed)
        }
    }

    private func withAnnotation(_ annotation: String, _ elementType: String = "Link", tagged: Bool = true, page: String = "/Tabs /S") -> [UInt8] {
        PdfUaKit.build(page: "\(page) /Annots [13 0 R]", edit: { o in
            o[10] = "<</Type /StructElem /S /Document /P 9 0 R /K [11 0 R \(tagged ? "14 0 R" : "")]>>"
            o[14] = "<</Type /StructElem /S /\(elementType) /P 10 0 R /Pg 3 0 R /K <</Type /OBJR /Obj 13 0 R /Pg 3 0 R>>>>"
        }, extra: { $0.obj(13, annotation) })
    }

    func test_annotationsAreTaggedUnderTheRightTypeAndDescribed() throws {
        let link = "<</Type /Annot /Subtype /Link /Rect [0 0 10 10] /Contents (Home)>>"
        try passes(withAnnotation(link))

        try fails("28-002", withAnnotation(link, tagged: false))
        try fails("28-011", withAnnotation(link, "Annot"))
        try fails("28-003", withAnnotation("<</Type /Annot /Subtype /Text /Rect [0 0 10 10] /Contents (Note)>>"))
        try fails("28-004", withAnnotation("<</Type /Annot /Subtype /Link /Rect [0 0 10 10]>>"))
        try fails("28-004", withAnnotation("<</Type /Annot /Subtype /Text /Rect [0 0 10 10]>>", "Annot"))
        try passes(withAnnotation("<</Type /Annot /Subtype /Text /Rect [0 0 10 10] /Contents (Note)>>", "Annot"))
    }

    func test_theElementsAltDescribesAnAnnotationButNotALink() throws {
        try passes(withAnnotation("<</Type /Annot /Subtype /Stamp /Rect [0 0 10 10]>>", "Annot /Alt (Approved)"))
        try passes(withAnnotation("<</Type /Annot /Subtype /Widget /FT /Tx /T (a) /Rect [0 0 10 10]>>", "Form /Alt (Name)"))
        try fails("28-004", withAnnotation("<</Type /Annot /Subtype /Link /Rect [0 0 10 10]>>", "Link /Alt (Home)"))
        try fails("28-004", withAnnotation("<</Type /Annot /Subtype /Stamp /Rect [0 0 10 10]>>", "Annot /Alt ( )"))
        try fails("28-005", withAnnotation("<</Type /Annot /Subtype /Widget /FT /Tx /T (a) /Rect [0 0 10 10]>>", "Form /Alt ( )"))
    }

    func test_aTrapNetAnnotationIsNotAllowed() throws {
        try fails("28-007", withAnnotation("<</Type /Annot /Subtype /TrapNet /Rect [0 0 10 10]>>", tagged: false))
        try passes(withAnnotation("<</Type /Annot /Subtype /PrinterMark /Rect [0 0 10 10]>>", tagged: false))
    }

    func test_aPopupNeedsNothing() throws {
        try passes(withAnnotation("<</Type /Annot /Subtype /Popup /Rect [0 0 10 10]>>", tagged: false))
    }

    func test_aWidgetNeedsAToolTipFromItselfOrItsField() throws {
        let field = "<</Type /Annot /Subtype /Widget /FT /Tx /T (a) /Rect [0 0 10 10] /TU (Name)>>"
        try passes(withAnnotation(field, "Form"))
        try fails("28-005", withAnnotation(field.replacingOccurrences(of: "/TU (Name)", with: ""), "Form"))
        try fails("28-010", withAnnotation(field, "Annot"))

        try passes(PdfUaKit.build(page: "/Tabs /S /Annots [13 0 R]", edit: { o in
            o[10] = "<</Type /StructElem /S /Document /P 9 0 R /K [11 0 R 14 0 R]>>"
            o[14] = "<</Type /StructElem /S /Form /P 10 0 R /Pg 3 0 R /K <</Type /OBJR /Obj 13 0 R /Pg 3 0 R>>>>"
        }, extra: { pdf in
            pdf.obj(13, "<</Type /Annot /Subtype /Widget /Parent 15 0 R /Rect [0 0 10 10]>>")
            pdf.obj(15, "<</FT /Tx /T (a) /TU (Name) /Kids [13 0 R]>>")
        }))
    }

    func test_pagesWithAnnotationsFollowTheStructureForTabOrder() throws {
        let link = "<</Type /Annot /Subtype /Link /Rect [0 0 10 10] /Contents (Home)>>"
        try fails("28-008", withAnnotation(link, page: ""))
        try fails("28-009", withAnnotation(link, page: "/Tabs /R"))
    }

    func test_aReferenceXObjectFails() throws {
        let resources = "/XObject <</X1 13 0 R>>"
        try fails("30-001", PdfUaKit.build(resources: resources, extra: { $0.stream(13, "/Type /XObject /Subtype /Form /BBox [0 0 1 1] /Ref <</F (x.pdf) /Page 0>>", "") }))
        try passes(PdfUaKit.build(resources: resources, extra: { $0.stream(13, "/Type /XObject /Subtype /PS", "") }))
        try passes(PdfUaKit.build(resources: resources, extra: { $0.stream(13, "/Type /XObject /Subtype /Form /BBox [0 0 1 1]", "") }))
    }

    private func withText(_ fontObject: String, _ text: String = "BT /F1 12 Tf 20 100 Td (Hello) Tj ET", more: ((TestPdf) -> Void)? = nil) -> [UInt8] {
        PdfUaKit.build(content: "/P <</MCID 0>> BDC \(text) EMC", resources: "/Font <</F1 13 0 R>>",
                       edit: { $0[11] = "<</Type /StructElem /S /P /P 10 0 R /Pg 3 0 R /K 0>>" },
                       extra: { pdf in
                           pdf.obj(13, fontObject)
                           more?(pdf)
                       })
    }

    func test_shownFontsAreEmbedded() throws {
        let plain = "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding>>"
        try fails("31-009", withText(plain))
        try lacks("31-009", withText(plain, "BT /F1 12 Tf 3 Tr 20 100 Td (Hello) Tj ET"))

        let embedded = withText("<</Type /Font /Subtype /Type1 /BaseFont /ABCDEF+Helv /Encoding /WinAnsiEncoding /FontDescriptor 14 0 R>>", more: { pdf in
            pdf.obj(14, "<</Type /FontDescriptor /FontName /ABCDEF+Helv /Flags 32 /FontFile 15 0 R>>")
            pdf.stream(15, "", "x")
        })
        try lacks("31-009", embedded)
    }

    func test_shownCharactersMapToUnicode() throws {
        try fails("31-027", withText("<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding <</Type /Encoding /Differences [65 /zzunknown]>>>>", "BT /F1 12 Tf 20 100 Td (A) Tj ET"))
        try lacks("31-027", withText("<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding>>"))
    }

    func test_manyBrokenRulesStayWithinTheCap() throws {
        let report = try PdfUaKit.check(PdfUaKit.build(markInfo: "", lang: "", viewer: "", xmp: ""))

        XCTAssertFalse(report.truncated)
        XCTAssertTrue((4...19).contains(report.issues.count), "\(report.issues.count)")
    }
}
