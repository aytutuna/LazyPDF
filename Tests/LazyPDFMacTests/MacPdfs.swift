#if os(macOS)
import Foundation
import LazyPDFKit

// The files of the Mac tests: built by the engine, or read from Tests/Fixtures/Documents.
enum MacPdfs {
    static func text(pages: Int = 1) throws -> [UInt8] {
        let text = (0..<pages).map { "Hello from the tests. Page \($0 + 1)." }.joined(separator: "\u{0C}")
        return try PdfFromText.create(text).bytes
    }

    /// One page of 100 by 100 units with a black square, at /UserUnit `unit`.
    static func square(unit: Double? = nil) -> [UInt8] {
        let content = "0 g 0 0 50 50 re f"
        let page = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Contents 4 0 R" + (unit.map { " /UserUnit \($0)" } ?? "") + " >>"
        let objects = ["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>", page,
                       "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream"]
        var file = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (i, body) in objects.enumerated() {
            offsets.append(file.utf8.count)
            file += "\(i + 1) 0 obj\n\(body)\nendobj\n"
        }
        let start = file.utf8.count
        file += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { file += String(format: "%010d 00000 n \n", offset) }
        file += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(start)\n%%EOF\n"
        return Array(file.utf8)
    }

    static func fixture(_ name: String) throws -> [UInt8] {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return [UInt8](try Data(contentsOf: tests.appendingPathComponent("Fixtures/Documents/\(name)")))
    }
}
#endif
