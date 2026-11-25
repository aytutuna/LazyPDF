import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Standards/PdfABudgetTests.cs: the same cases.

final class PdfABudgetTests: XCTestCase {
    private let form = "/Type /XObject /Subtype /Form /BBox [0 0 100 100]"

    private func limited(_ file: [UInt8], _ limit: Int) throws -> PdfAReport {
        let document = try PdfDocument.open(file)
        let checker = PdfAChecker(document, .a2b)
        checker.maxWork = limit
        checker.run()
        return checker.report()
    }

    private func tooMuch(_ report: PdfAReport) -> Bool { report.issues.contains { $0.message == PdfAText.tooMuchContent } }

    func test_showingTextInAFormCostsItsGlyphsAtEveryPaint() throws {
        let text = String(repeating: "A", count: 30_000)
        func run(_ paints: Int) throws -> PdfAReport {
            try limited(StandardsKit.compliant(content: String(repeating: "/Fm Do ", count: paints), resources: "/XObject <</Fm 9 0 R>>",
                                               extra: { pdf in pdf.stream(9, self.form, "BT (\(text)) Tj ET") }), 1 << 20)
        }
        XCTAssertTrue(tooMuch(try run(60)))
        XCTAssertFalse(tooMuch(try run(2)))
    }

    func test_aFormTheInterpreterCouldNotReadStillTakesACacheSlot() throws {
        let small = 1023
        let unreadable = PdfFilterEncoders.flate([UInt8](repeating: 0, count: (64 << 20) + 1024), .fastest)
        let names = (0..<small).map { "/S\($0) \(20 + $0) 0 R " }.joined()
        let paints = "/Bad Do " + (0..<small).map { "/S\($0) Do " }.joined()
        func run(_ count: Int) throws -> PdfAReport {
            try limited(StandardsKit.compliant(content: paints + String(repeating: "/Big Do ", count: count),
                                               resources: "/XObject <</Bad 8000 0 R \(names) /Big 9 0 R>>", extra: { pdf in
                pdf.stream(8000, self.form + " /Filter /FlateDecode", unreadable)
                pdf.stream(9, self.form, String(repeating: " ", count: 1 << 20))
                for i in 0..<small { pdf.stream(20 + i, self.form, "q Q") }
            }), 4 << 20)
        }
        XCTAssertTrue(tooMuch(try run(20)))
        XCTAssertFalse(tooMuch(try run(1)))
    }

    func test_aFormAtTheDepthLimitIsReportedWhenAPatternItInheritsIsPainted() throws {
        for inherited in [true, false] {
            let depth = 20
            let cell = "/PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 10 10] /XStep 10 /YStep 10"
            let file = StandardsKit.compliant(content: (inherited ? "/Pattern cs /P scn " : "") + "/Fm Do", resources: "/XObject <</Fm 9 0 R>> /Pattern <</P 5000 0 R>>", extra: { pdf in
                for i in 0..<depth {
                    let last = i == depth - 1
                    pdf.stream(9 + i, self.form + " /Resources <<" + (last ? "" : "/XObject <</Fm \(10 + i) 0 R>>") + ">>", last ? "0 0 10 10 re f" : "/Fm Do")
                }
                pdf.stream(5000, cell, "0 0 5 5 re f")
            })
            XCTAssertEqual(inherited, tooMuch(try StandardsKit.check(file)), "inherited \(inherited)")
        }
    }

    func test_aColourSetAtTheDepthLimitIsNotAPatternToSkip() throws {
        let depth = 20
        let file = StandardsKit.compliant(content: "/Fm Do", resources: "/XObject <</Fm 9 0 R>>", extra: { pdf in
            for i in 0..<depth {
                let last = i == depth - 1
                pdf.stream(9 + i, self.form + " /Resources <<" + (last ? "/ColorSpace <</Cs [/ICCBased 7 0 R]>>" : "/XObject <</Fm \(10 + i) 0 R>>") + ">>",
                           last ? "/Cs cs 0 0 0 scn 0 0 10 10 re f" : "/Fm Do")
            }
        })
        XCTAssertFalse(tooMuch(try StandardsKit.check(file)))
    }

    func test_aDeviceColourUsedOverAndOverIsReportedOnce() throws {
        let file = StandardsKit.compliant(content: String(repeating: "1 0 0 0 k 0 0 5 5 re f ", count: 5000))
        XCTAssertEqual(try StandardsKit.check(file).issues.filter { $0.clause == "6.2.4.3" }.count, 1)
    }

    func test_theTaggedContentIsNotReadAgainOnceTheBudgetIsGone() throws {
        let document = try PdfDocument.open(StandardsKit.tagged(.a2a))
        let checker = PdfAChecker(document, .a2a)
        checker.maxWork = 1
        checker.run()
        XCTAssertTrue(checker.structureIssues.contains { $0.message == PdfAText.tooMuchContent })
    }
}
