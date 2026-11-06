import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Standards/PdfABoundTests.cs: the same cases. The two tests that race a Task against a
// timeout (AnActionThatNamesItselfInNextIsJudgedOnce, ActionsSharingOneNextListAreJudgedInLinearTime) run the check in line:
// a loop would hang the run, which has its own limit; the second also checks the elapsed time against six times the C# limit.

final class PdfABoundTests: XCTestCase {
    private let helvetica = "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding>>"
    private let formEntries = "/Type /XObject /Subtype /Form /BBox [0 0 100 100]"

    private func limited(_ file: [UInt8], _ limit: Int) throws -> PdfAReport {
        let document = try PdfDocument.open(file)
        let checker = PdfAChecker(document, .a2b)
        checker.maxWork = limit
        checker.run()
        return checker.report()
    }

    private func name(_ i: Int) -> String {
        "zz" + String(Unicode.Scalar(UInt8(97 + i / 26))) + String(Unicode.Scalar(UInt8(97 + i % 26)))
    }

    func test_anActionThatNamesItselfInNextIsJudgedOnce() throws {
        let file = StandardsKit.compliant(catalog: "/OpenAction 40 0 R", extra: { pdf in
            pdf.obj(40, "<</S /GoTo /D [3 0 R /Fit] /Next [40 0 R 40 0 R 40 0 R 40 0 R]>>")
        })
        XCTAssertTrue(try StandardsKit.check(file).isValid)
    }

    func test_aNextChainIsFollowedToItsEnd() throws {
        let chain = StandardsKit.compliant(catalog: "/OpenAction 40 0 R", extra: { pdf in
            for i in 0..<18 { pdf.obj(40 + i, "<</S /GoTo /D [3 0 R /Fit] /Next \(41 + i) 0 R>>") }
            pdf.obj(58, "<</S /JavaScript /JS (1)>>")
        })
        StandardsKit.assertContains(try StandardsKit.clauses(chain), "6.5.1")

        let many = String(repeating: "<</S /GoTo /D [3 0 R /Fit]>> ", count: 70)
        let wide = StandardsKit.compliant(catalog: "/OpenAction <</S /GoTo /D [3 0 R /Fit] /Next [\(many) <</S /Launch>>]>>")
        StandardsKit.assertContains(try StandardsKit.clauses(wide), "6.5.1")
    }

    func test_aFontShownInAnOversizedFormIsStillReported() throws {
        let content = String(repeating: "n ", count: 1_000_100) + "BT /F1 12 Tf (A) Tj ET"
        let file = StandardsKit.compliant(content: "/Fm Do", resources: "/XObject <</Fm 9 0 R>>", extra: { pdf in
            pdf.stream(9, "/Type /XObject /Subtype /Form /BBox [0 0 100 100] /Resources <</Font <</F1 10 0 R>>>>", content)
            pdf.obj(10, self.helvetica)
        })
        StandardsKit.assertHas(try StandardsKit.check(file).issues) { $0.clause == "6.1.7" && $0.message == PdfAText.tooMuchContent }
    }

    func test_aFontShownInASoftMaskGroupIsReported() throws {
        let file = StandardsKit.compliant(content: "/GS0 gs 0 0 1 rg 20 20 100 100 re f", resources: "/ExtGState <</GS0 <</SMask <</S /Luminosity /G 9 0 R>>>>>>", extra: { pdf in
            pdf.stream(9, "/Type /XObject /Subtype /Form /BBox [0 0 200 300] /Group <</S /Transparency /CS /DeviceGray>> /Resources <</Font <</F1 10 0 R>>>>", "BT /F1 12 Tf (A) Tj ET")
            pdf.obj(10, self.helvetica)
        })
        StandardsKit.assertHas(try StandardsKit.check(file).issues) { $0.clause == "6.2.11.4.1" && $0.where == "Font Helvetica" }
    }

    private let type3 = "<</Type /Font /Subtype /Type3 /FontBBox [0 0 10 10] /FontMatrix [0.001 0 0 0.001 0 0] /CharProcs <</a 11 0 R>> "
        + "/Encoding <</Type /Encoding /Differences [97 /a]>> /FirstChar 97 /LastChar 97 /Widths [500] /Resources <</Font <</F2 12 0 R>>>>>>"

    func test_aFontShownInAGlyphProcedureIsReported() throws {
        func page(_ procedure: String) -> [UInt8] {
            StandardsKit.compliant(content: "BT /F1 12 Tf 20 20 Td (a) Tj ET", resources: "/Font <</F1 9 0 R>>", extra: { pdf in
                pdf.obj(9, self.type3)
                pdf.stream(11, "", procedure)
                pdf.obj(12, self.helvetica)
            })
        }
        StandardsKit.assertHas(try StandardsKit.check(page("500 0 d0 BT /F2 12 Tf (A) Tj ET")).issues) { $0.clause == "6.2.11.4.1" && $0.where == "Font Helvetica" }
        StandardsKit.assertNone(try StandardsKit.check(page("500 0 d0")).issues) { $0.where == "Font Helvetica" }
    }

    func test_aTextRenderModeOfThreeInAGlyphProcedureNeedsNoEmbedding() throws {
        let file = StandardsKit.compliant(content: "BT /F1 12 Tf 20 20 Td (a) Tj ET", resources: "/Font <</F1 9 0 R>>", extra: { pdf in
            pdf.obj(9, self.type3)
            pdf.stream(11, "", "500 0 d0 q BT 3 Tr /F2 12 Tf (A) Tj ET Q")
            pdf.obj(12, self.helvetica)
        })
        StandardsKit.assertNone(try StandardsKit.check(file).issues) { $0.where == "Font Helvetica" }
    }

    func test_reusingAFormCostsItsOperationsAndNotItsSizeEachTime() throws {
        let form = "q Q" + String(repeating: " ", count: 1 << 20)
        let content = String(repeating: "/Fm Do ", count: 1100)
        try StandardsKit.assertClean(StandardsKit.compliant(content: content, resources: "/XObject <</Fm 9 0 R>>",
                                                            extra: { pdf in pdf.stream(9, "/Type /XObject /Subtype /Form /BBox [0 0 100 100]", form) }))
    }

    func test_formsListedInTheResourcesAreReadOnlyWhileThereIsBudget() throws {
        let file = StandardsKit.compliant(content: "", resources: "/XObject <<" + (0..<60).map { "/F\($0) \(20 + $0) 0 R " }.joined() + ">>", extra: { pdf in
            for i in 0..<60 { pdf.stream(20 + i, "/Type /XObject /Subtype /Form /BBox [0 0 10 10]", String(repeating: " ", count: 40_000) + self.name(i)) }
        })
        let issues = try limited(file, 1 << 20).issues
        StandardsKit.assertHas(issues) { $0.message == PdfAText.unknownOperator(self.name(0)) }
        StandardsKit.assertHas(issues) { $0.message == PdfAText.tooMuchContent }
        StandardsKit.assertNone(issues) { $0.message == PdfAText.unknownOperator(self.name(59)) }
        StandardsKit.assertNone(try limited(file, 1 << 30).issues) { $0.message == PdfAText.tooMuchContent }
    }

    func test_appearancesAreReadOnlyWhileThereIsBudget() throws {
        let count = 300
        let file = StandardsKit.compliant(page: "/Annots [" + (0..<count).map { "\(20 + $0) 0 R " }.joined() + "]", extra: { pdf in
            for i in 0..<count {
                pdf.stream(1000 + i, "/Type /XObject /Subtype /Form /BBox [0 0 10 10]", String(repeating: " ", count: 4000) + self.name(i))
                pdf.obj(20 + i, "<</Type /Annot /Subtype /Square /Rect [10 10 50 50] /F 4 /AP <</N \(1000 + i) 0 R>>>>")
            }
        })
        let issues = try limited(file, 1 << 18).issues
        StandardsKit.assertHas(issues) { $0.message == PdfAText.unknownOperator(self.name(0)) }
        StandardsKit.assertHas(issues) { $0.message == PdfAText.tooMuchContent }
        StandardsKit.assertNone(issues) { $0.message == PdfAText.unknownOperator(self.name(count - 1)) }
    }

    func test_aPageThatRunsPastTheOperationLimitIsReported() throws {
        let form = String(repeating: "n ", count: 100_000)
        let content = String(repeating: "/Fm Do ", count: 120)
        let file = StandardsKit.compliant(content: content, resources: "/XObject <</Fm 9 0 R>>",
                                          extra: { pdf in pdf.stream(9, "/Type /XObject /Subtype /Form /BBox [0 0 100 100]", form) })
        StandardsKit.assertHas(try StandardsKit.check(file).issues) { $0.where == "Page 1" && $0.message == PdfAText.tooMuchContent }
    }

    func test_aChainOfGlyphProceduresThatShowTheNextFontIsCutOff() throws {
        let count = 100
        let file = StandardsKit.compliant(content: "BT /F 12 Tf 20 20 Td (a) Tj ET", resources: "/Font <</F 100 0 R>>", extra: { pdf in
            for i in 0..<count {
                pdf.obj(100 + i, "<</Type /Font /Subtype /Type3 /FontBBox [0 0 10 10] /FontMatrix [0.001 0 0 0.001 0 0] /CharProcs <</a \(1000 + i) 0 R>> "
                    + "/Encoding <</Type /Encoding /Differences [97 /a]>> /FirstChar 97 /LastChar 97 /Widths [500] /Resources <</Font <</F \(101 + i) 0 R>>>>>>")
                pdf.stream(1000 + i, "", "500 0 d0 BT /F 12 Tf (a) Tj ET")
            }
        })
        StandardsKit.assertHas(try StandardsKit.check(file).issues) { $0.clause == "6.1.7" && $0.message == PdfAText.tooMuchContent }
    }

    func test_actionsSharingOneNextListAreJudgedInLinearTime() throws {
        let count = 20_000
        let file = StandardsKit.compliant(catalog: "/OpenAction 40 0 R", extra: { pdf in
            pdf.obj(39, "[" + (0..<count).map { "\(40 + $0) 0 R " }.joined() + "\(40 + count) 0 R]")
            for i in 0..<count { pdf.obj(40 + i, "<</S /GoTo /D [3 0 R /Fit] /Next 39 0 R>>") }
            pdf.obj(40 + count, "<</S /JavaScript /JS (1)>>")
        })
        let start = Date()
        XCTAssertTrue(try StandardsKit.check(file).issues.map { $0.clause }.contains("6.5.1"))
        XCTAssertLessThan(Date().timeIntervalSince(start), 60, "the C# limit is 10 seconds; a debug build of Swift is slower")
    }

    func test_walkingAnnotationsAndTheirStatesUsesTheBudget() throws {
        let count = 2000
        let file = StandardsKit.compliant(page: "/Annots [" + (0..<count).map { "\(20 + $0) 0 R " }.joined() + "]", extra: { pdf in
            pdf.obj(9, "<<" + (0..<256).map { "/S\($0) 10 0 R " }.joined() + ">>")
            pdf.stream(10, "/Type /XObject /Subtype /Form /BBox [0 0 10 10]", "q Q")
            for i in 0..<count { pdf.obj(20 + i, "<</Type /Annot /Subtype /Square /Rect [10 10 50 50] /F 4 /AP <</N 9 0 R>>>>") }
        })
        StandardsKit.assertHas(try limited(file, 1 << 20).issues) { $0.message == PdfAText.tooMuchContent }
        StandardsKit.assertNone(try limited(file, 1 << 30).issues) { $0.message == PdfAText.tooMuchContent }
    }

    func test_aFormTheInterpreterDoesNotKeepCostsItsSizeAtEveryPaint() throws {
        let small = 1100
        let names = (0..<small).map { "/S\($0) \(20 + $0) 0 R " }.joined()
        let paints = (0..<small).map { "/S\($0) Do " }.joined()
        func run(_ count: Int) throws -> PdfAReport {
            try limited(StandardsKit.compliant(content: paints + String(repeating: "/Big Do ", count: count), resources: "/XObject <<\(names) /Big 9 0 R>>", extra: { pdf in
                pdf.stream(9, "/Type /XObject /Subtype /Form /BBox [0 0 100 100]", String(repeating: " ", count: 2 << 20))
                for i in 0..<small { pdf.stream(20 + i, "/Type /XObject /Subtype /Form /BBox [0 0 10 10]", "q Q") }
            }), 8 << 20)
        }
        StandardsKit.assertHas(try run(20).issues) { $0.message == PdfAText.tooMuchContent }
        StandardsKit.assertNone(try run(1).issues) { $0.message == PdfAText.tooMuchContent }
    }

    func test_formsNestedPastTheInterpretersDepthAreReported() throws {
        for (depth, reported) in [(25, true), (10, false)] {
            let file = StandardsKit.compliant(content: "/Fm Do", resources: "/XObject <</Fm 9 0 R>>", extra: { pdf in
                for i in 0..<depth {
                    let last = i == depth - 1
                    pdf.stream(9 + i, "/Type /XObject /Subtype /Form /BBox [0 0 100 100] /Resources <<" + (last ? "/Font <</F1 5000 0 R>>" : "/XObject <</Fm \(10 + i) 0 R>>") + ">>",
                               last ? "BT /F1 12 Tf (A) Tj ET" : "/Fm Do")
                }
                pdf.obj(5000, self.helvetica)
            })
            let issues = try StandardsKit.check(file).issues
            XCTAssertEqual(reported, issues.contains { $0.message == PdfAText.tooMuchContent }, "depth \(depth)")
            if !reported { StandardsKit.assertHas(issues, "depth \(depth)") { $0.clause == "6.2.11.4.1" } }
        }
    }

    func test_anAppearanceThatRunsPastTheOperationLimitIsReported() throws {
        let form = String(repeating: "n ", count: 100_000)
        let file = StandardsKit.compliant(page: "/Annots [20 0 R]", extra: { pdf in
            pdf.stream(9, "/Type /XObject /Subtype /Form /BBox [0 0 100 100]", form)
            pdf.stream(10, "/Type /XObject /Subtype /Form /BBox [0 0 10 10] /Resources <</XObject <</Fm 9 0 R>>>>", String(repeating: "/Fm Do ", count: 120))
            pdf.obj(20, "<</Type /Annot /Subtype /Square /Rect [10 10 50 50] /F 4 /AP <</N 10 0 R>>>>")
        })
        StandardsKit.assertHas(try StandardsKit.check(file).issues) { $0.where.hasPrefix("Page 1") && $0.where != "Page 1" && $0.message == PdfAText.tooMuchContent }
    }

    func test_aDeviceImageInAGlyphProcedureCountsAsUsed() throws {
        let type3 = "<</Type /Font /Subtype /Type3 /FontBBox [0 0 10 10] /FontMatrix [0.001 0 0 0.001 0 0] /CharProcs <</a 11 0 R>> "
            + "/Encoding <</Type /Encoding /Differences [97 /a]>> /FirstChar 97 /LastChar 97 /Widths [500] /Resources <</XObject <</Im 12 0 R>>>>>>"
        func page(_ space: String) -> [UInt8] {
            StandardsKit.compliant(content: "BT /F1 12 Tf 20 20 Td (a) Tj ET", resources: "/Font <</F1 9 0 R>>", extra: { pdf in
                pdf.obj(9, type3)
                pdf.stream(11, "", "500 0 d0 /Im Do")
                pdf.stream(12, "/Type /XObject /Subtype /Image /Width 1 /Height 1 /BitsPerComponent 8 /ColorSpace \(space)", "    ")
            })
        }
        StandardsKit.assertContains(try StandardsKit.clauses(page("/DeviceCMYK")), "6.2.4.3")
        try StandardsKit.assertClean(page("/DeviceRGB"))
    }

    func test_hexStringsInObjectStreamsAndContentStreamsAreRead() throws {
        let stored = StandardsKit.compliant(extra: { pdf in pdf.stream(9, "/Type /ObjStm /N 1 /First 5", "10 0 <</X <ABC>>>") })
        let rebuilt = TestPdf.replace(stored, "startxref", "startxref\n7")
        StandardsKit.assertHas(try StandardsKit.check(rebuilt).issues) { $0.clause == "6.1.6" && $0.where == PdfAText.objectName(9) }

        StandardsKit.assertContains(try StandardsKit.clauses(StandardsKit.compliant(content: "/Span <</X <ABC>>> BDC EMC")), "6.1.6")
        try StandardsKit.assertClean(StandardsKit.compliant(content: "/Span <</X <ABCD>>> BDC EMC"))
        try StandardsKit.assertClean(StandardsKit.compliant(content: "q BI /W 2 /H 1 /BPC 8 /CS /G ID <( EI Q"))
    }

    func test_inlineImageDataEndsWhereTheParserEndsIt() throws {
        StandardsKit.assertLacks(try StandardsKit.clauses(StandardsKit.compliant(content: "q BI /W 8 /H 1 /BPC 8 /CS /G ID a EI <z EI Q")), "6.1.6")
        StandardsKit.assertContains(try StandardsKit.clauses(StandardsKit.compliant(content: "q BI /W 1 /H 1 /BPC 8 /CS /G ID a EI <z> Q")), "6.1.6")
    }

    func test_inlineImagesTakeTheShortFilterNamesButNeverCrypt() throws {
        func image(_ filter: String, _ data: String) -> String { "BI /W 1 /H 1 /BPC 8 /CS /G /F \(filter) ID \(data) EI" }
        try StandardsKit.assertClean(StandardsKit.compliant(content: image("/AHx", "00>")))
        StandardsKit.assertContains(try StandardsKit.clauses(StandardsKit.compliant(content: image("/Crypt", "x"))), "6.1.10")
        StandardsKit.assertContains(try StandardsKit.clauses(StandardsKit.compliant(.a1b, content: image("/Crypt", "x")), .a1b), "6.1.10")
    }

    func test_aStreamTakesTheFullFilterNamesOnly() throws {
        func stream(_ filter: String) -> [UInt8] {
            StandardsKit.compliant(catalog: "/Extra 9 0 R", extra: { pdf in pdf.stream(9, "/Filter \(filter)", "abc") })
        }
        StandardsKit.assertHas(try StandardsKit.check(stream("/Fl")).issues) { $0.clause == "6.1.7.2" && $0.message.contains("Fl") }
        StandardsKit.assertHas(try StandardsKit.check(stream("[/ASCIIHexDecode /DCT]")).issues) { $0.clause == "6.1.7.2" && $0.message.contains("DCT") }
        StandardsKit.assertLacks(try StandardsKit.clauses(stream("/FlateDecode")), "6.1.7.2")
    }

    func test_statesPastTheBudgetStillHaveTheirDictionariesCheckedAndAreReported() throws {
        let file = StandardsKit.compliant(page: "/Annots [30 0 R]", extra: { pdf in
            pdf.obj(30, "<</Type /Annot /Subtype /Square /Rect [10 10 50 50] /F 4 /AP <</N 31 0 R>>>>")
            pdf.obj(31, "<</A 32 0 R /B 33 0 R /C 34 0 R>>")
            pdf.stream(32, "/Type /XObject /Subtype /Form /BBox [0 0 10 10]", String(repeating: " ", count: 40_000))
            pdf.stream(33, "/Type /XObject /Subtype /Form /BBox [0 0 10 10]", "q Q")
            pdf.stream(34, "/Type /XObject /Subtype /Form /BBox [0 0 10 10] /Ref 1 0 R", "q Q")
        })
        let issues = try limited(file, 20_000).issues
        StandardsKit.assertHas(issues) { $0.message == PdfAText.referenceXObject }
        StandardsKit.assertHas(issues) { $0.message == PdfAText.tooMuchContent && $0.where == "Page 1, annotation 1" }
    }

    func test_manyObjectsAreWalkedInLinearTime() throws {
        let count = 100_000
        let file = StandardsKit.compliant(catalog: "/Extra 39 0 R", extra: { pdf in
            pdf.obj(39, "[" + (0..<count).map { "\(40 + $0) 0 R " }.joined() + "]")
            for i in 0..<count { pdf.obj(40 + i, "<<>>") }
        })
        let start = Date()
        _ = try StandardsKit.check(file)
        XCTAssertLessThan(Date().timeIntervalSince(start), 120, "the C# limit is 30 seconds; a debug build of Swift is slower")
    }

    func test_objectStreamsAreReadInTheOrderTheFileListsThem() throws {
        let stored = StandardsKit.compliant(extra: { pdf in
            pdf.stream(9, "/Type /ObjStm /N 1 /First 5", "10 0 <</X <ABC>>>")
            pdf.stream(8, "/Type /ObjStm /N 1 /First 5", "11 0 <</X <ABC>>>")
        })
        let rebuilt = TestPdf.replace(stored, "startxref", "startxref\n7")
        let places = try StandardsKit.check(rebuilt).issues.filter { $0.clause == "6.1.6" }.map { $0.where }
        XCTAssertEqual(places, [PdfAText.objectName(9), PdfAText.objectName(8)])
    }
}
