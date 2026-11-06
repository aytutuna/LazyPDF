import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Standards/PdfAScopeTests.cs: the same cases.

final class PdfAScopeTests: XCTestCase {
    private let noIntent = ""
    private let blue = "0 0 1 rg 0 0 5 5 re f"

    private func linkWith(_ action: String, _ level: PdfALevel = .a2b) -> [UInt8] {
        StandardsKit.compliant(level, page: "/Annots [9 0 R]", extra: { pdf in
            pdf.obj(9, "<</Type /Annot /Subtype /Link /Rect [10 10 50 50] /F 4 /Border [0 0 0] /A \(action)>>")
        })
    }

    private func outline(_ first: String, _ second: String, _ level: PdfALevel = .a2b) -> [UInt8] {
        StandardsKit.compliant(level, catalog: "/Outlines 9 0 R", extra: { pdf in
            pdf.obj(9, "<</Type /Outlines /First 10 0 R /Last 11 0 R /Count 2>>")
            pdf.obj(10, "<</Title (a) /Parent 9 0 R /Next 11 0 R \(first)>>")
            pdf.obj(11, "<</Title (b) /Parent 9 0 R /Prev 10 0 R \(second)>>")
        })
    }

    /// Two pages; the second paints `second` with no resources of its own.
    private func twoPages(_ firstResources: String, _ second: String, _ intents: String = "") -> [UInt8] {
        StandardsKit.compliant(resources: firstResources, extra: { pdf in
            pdf.obj(2, "<</Type /Pages /Kids [3 0 R 12 0 R] /Count 2 /MediaBox [0 0 200 300]>>")
            pdf.obj(12, "<</Type /Page /Parent 2 0 R /Contents 13 0 R /Resources << >>>>")
            pdf.stream(13, "", second)
        }, intents: intents)
    }

    func test_theDeprecatedActionsAreForbidden() throws {
        for type in ["NOP", "SetState"] {
            StandardsKit.assertContains(try StandardsKit.clauses(linkWith("<</S /\(type)>>")), "6.5.1")
            StandardsKit.assertContains(try StandardsKit.clauses(linkWith("<</S /\(type)>>", .a1b), .a1b), "6.6.1")
        }
    }

    func test_actionsOfBookmarksAreChecked() throws {
        try StandardsKit.assertClean(outline("/A << /S /GoTo /D [3 0 R /Fit] >>", "/Dest [3 0 R /Fit]"))
        StandardsKit.assertHas(try StandardsKit.check(outline("/A << /S /JavaScript /JS (1) >>", "")).issues) { $0.clause == "6.5.1" && $0.where == "Outlines" }
        StandardsKit.assertContains(try StandardsKit.clauses(outline("", "/A << /S /GoTo /D [3 0 R /Fit] /Next << /S /Launch >> >>")), "6.5.1")
        StandardsKit.assertContains(try StandardsKit.clauses(outline("/A << /S /Launch >>", "", .a1b), .a1b), "6.6.1")
    }

    func test_onlyAPdfAIntentSetsWhatDeviceColourIsAllowed() throws {
        let other = StandardsKit.compliant(content: blue, extra: { pdf in
            pdf.obj(6, "<</Type /OutputIntent /S /GTS_PDFX /OutputConditionIdentifier (x) /DestOutputProfile 7 0 R>>")
        })
        StandardsKit.assertContains(try StandardsKit.clauses(other), "6.2.4.3")
        try StandardsKit.assertClean(StandardsKit.compliant(content: blue))
    }

    func test_anIntentProfileMustBeOfClassPrtrOrMntr() throws {
        for kind in ["scnr", "spac", "abst"] {
            let file = try StandardsKit.edited(StandardsKit.compliant()) { d in
                let intents = try XCTUnwrap(d.array(d.catalog, "OutputIntents"))
                let intent = try XCTUnwrap(d.resolve(intents.items[0]) as? PdfDictionary)
                let profile = try XCTUnwrap(d.stream(intent, "DestOutputProfile"))
                var copy = PdfASrgb.srgbProfile
                copy.replaceSubrange(12..<16, with: Array(kind.utf8))
                profile.data = copy
            }
            StandardsKit.assertHas(try StandardsKit.check(file).issues, kind) { $0.clause == "6.2.3" && $0.where == "Output intent" && $0.message.contains(kind) }
            StandardsKit.assertContains(try StandardsKit.clauses(file), "6.2.4.3")
        }
    }

    func test_aDefaultSpaceOnlyCountsInItsOwnResources() throws {
        let file = twoPages("/ColorSpace <</DefaultRGB [/ICCBased 7 0 R]>>", blue)
        StandardsKit.assertHas(try StandardsKit.check(file).issues) { $0.clause == "6.2.4.3" && $0.where == "Page 2" }
        StandardsKit.assertNone(try StandardsKit.check(file).issues) { $0.where == "Page 1" }

        let own = StandardsKit.compliant(content: "/Fm Do", resources: "/XObject <</Fm 9 0 R>>", extra: { pdf in
            pdf.stream(9, "/Type /XObject /Subtype /Form /BBox [0 0 10 10] /Resources << /ColorSpace <</DefaultRGB [/ICCBased 7 0 R]>> >>", self.blue)
        }, intents: noIntent)
        try StandardsKit.assertClean(own)

        let page = StandardsKit.compliant(content: "/Fm Do", resources: "/XObject <</Fm 9 0 R>> /ColorSpace <</DefaultRGB [/ICCBased 7 0 R]>>", extra: { pdf in
            pdf.stream(9, "/Type /XObject /Subtype /Form /BBox [0 0 10 10] /Resources << >>", self.blue)
        }, intents: noIntent)
        StandardsKit.assertContains(try StandardsKit.clauses(page), "6.2.4.3")
    }

    func test_aColourSpaceOrImageThatNothingPaintsWithIsNotAUse() throws {
        try StandardsKit.assertClean(StandardsKit.compliant(content: "", resources: "/ColorSpace <</CS0 /DeviceRGB>>", intents: noIntent))
        let unused = StandardsKit.compliant(content: "", resources: "/XObject <</Im0 9 0 R>>", extra: { pdf in
            pdf.stream(9, "/Type /XObject /Subtype /Image /Width 1 /Height 1 /BitsPerComponent 8 /ColorSpace /DeviceRGB", [UInt8](repeating: 0, count: 3))
        }, intents: noIntent)
        try StandardsKit.assertClean(unused)
        let drawn = StandardsKit.compliant(content: "q 10 0 0 10 0 0 cm /Im0 Do Q", resources: "/XObject <</Im0 9 0 R>>", extra: { pdf in
            pdf.stream(9, "/Type /XObject /Subtype /Image /Width 1 /Height 1 /BitsPerComponent 8 /ColorSpace /DeviceRGB", [UInt8](repeating: 0, count: 3))
        }, intents: noIntent)
        StandardsKit.assertContains(try StandardsKit.clauses(drawn), "6.2.4.3")
        let named = StandardsKit.compliant(content: "/CS0 cs 0 0 1 sc 0 0 5 5 re f", resources: "/ColorSpace <</CS0 /DeviceRGB>>", intents: noIntent)
        StandardsKit.assertContains(try StandardsKit.clauses(named), "6.2.4.3")
    }
}
