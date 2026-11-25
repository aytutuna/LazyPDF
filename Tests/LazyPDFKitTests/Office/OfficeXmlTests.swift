import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Office/XmlTreeTests.cs: the same cases.

final class OfficeXmlTests: XCTestCase {
    private func read(_ xml: String, _ limits: OfficeXmlLimits = .standard) throws -> OfficeXmlElement {
        try OfficeXml.parse(Array(xml.utf8), limits)
    }

    private func problem(_ xml: String, _ limits: OfficeXmlLimits = .standard) -> PdfReadProblem? {
        do {
            _ = try read(xml, limits)
            return nil
        } catch let e as PdfReadException {
            return e.problem
        } catch {
            return nil
        }
    }

    func test_goldenFile() throws {
        let actual = OfficeXmlGolden.run(try Golden.input("xml", "xml-input.txt"))
        // The golden file is long: name the lines that differ before the byte comparison says only that they do.
        let expected = try Golden.input("xml", "xml-output.txt").components(separatedBy: "\n")
        let lines = actual.components(separatedBy: "\n")
        var shown = 0
        for i in 0..<min(lines.count, expected.count) where lines[i] != expected[i] && shown < 12 {
            XCTFail("line \(i + 1)\n  expected \(expected[i])\n  actual   \(lines[i])")
            shown += 1
        }
        if lines.count != expected.count { XCTFail("expected \(expected.count) lines, actual \(lines.count)") }
        try Golden.check("xml", "xml-output.txt", actual)
    }

    func test_readsWordProcessingNamespaces() throws {
        let w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
        let doc = try read("<w:document xmlns:w=\"\(w)\"><w:body><w:p><w:r><w:t xml:space=\"preserve\"> a </w:t></w:r><w:r><w:t>b</w:t></w:r></w:p></w:body></w:document>")
        let runs = doc.child(w, "body")!.child(w, "p")!.elements(w, "r")
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs[0].child(w, "t")!.text, " a ")
        XCTAssertEqual(runs[0].child(w, "t")!.attribute("http://www.w3.org/XML/1998/namespace", "space"), "preserve")
        XCTAssertNil(doc.child("", "body"))
    }

    func test_attributeWithoutPrefixHasNoNamespace() throws {
        let e = try read("<a xmlns=\"urn:d\" x=\"1\"/>")
        XCTAssertEqual(e.uri, "urn:d")
        XCTAssertEqual(e.attribute("x"), "1")
        XCTAssertNil(e.attribute("urn:d", "x"))
    }

    func test_externalEntityIsRefusedNotFetched() {
        XCTAssertEqual(problem("<!DOCTYPE a [<!ENTITY x SYSTEM \"file:///c:/windows/win.ini\">]><a>&x;</a>"), .unsupported)
    }

    func test_billionLaughsIsRefusedAtTheDoctype() {
        XCTAssertEqual(problem("<!DOCTYPE l [<!ENTITY a \"aaaa\"><!ENTITY b \"&a;&a;&a;&a;\">]><l>&b;&b;</l>"), .unsupported)
    }

    func test_deepNestingIsRefusedWithoutOverflow() {
        XCTAssertEqual(problem(String(repeating: "<a>", count: 200_000)), .unsupported)
    }

    func test_depthAtTheLimitReads() throws {
        let xml = String(repeating: "<a>", count: 1000) + String(repeating: "</a>", count: 1000)
        let e = try read(xml, OfficeXmlLimits(maxDepth: 1000))
        var depth = 1
        var next = e.elements.first
        while let n = next {
            depth += 1
            next = n.elements.first
        }
        XCTAssertEqual(depth, 1000)
    }

    func test_manyElementsAreRefused() throws {
        let xml = "<a>" + String(repeating: "<b/>", count: 1000) + "</a>"
        XCTAssertEqual(problem(xml, OfficeXmlLimits(maxElements: 999)), .unsupported)
        XCTAssertEqual(try read(xml, OfficeXmlLimits(maxElements: 1001)).elements.count, 1000)
    }

    func test_manyAttributesAreRefused() {
        let xml = "<a " + (0..<5000).map { "x\($0)=\"1\"" }.joined(separator: " ") + "/>"
        XCTAssertEqual(problem(xml), .unsupported)
    }

    func test_runOfAmpersandsIsFast() {
        let start = Date()
        XCTAssertNotNil(problem("<a>" + String(repeating: "&", count: 200_000) + "</a>"))
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func test_largeTextReadsInOneNode() throws {
        let text = String(repeating: "x", count: 5_000_000)
        let e = try read("<a>\(text)<!-- c -->\(text)</a>")
        XCTAssertEqual(e.children.count, 1)
        XCTAssertEqual(e.text.utf16.count, 10_000_000)
    }

    func test_randomBytesNeverCrash() {
        var state: UInt64 = 7
        func next(_ n: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(n))
        }
        let seed = Array("<?xml version=\"1.0\"?><a xmlns:p=\"urn:p\" p:x=\"&amp;\"><p:b>t&#65;<![CDATA[c]]></p:b><!-- c --></a>".utf8)
        for n in 0..<3000 {
            var d = seed
            for _ in 0..<(1 + next(4)) { d[next(d.count)] = UInt8(next(256)) }
            if n % 3 == 0 { d = Array(d[..<next(d.count)]) }
            _ = try? OfficeXml.parse(d)
        }
    }
}
