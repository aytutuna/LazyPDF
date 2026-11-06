import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Export/PptxWriterTests.cs: the same cases. The relationship targets are resolved
// against their folder by hand, where the C# uses Uri.

final class PptxWriterTests: XCTestCase {
    private let a = "http://schemas.openxmlformats.org/drawingml/2006/main"
    private let p = "http://schemas.openxmlformats.org/presentationml/2006/main"
    private let r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    private let rel = "http://schemas.openxmlformats.org/package/2006/relationships"

    private func model() throws -> ExportDocument { try ExportLayout.analyze(ExportKit.report()) }

    private func attribute(_ element: XmlElement, _ name: String) -> String? { element.attribute(XmlName("", name))?.value }

    func test_aSlideForEachPageSizedAsThePage() throws {
        let package = try PptxWriter.make(model())
        let presentation = try ExportKit.part(package, "ppt/presentation.xml")
        XCTAssertEqual(ExportKit.descendants(presentation, p, "sldId").count, 3)
        let sizes = ExportKit.descendants(presentation, p, "sldSz")
        XCTAssertEqual(sizes.count, 1)
        XCTAssertEqual(Int(attribute(sizes[0], "cx") ?? ""), 612 * 12700)
        XCTAssertEqual(Int(attribute(sizes[0], "cy") ?? ""), 792 * 12700)
    }

    func test_everyRelationshipTargetsAPartAndEveryPartIsWellFormed() throws {
        let package = try PptxWriter.make(model())
        let entries = try ExportKit.entries(package)
        for e in entries where e.hasSuffix(".xml") || e.hasSuffix(".rels") { _ = try ExportKit.part(package, e) }
        for rels in entries where rels.hasSuffix(".rels") {
            let folder = rels.range(of: "_rels/").map { String(rels[..<$0.lowerBound]) } ?? ""
            for item in ExportKit.descendants(try ExportKit.part(package, rels), rel, "Relationship") {
                let target = attribute(item, "Target") ?? ""
                var path = folder.split(separator: "/").map(String.init)
                for piece in target.split(separator: "/") {
                    if piece == ".." { _ = path.popLast() } else if piece != "." { path.append(String(piece)) }
                }
                XCTAssertTrue(entries.contains(path.joined(separator: "/")), "\(rels): \(target)")
            }
        }
        let types = try ExportKit.unzip(package, "[Content_Types].xml")
        for i in 1...3 { XCTAssertTrue(types.contains("/ppt/slides/slide\(i).xml")) }
    }

    func test_everyLineIsATextBoxAtItsPlace() throws {
        let model = try model()
        let package = try PptxWriter.make(model)
        let slide = try ExportKit.part(package, "ppt/slides/slide1.xml")
        let boxes = ExportKit.descendants(slide, p, "sp")
        XCTAssertEqual(boxes.count, model.pages[0].lines.count)
        let headings = boxes.filter { $0.value == "Annual Report" }
        XCTAssertEqual(headings.count, 1)
        let offsets = ExportKit.descendants(headings[0], a, "off")
        XCTAssertEqual(offsets.count, 1)
        let lines = model.pages[0].lines.filter { $0.text == "Annual Report" }
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(Int(attribute(offsets[0], "x") ?? ""), Int((lines[0].bounds.x * 12700).rounded(.toNearestOrEven)))
        XCTAssertEqual(Int(attribute(offsets[0], "y") ?? ""), Int((lines[0].bounds.y * 12700).rounded(.toNearestOrEven)))
        let runs = ExportKit.descendants(headings[0], a, "rPr")
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(attribute(runs[0], "b"), "1")
        XCTAssertEqual(attribute(runs[0], "sz"), "2400")
    }

    func test_thePictureIsPlacedAndSharedBetweenSlides() throws {
        let package = try PptxWriter.make(model())
        let slide = try ExportKit.part(package, "ppt/slides/slide1.xml")
        let pictures = ExportKit.descendants(slide, p, "pic")
        XCTAssertEqual(pictures.count, 1)
        let ext = ExportKit.descendants(pictures[0], a, "ext")
        XCTAssertEqual(ext.count, 1)
        XCTAssertEqual(Int(attribute(ext[0], "cx") ?? ""), 96 * 12700)
        XCTAssertEqual(Int(attribute(ext[0], "cy") ?? ""), 72 * 12700)
        let blips = ExportKit.descendants(pictures[0], a, "blip")
        XCTAssertEqual(blips.count, 1)
        let id = blips[0].attribute(XmlName(r, "embed"))?.value
        let targets = ExportKit.descendants(try ExportKit.part(package, "ppt/slides/_rels/slide1.xml.rels"), rel, "Relationship").filter { attribute($0, "Id") == id }
        XCTAssertEqual(targets.count, 1)
        XCTAssertEqual(attribute(targets[0], "Target"), "../media/image1.jpg")
        XCTAssertEqual(try ExportKit.entries(package).filter { $0.hasPrefix("ppt/media/") }.count, 1)
    }

    func test_aBiggerPageIsScaledIntoTheSlide() throws {
        let small = ExportPage(0, 100, 100, [], [ExportTextLine(DisplayRect(10, 10, 50, 10), [ExportRun("A", false, false, 10)])], [])
        let big = ExportPage(1, 200, 200, [], [ExportTextLine(DisplayRect(20, 20, 100, 20), [ExportRun("B", false, true, 20)])], [])
        let package = try PptxWriter.make(ExportDocument(nil, [small, big], 10))
        let runs = ExportKit.descendants(try ExportKit.part(package, "ppt/slides/slide2.xml"), a, "rPr")
        XCTAssertEqual(runs.count, 1)
        // The slide takes the first page's size and the bigger page shrinks into it.
        XCTAssertEqual(attribute(runs[0], "i"), "1")
        XCTAssertLessThan(Int(attribute(runs[0], "sz") ?? "") ?? Int.max, 2000)
    }

    func test_turkishTextIsKept() throws {
        let line = ExportTextLine(DisplayRect(10, 10, 200, 14), [ExportRun("İstanbul ğüşıöç", false, false, 12)])
        let package = try PptxWriter.make(ExportDocument(nil, [ExportPage(0, 612, 792, [], [line], [])], 12))
        let texts = ExportKit.descendants(try ExportKit.part(package, "ppt/slides/slide1.xml"), a, "t")
        XCTAssertEqual(texts.map { $0.value }, ["İstanbul ğüşıöç"])
    }

    func test_aDocumentWithoutPagesHasNoSlides() throws {
        let package = try PptxWriter.make(ExportDocument(nil, [], 11))
        XCTAssertFalse(try ExportKit.unzip(package, "ppt/presentation.xml").contains("sldIdLst"))
    }
}
