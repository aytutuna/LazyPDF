import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Standards/PdfAImageTests.cs: the same cases.

final class PdfAImageTests: XCTestCase {
    private func withImage(_ entries: String, _ level: PdfALevel = .a2b, data: [UInt8] = [0]) -> [UInt8] {
        StandardsKit.compliant(level, content: "q 10 0 0 10 0 0 cm /Im Do Q", resources: "/XObject <</Im 9 0 R>>", extra: { pdf in
            pdf.stream(9, "/Type /XObject /Subtype /Image /Width 1 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 8 \(entries)", data)
        })
    }

    func test_aPlainImagePasses() throws {
        try StandardsKit.assertClean(withImage(""))
        try StandardsKit.assertClean(withImage("/Interpolate false"))
    }

    func test_interpolateOpiAndAlternatesAreReported() throws {
        StandardsKit.assertContains(try StandardsKit.clauses(withImage("/Interpolate true")), "6.2.8")
        StandardsKit.assertContains(try StandardsKit.clauses(withImage("/Interpolate true", .a1b), .a1b), "6.2.4")
        StandardsKit.assertHas(try StandardsKit.check(withImage("/OPI << /Version 2 >>")).issues) { $0.message.contains("OPI") }
        StandardsKit.assertHas(try StandardsKit.check(withImage("/Alternates []")).issues) { $0.message.contains("Alternates") }
    }

    func test_aSoftMaskedImageIsRefusedByPart1Only() throws {
        let file = StandardsKit.compliant(.a1b, content: "q 10 0 0 10 0 0 cm /Im Do Q", resources: "/XObject <</Im 9 0 R>>", extra: { pdf in
            pdf.stream(9, "/Type /XObject /Subtype /Image /Width 1 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 8 /SMask 10 0 R", [0])
                .stream(10, "/Type /XObject /Subtype /Image /Width 1 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 8", [255])
        })
        StandardsKit.assertContains(try StandardsKit.clauses(file, .a1b), "6.4")
        StandardsKit.assertLacks(try StandardsKit.clauses(file, .a2b), "6.2.10")
    }

    func test_jpegTwoThousandIsRefusedByPart1Only() throws {
        let file = withImage("/Filter /JPXDecode", .a1b)
        StandardsKit.assertContains(try StandardsKit.clauses(file, .a1b), "6.2.4")
        StandardsKit.assertLacks(try StandardsKit.clauses(file, .a2b), "6.2.8")
    }

    func test_inlineImagesAreHeldToTheSameRules() throws {
        let inline = "q 10 0 0 10 0 0 cm BI /W 1 /H 1 /CS /G /BPC 8 /I true ID x EI Q"
        StandardsKit.assertContains(try StandardsKit.clauses(StandardsKit.compliant(content: inline)), "6.2.8")
        StandardsKit.assertLacks(try StandardsKit.clauses(StandardsKit.compliant(content: inline.replacingOccurrences(of: "/I true ", with: ""))), "6.2.8")
        StandardsKit.assertContains(try StandardsKit.clauses(StandardsKit.compliant(content: inline.replacingOccurrences(of: "/I true", with: "/F /LZW"))), "6.1.10")
    }

    func test_formXObjectsMayNotReferenceOrCarryPostScript() throws {
        let use = "/Fm Do"
        func form(_ entries: String) -> [UInt8] {
            StandardsKit.compliant(content: use, resources: "/XObject <</Fm 9 0 R>>", extra: { pdf in
                pdf.stream(9, "/Type /XObject /Subtype /Form /BBox [0 0 10 10] \(entries)", "0 g 0 0 5 5 re f")
            })
        }
        try StandardsKit.assertClean(form(""))
        StandardsKit.assertContains(try StandardsKit.clauses(form("/Ref << /F (x.pdf) /Page 0 >>")), "6.2.9")
        StandardsKit.assertContains(try StandardsKit.clauses(form("/Subtype2 /PS")), "6.2.9")
        StandardsKit.assertContains(try StandardsKit.clauses(form("/OPI << >>")), "6.2.9")
        StandardsKit.assertContains(try StandardsKit.clauses(form("/Ref << /F (x.pdf) /Page 0 >>"), .a1b), "6.2.6")
        StandardsKit.assertContains(try StandardsKit.clauses(form("/Subtype2 /PS"), .a1b), "6.2.7")
    }

    func test_aPostScriptXObjectIsReported() throws {
        let file = StandardsKit.compliant(resources: "/XObject <</P 9 0 R>>", extra: { pdf in pdf.stream(9, "/Type /XObject /Subtype /PS", "1 0 moveto") })
        StandardsKit.assertContains(try StandardsKit.clauses(file), "6.2.9")
    }
}
