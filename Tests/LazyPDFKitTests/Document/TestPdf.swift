import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Document/TestPdf.cs: builds small PDF files byte by byte, so that a test can
// break exactly one thing.

final class TestPdf {
    private var bytes: [UInt8] = []
    private var offsets: [Int: Int] = [:]

    init(_ header: String = "%PDF-1.4\n") {
        write(header)
    }

    var position: Int { bytes.count }

    static func latin(_ text: String) -> [UInt8] { Latin1.bytes(text) }

    static func text(_ bytes: [UInt8]) -> String { Latin1.string(bytes) }

    static func deflate(_ data: [UInt8]) -> [UInt8] { PdfFilterEncoders.flate(data, .fastest) }

    @discardableResult
    func write(_ text: String) -> TestPdf {
        bytes.append(contentsOf: Self.latin(text))
        return self
    }

    @discardableResult
    func obj(_ number: Int, _ body: String) -> TestPdf {
        offsets[number] = position
        return write("\(number) 0 obj\n\(body)\nendobj\n")
    }

    /// A stream object; `length` is what /Length says (the data's length when nil, omitted when negative).
    @discardableResult
    func stream(_ number: Int, _ entries: String, _ data: [UInt8], length: Int? = nil, endstream: Bool = true) -> TestPdf {
        offsets[number] = position
        var declared = "/Length \(length ?? data.count)"
        if let length, length < 0 { declared = "" }
        write("\(number) 0 obj\n<<\(entries) \(declared)>>\nstream\n")
        bytes.append(contentsOf: data)
        return write(endstream ? "\nendstream\nendobj\n" : "\nendobj\n")
    }

    @discardableResult
    func stream(_ number: Int, _ entries: String, _ data: String, length: Int? = nil, endstream: Bool = true) -> TestPdf {
        stream(number, entries, Self.latin(data), length: length, endstream: endstream)
    }

    /// The classic table and trailer, and the file; `shift` moves every offset by that much.
    func finish(_ trailer: String = "/Root 1 0 R", shift: Int = 0, startxref: String = "") -> [UInt8] {
        let start = position
        let size = (offsets.keys.max() ?? 0) + 1
        var text = "xref\n0 \(size)\n0000000000 65535 f \n"
        for n in 1..<size {
            if let offset = offsets[n] {
                text += String(format: "%010ld 00000 n \n", offset + shift)
            } else {
                text += "0000000000 00000 f \n"
            }
        }
        text += "trailer\n<</Size \(size) \(trailer)>>\nstartxref\n\(startxref.isEmpty ? String(start) : startxref)\n%%EOF\n"
        return bytes + Self.latin(text)
    }

    func finishWithoutXref() -> [UInt8] { bytes }

    /// A catalog (1), a page tree (2) and `count` pages (3...), each with a content stream after them.
    static func withPages(_ count: Int) -> TestPdf {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        let kids = (0..<count).map { "\(3 + $0) 0 R" }.joined(separator: " ")
        pdf.obj(2, "<</Type /Pages /Kids [\(kids)] /Count \(count) /MediaBox [0 0 200 300]>>")
        for i in 0..<count { pdf.obj(3 + i, "<</Type /Page /Parent 2 0 R /Contents \(3 + count + i) 0 R>>") }
        for i in 0..<count { pdf.stream(3 + count + i, "", "BT /F1 12 Tf (\(i + 1)) Tj ET") }
        return pdf
    }

    static func simple(_ count: Int = 2) -> [UInt8] { withPages(count).finish() }

    /// The file with the first `find` replaced by `replacement`.
    static func replace(_ file: [UInt8], _ find: String, _ replacement: String) -> [UInt8] {
        guard let at = file.indexOf(latin(find)) else {
            preconditionFailure("\"\(find)\" is not in the file.")
        }
        return Array(file[0..<at]) + latin(replacement) + Array(file[(at + find.count)...])
    }
}

/// Assert.Same.
func assertSame(_ a: AnyObject?, _ b: AnyObject?, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(a === b, "not the same instance", file: file, line: line)
}

/// Assert.Throws<PdfReadException>, and the problem it carries when one is given.
func assertReadFails<T>(_ expression: @autoclosure () throws -> T, _ problem: PdfReadProblem? = nil, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertThrowsError(try expression(), file: file, line: line) { error in
        guard let failure = error as? PdfReadException else {
            XCTFail("not a PdfReadException: \(error)", file: file, line: line)
            return
        }
        if let problem { XCTAssertEqual(failure.problem, problem, file: file, line: line) }
    }
}

func temporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lazypdf-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

extension TestPdf {
    /// Whether `bytes`, read as Latin-1, contain `text`.
    static func contains(_ bytes: [UInt8], _ text: String) -> Bool {
        bytes.indexOf(latin(text)) != nil
    }
}
