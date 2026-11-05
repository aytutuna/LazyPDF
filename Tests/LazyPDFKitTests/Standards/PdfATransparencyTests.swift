import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Standards/PdfATransparencyTests.cs: the same cases.

final class PdfATransparencyTests: XCTestCase {
    private func drawn(_ state: String, page: String = "") -> [UInt8] {
        StandardsKit.compliant(page: page, content: "/GS gs 0 0 1 rg 10 10 50 50 re f", resources: "/ExtGState <</GS <<\(state)>>>>")
    }

    func test_part1RefusesWhatNeedsTransparencyAndLaterPartsAllowIt() throws {
        for state in ["/ca 0.5", "/CA 0.5", "/BM /Multiply", "/SMask << /S /Luminosity /G 9 0 R >>"] {
            let file = StandardsKit.compliant(.a1b, content: "/GS gs 0 0 1 rg 10 10 50 50 re f", resources: "/ExtGState <</GS <<\(state)>>>>", extra: { pdf in
                pdf.stream(9, "/Type /XObject /Subtype /Form /BBox [0 0 10 10]", "0.5 g 0 0 10 10 re f")
            })
            XCTAssertTrue(try StandardsKit.clauses(file, .a1b).contains("6.4"), state)
            XCTAssertFalse(try StandardsKit.clauses(file, .a2b).contains("6.4"), state)
            XCTAssertFalse(try StandardsKit.clauses(file, .a2b).contains("6.2.10"), state)
        }
    }

    func test_aNormalGraphicsStateIsFineEverywhere() throws {
        try StandardsKit.assertClean(drawn("/ca 1 /CA 1 /BM /Normal /SMask /None"), .a2b)
        StandardsKit.assertLacks(try StandardsKit.clauses(drawn("/ca 1 /BM /Compatible"), .a1b), "6.4")
    }

    func test_aTransparencyGroupOnThePageIsRefusedByPart1Only() throws {
        let file = StandardsKit.compliant(.a1b, page: "/Group << /S /Transparency /CS /DeviceRGB >>")
        StandardsKit.assertContains(try StandardsKit.clauses(file, .a1b), "6.4")
        StandardsKit.assertLacks(try StandardsKit.clauses(file, .a2b), "6.2.10")
    }

    func test_aGroupWithADeviceSpaceCountsAsDeviceColourUse() throws {
        let file = StandardsKit.compliant(page: "/Group << /S /Transparency /CS /DeviceCMYK >>", content: "", intents: "")
        StandardsKit.assertContains(try StandardsKit.clauses(file), "6.2.4.3")
    }

    func test_transferFunctionsAreNeverAllowed() throws {
        StandardsKit.assertContains(try StandardsKit.clauses(drawn("/TR /Identity")), "6.2.5")
        StandardsKit.assertContains(try StandardsKit.clauses(drawn("/TR 9 0 R"), .a1b), "6.2.8")
        StandardsKit.assertLacks(try StandardsKit.clauses(drawn("/TR2 /Default")), "6.2.5")
        StandardsKit.assertContains(try StandardsKit.clauses(drawn("/TR2 /Identity")), "6.2.5")
    }

    func test_anAnnotationOpacityBelowOneIsRefusedByPart1() throws {
        let file = StandardsKit.compliant(.a1b, page: "/Annots [9 0 R]", extra: { pdf in
            pdf.obj(9, "<</Type /Annot /Subtype /Square /Rect [10 10 50 50] /F 4 /CA 0.5 /AP <</N 10 0 R>>>>")
                .stream(10, "/Type /XObject /Subtype /Form /BBox [0 0 40 40]", "0 0 1 rg 0 0 40 40 re f")
        })
        StandardsKit.assertContains(try StandardsKit.clauses(file, .a1b), "6.4")
        StandardsKit.assertLacks(try StandardsKit.clauses(file, .a2b), "6.2.10")
    }
}
