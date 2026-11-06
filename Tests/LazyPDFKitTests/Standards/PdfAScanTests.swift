import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Standards/PdfAScanTests.cs: the same cases.

final class PdfAScanTests: XCTestCase {
    private let helvetica = "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding>>"
    private let courier = "<</Type /Font /Subtype /Type1 /BaseFont /Courier /Encoding /WinAnsiEncoding>>"
    private let cell = "/PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 10 10] /XStep 10 /YStep 10 /Resources <</Font <</F2 12 0 R>>>>"

    private func reports(_ file: [UInt8], _ clause: String, _ place: String) throws -> Bool {
        try StandardsKit.check(file).issues.contains { $0.clause == clause && $0.where == place }
    }

    func test_aFontInATilingCellIsFoundWhenTextOrAMaskIsPaintedWithIt() throws {
        for painting in ["BT /F1 12 Tf 20 20 Td (A) Tj ET", "/Im Do"] {
            let file = StandardsKit.compliant(content: "/Pattern cs /P scn " + painting, resources: "/Font <</F1 11 0 R>> /Pattern <</P 9 0 R>> /XObject <</Im 10 0 R>>", extra: { pdf in
                pdf.stream(9, self.cell, "BT /F2 12 Tf (A) Tj ET")
                pdf.stream(10, "/Type /XObject /Subtype /Image /Width 1 /Height 1 /BitsPerComponent 1 /ImageMask true", " ")
                pdf.obj(11, self.helvetica)
                pdf.obj(12, self.courier)
            })
            XCTAssertTrue(try reports(file, "6.2.11.4.1", "Font Courier"), painting)
        }
    }

    func test_aFontInATilingCellIsFoundWhenAPathIsPaintedWithIt() throws {
        let file = StandardsKit.compliant(content: "/Pattern cs /P scn 0 0 10 10 re f", resources: "/Pattern <</P 9 0 R>>", extra: { pdf in
            pdf.stream(9, self.cell, "BT /F2 12 Tf (A) Tj ET")
            pdf.obj(12, self.courier)
        })
        XCTAssertTrue(try reports(file, "6.2.11.4.1", "Font Courier"))
    }

    private let type3 = "<</Type /Font /Subtype /Type3 /FontBBox [0 0 10 10] /FontMatrix [0.001 0 0 0.001 0 0] /CharProcs <</a 11 0 R /b 13 0 R>> "
        + "/Encoding <</Type /Encoding /Differences [97 /a /b]>> /FirstChar 97 /LastChar 98 /Widths [500 500] /Resources <<%@>>>>"

    private func glyphs(_ shown: String, _ procedure: String, _ resources: String) -> [UInt8] {
        let font = type3.replacingOccurrences(of: "%@", with: resources)
        return StandardsKit.compliant(content: "BT /F1 12 Tf 20 20 Td (\(shown)) Tj ET", resources: "/Font <</F1 9 0 R>>", extra: { pdf in
            pdf.obj(9, font)
            pdf.stream(11, "", "500 0 d0")
            pdf.stream(13, "", procedure)
            pdf.stream(12, "/Type /XObject /Subtype /Image /Width 1 /Height 1 /BitsPerComponent 8 /ColorSpace /DeviceCMYK", "    ")
        })
    }

    func test_aDeviceSpaceUsedInAGlyphProcedureCountsAsUsed() throws {
        let cases = [
            ("500 0 d0 /Sh sh", "/Shading <</Sh <</ShadingType 2 /ColorSpace /DeviceCMYK /Coords [0 0 1 0] /Function <</FunctionType 2 /Domain [0 1] /C0 [0 0 0 0] /C1 [1 1 1 1] /N 1>>>>>>"),
            ("500 0 d0 /C cs 0 sc 0 0 5 5 re f", "/ColorSpace <</C [/Indexed /DeviceCMYK 0 <00000000>]>>"),
            ("500 0 d0 /Im Do", "/XObject <</Im 12 0 R>>"),
        ]
        for (procedure, resources) in cases {
            StandardsKit.assertContains(try StandardsKit.clauses(glyphs("b", procedure, resources)), "6.2.4.3")
        }
    }

    func test_aGlyphThatIsNeverShownDoesNotPaint() throws {
        let resources = "/XObject <</Im 12 0 R>>"
        StandardsKit.assertLacks(try StandardsKit.clauses(glyphs("a", "500 0 d0 /Im Do", resources)), "6.2.4.3")
        StandardsKit.assertContains(try StandardsKit.clauses(glyphs("ab", "500 0 d0 /Im Do", resources)), "6.2.4.3")
    }

    private func masked(_ content: String) -> [UInt8] {
        StandardsKit.compliant(content: content, resources: "/ExtGState <</GS0 <</SMask <</S /Luminosity /G 9 0 R>>>>>>", extra: { pdf in
            pdf.stream(9, "/Type /XObject /Subtype /Form /BBox [0 0 200 300] /Group <</S /Transparency /CS /DeviceGray>> /Resources <</XObject <</Im 12 0 R>>>>", "/Im Do")
            pdf.stream(12, "/Type /XObject /Subtype /Image /Width 1 /Height 1 /BitsPerComponent 8 /ColorSpace /DeviceCMYK", "    ")
        })
    }

    func test_aSoftMaskNobodyAppliesPaintsNothing() throws {
        StandardsKit.assertLacks(try StandardsKit.clauses(masked("0 0 1 rg 20 20 100 100 re f")), "6.2.4.3")
        StandardsKit.assertContains(try StandardsKit.clauses(masked("/GS0 gs 0 0 1 rg 20 20 100 100 re f")), "6.2.4.3")
    }

    func test_aSoftMaskGroupIsHeldToTheContentRulesAndItsNestedMasksAreFollowed() throws {
        let file = StandardsKit.compliant(content: "/GS0 gs 0 0 1 rg 20 20 100 100 re f", resources: "/ExtGState <</GS0 <</SMask <</S /Luminosity /G 9 0 R>>>>>>", extra: { pdf in
            pdf.stream(9, "/Type /XObject /Subtype /Form /BBox [0 0 200 300] /Group <</S /Transparency /CS /DeviceGray>> "
                + "/Resources <</ExtGState <</GS1 <</SMask <</S /Luminosity /G 10 0 R>>>>>>>>", "/GS1 gs <ABC> pop bogus")
            pdf.stream(10, "/Type /XObject /Subtype /Form /BBox [0 0 200 300] /Group <</S /Transparency /CS /DeviceGray>> /Resources <</Font <</F1 11 0 R>>>>", "BT /F1 12 Tf (A) Tj ET")
            pdf.obj(11, self.helvetica)
        })
        let issues = try StandardsKit.check(file).issues
        StandardsKit.assertHas(issues) { $0.clause == "6.2.2" && $0.message == PdfAText.unknownOperator("pop") }
        StandardsKit.assertHas(issues) { $0.clause == "6.1.6" }
        StandardsKit.assertHas(issues) { $0.clause == "6.2.11.4.1" && $0.where == "Font Helvetica" }
    }
}
