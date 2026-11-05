import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Content/InterpreterGraphicsTests.cs: the same cases.

final class InterpreterGraphicsTests: XCTestCase {
    private func run(_ content: String, _ resources: String = "", _ objects: [String] = []) throws -> Recorder {
        ContentTestPdf.run(try ContentTestPdf.page(content, resources, objects))
    }

    func test_rectangleFillReportsBoundsAndColour() throws {
        let r = try run("1 0 0 rg 10 20 100 50 re f")
        XCTAssertEqual(r.paths.count, 1)
        let (path, state) = r.paths[0]
        XCTAssertEqual(path.operator, "f")
        XCTAssertTrue(path.fill)
        XCTAssertFalse(path.stroke)
        XCTAssertEqual(path.bounds, PdfRect(10, 20, 110, 70))
        XCTAssertEqual(state.fillColor.rgb, RgbColor(255, 0, 0))
        XCTAssertEqual(state.fillColor.space.family, "DeviceRGB")
        XCTAssertEqual(path.segments.count, 5)
    }

    func test_strokeBoundsGrowByHalfTheLineWidth() throws {
        let path = try run("10 w 0 0 100 100 re S").paths[0].path
        XCTAssertTrue(path.stroke)
        XCTAssertEqual(path.inkBounds, PdfRect(-5, -5, 105, 105))
        XCTAssertEqual(path.bounds, PdfRect(0, 0, 100, 100))
    }

    func test_pathsAreInTheStartingSpace() throws {
        let path = try run("q 2 0 0 2 100 100 cm 0 0 10 10 re f Q").paths[0].path
        XCTAssertEqual(path.bounds, PdfRect(100, 100, 120, 120))
    }

    func test_curvesCountTheirControlPoints() throws {
        let path = try run("0 0 m 50 100 100 100 150 0 c f").paths[0].path
        XCTAssertEqual(path.bounds.top, 100)
        XCTAssertEqual(path.segments[1].kind, .curve)
        let v = try run("10 10 m 50 60 90 10 v f").paths[0].path.segments[1]
        XCTAssertEqual(v.x1, 10)
        XCTAssertEqual(v.y1, 10)
        let y = try run("10 10 m 50 60 90 10 y f").paths[0].path.segments[1]
        XCTAssertEqual(y.x2, 90)
        XCTAssertEqual(y.y2, 10)
    }

    func test_clipShrinksTheBoundingBox() throws {
        let r = try run("0 0 100 100 re W n 50 50 200 200 re f 20 20 10 10 re W n 0 0 5 5 re f")
        XCTAssertEqual(r.paths.count, 4)
        XCTAssertTrue(r.paths[0].path.clips)
        XCTAssertEqual(r.paths[0].path.operator, "n")
        XCTAssertEqual(r.paths[1].state.clip, PdfRect(0, 0, 100, 100))
        XCTAssertEqual(r.paths[3].state.clip, PdfRect(20, 20, 30, 30))
    }

    func test_thePageCropBoxIsTheFirstClip() throws {
        XCTAssertEqual(try run("0 0 1 1 re f").paths[0].state.clip, PdfRect(0, 0, 600, 800))
    }

    func test_qAndQRestoreTheState() throws {
        let r = try run("q 5 w 1 0 0 rg 2 0 0 2 0 0 cm Q 0 0 1 1 re S")
        let state = r.paths[0].state
        XCTAssertEqual(state.lineWidth, 1)
        XCTAssertEqual(state.ctm, PdfMatrix.identity)
        XCTAssertEqual(state.fillColor.rgb, RgbColor(0, 0, 0))
    }

    func test_anUnmatchedQIsIgnoredAndTheStackIsCapped() throws {
        let content = "Q Q " + String(repeating: "q 2 w ", count: 1000) + String(repeating: "Q ", count: 1000) + "0 0 1 1 re S"
        let state = try run(content).paths[0].state
        XCTAssertEqual(state.lineWidth, 1)
    }

    func test_lineStateAndDash() throws {
        let s = try run("3 w 1 J 2 j 4 M [3 2] 1 d 0 0 1 1 re S").paths[0].state
        XCTAssertEqual(s.lineWidth, 3)
        XCTAssertEqual(s.lineCap, 1)
        XCTAssertEqual(s.lineJoin, 2)
        XCTAssertEqual(s.miterLimit, 4)
        XCTAssertEqual(s.dash, [3.0, 2.0])
        XCTAssertEqual(s.dashPhase, 1)
    }

    func test_extGStateSetsAlphaBlendAndLines() throws {
        let s = try run("/G gs 0 0 1 1 re f", "/ExtGState <</G <</CA 0.5 /ca 0.25 /BM /Multiply /LW 7 /SMask /None>>>>").paths[0].state
        XCTAssertEqual(s.strokeAlpha, 0.5)
        XCTAssertEqual(s.fillAlpha, 0.25)
        XCTAssertEqual(s.blendMode, "Multiply")
        XCTAssertEqual(s.lineWidth, 7)
        XCTAssertNil(s.softMask)
    }

    func test_colourSpacesAndValues() throws {
        let resources = "/ColorSpace <</Cs1 [/Separation /Spot /DeviceCMYK <</FunctionType 2 /Domain [0 1] /C0 [0 0 0 0] /C1 [0 1 1 0] /N 1>>] /Cs2 [/Indexed /DeviceRGB 1 <FF0000 00FF00>]>>"
        let r = try run("/Cs1 cs 1 sc 0 0 1 1 re f /Cs2 cs 1 sc 0 0 1 1 re f 0 0 0 1 k 0 0 1 1 re f 0.5 g 0 0 1 1 re f 0 1 0 0 K 0 0 1 1 re S", resources)
        XCTAssertEqual(r.paths[0].state.fillColor.space.family, "Separation")
        XCTAssertEqual(r.paths[0].state.fillColor.rgb, RgbColor(255, 0, 0))
        XCTAssertEqual(r.paths[1].state.fillColor.space.family, "Indexed")
        XCTAssertEqual(r.paths[1].state.fillColor.rgb, RgbColor(0, 255, 0))
        XCTAssertEqual(r.paths[2].state.fillColor.rgb, RgbColor(0, 0, 0))
        XCTAssertEqual(r.paths[3].state.fillColor.rgb, RgbColor(128, 128, 128))
        XCTAssertEqual(r.paths[4].state.strokeColor.space.family, "DeviceCMYK")
    }

    func test_initialColourOfASpaceIsBlackOrFull() throws {
        let r = try run("/DeviceCMYK cs 0 0 1 1 re f")
        XCTAssertEqual(r.paths[0].state.fillColor.components, [0.0, 0, 0, 1])
    }

    func test_imageXObjectsReportPlacementAndSize() throws {
        let document = try ContentTestPdf.page("q 100 0 0 50 10 20 cm /Im Do Q", "/XObject <</Im 5 0 R>>") { pdf in
            pdf.stream(5, "/Type /XObject /Subtype /Image /Width 8 /Height 4 /ColorSpace /DeviceGray /BitsPerComponent 8", [UInt8](repeating: 0, count: 32))
        }
        let r = ContentTestPdf.run(document)
        XCTAssertEqual(r.images.count, 1)
        let i = r.images[0]
        XCTAssertEqual(i.name, "Im")
        XCTAssertEqual(i.width, 8)
        XCTAssertEqual(i.height, 4)
        XCTAssertFalse(i.isMask)
        XCTAssertEqual(i.bounds, PdfRect(10, 20, 110, 70))
        XCTAssertNotNil(i.stream)
    }

    func test_inlineImagesAreExpandedAndPlaced() throws {
        let r = try run("q 40 0 0 40 5 5 cm BI /W 2 /H 2 /BPC 8 /CS /G ID abcd\nEI Q")
        XCTAssertEqual(r.images.count, 1)
        let i = r.images[0]
        XCTAssertNil(i.name)
        XCTAssertNotNil(i.inline)
        XCTAssertEqual(i.width, 2)
        XCTAssertEqual(i.height, 2)
        XCTAssertEqual(i.bounds, PdfRect(5, 5, 45, 45))
        XCTAssertNotNil(i.dictionary["BitsPerComponent"])
    }

    func test_shadingsAreReported() throws {
        let r = try run("0 0 50 50 re W n /Sh sh", "/Shading <</Sh <</ShadingType 2 /ColorSpace /DeviceRGB /Coords [0 0 1 1]>>>>")
        XCTAssertEqual(r.shadings.count, 1)
        XCTAssertEqual(r.shadings[0].bounds, PdfRect(0, 0, 50, 50))
        XCTAssertTrue(r.shadings[0].shading is PdfDictionary)
    }

    func test_markedContentCarriesMcidAndOptionalContent() throws {
        let r = try run("/Span <</MCID 4>> BDC /OC /Lyr BDC /P1 BMC 0 0 1 1 re f EMC EMC EMC",
                        "/Properties <</Lyr 5 0 R>>", ["<</Type /OCG /Name (Layer)>>"])
        XCTAssertEqual(r.events, ["begin Span 4", "begin OC", "begin P1", "end P1", "end OC", "end Span"])
        XCTAssertEqual(r.`where`[0].mcid, 4)
    }

    func test_anMcidOutsideTheIntRangeIsNoStructureElement() throws {
        let r = try run("/Span <</MCID 4294967301>> BDC 0 0 1 1 re f EMC")
        XCTAssertEqual(r.events, ["begin Span", "end Span"])
        XCTAssertNil(r.`where`[0].mcid)
    }

    func test_boundsAreNotANumberWhenTheMatrixOverflows() throws {
        let big = "1" + String(repeating: "0", count: 308)
        let path = try run("\(big) 0 0 \(big) 0 0 cm \(big) 0 0 \(big) 0 0 cm 0 0 5 5 re f").paths[0].path
        XCTAssertTrue(path.bounds.left.isNaN)
        XCTAssertTrue(path.bounds.top.isNaN)
    }

    func test_unclosedMarkedContentIsClosedAtTheEnd() throws {
        let r = try run("/A BMC /B BMC 0 0 1 1 re f")
        XCTAssertEqual(r.events, ["begin A", "begin B", "end B", "end A"])
    }

    func test_extraEmcIsIgnored() throws {
        XCTAssertTrue(try run("EMC EMC 0 0 1 1 re f").events.isEmpty)
    }

    func test_optionalContentIsOnTheContext() throws {
        var seen: PdfDictionary?
        let document = try ContentTestPdf.page("/OC /Lyr BDC 0 0 1 1 re f EMC", "/Properties <</Lyr 5 0 R>>", ["<</Type /OCG /Name (L)>>"])
        ContentInterpreter(document).run(document.pages[0], OcVisitor { seen = $0 })
        XCTAssertNotNil(seen)
        XCTAssertEqual((seen?["Type"] as? PdfName)?.value, "OCG")
    }

    private final class OcVisitor: ContentVisitor {
        private let found: (PdfDictionary?) -> Void

        init(_ found: @escaping (PdfDictionary?) -> Void) {
            self.found = found
            super.init()
        }

        override func paintPath(_ context: ContentContext, _ path: PathInfo) {
            found(context.optionalContent)
        }
    }
}
