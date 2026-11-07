#if os(macOS)
import Foundation
import LazyPDFKit

// The files of the Mac tests: built by the engine, or read from Tests/Fixtures/Documents.
enum MacPdfs {
    static func text(pages: Int = 1) throws -> [UInt8] {
        let text = (0..<pages).map { "Hello from the tests. Page \($0 + 1)." }.joined(separator: "\u{0C}")
        return try PdfFromText.create(text).bytes
    }

    static func fixture(_ name: String) throws -> [UInt8] {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return [UInt8](try Data(contentsOf: tests.appendingPathComponent("Fixtures/Documents/\(name)")))
    }
}
#endif
