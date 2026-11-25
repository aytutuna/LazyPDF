import Foundation
import LazyPDFKit

// Mirrors the Pdfs class of windows/LazyPDF.App.Tests/StandIns.cs, for the Apple service tests.

enum ApplePdfs {
    static func text(pages: Int = 1, line: String = "Hello from the tests.") throws -> [UInt8] {
        let text = (0..<pages).map { "\(line) Page \($0 + 1)." }.joined(separator: "\u{0C}")
        return try PdfFromText.create(text).bytes
    }

    /// A file of the fixtures (Tests/Fixtures/Documents) by name.
    static func fixture(_ name: String) throws -> [UInt8] {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return [UInt8](try Data(contentsOf: tests.appendingPathComponent("Fixtures/Documents/\(name)")))
    }

    /// One page of `media` with a black square of 50 points at the bottom left of the media box and nothing else.
    static func square(media: [Int] = [0, 0, 200, 100], crop: [Int]? = nil, rotate: Int = 0, unit: Double? = nil) -> [UInt8] {
        var page = "<< /Type /Page /Parent 2 0 R /MediaBox [\(media.map(String.init).joined(separator: " "))] /Contents 4 0 R"
        if let crop { page += " /CropBox [\(crop.map(String.init).joined(separator: " "))]" }
        if rotate != 0 { page += " /Rotate \(rotate)" }
        if let unit { page += " /UserUnit \(unit)" }
        page += " >>"
        let content = "0 g \(media[0]) \(media[1]) 50 50 re f"
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
}
