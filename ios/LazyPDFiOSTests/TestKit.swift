import XCTest
import LazyPDFKit
import LazyPDFApp

/// A folder in the app's temporary folder for one test, removed with it.
func scratch(_ test: XCTestCase) -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lazypdf-tests-" + UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    test.addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
    return folder
}

func samplePdf(_ line: String = "Hello from the tests.") throws -> [UInt8] {
    try PdfFromText.create(line).bytes
}

/// Reports every page as drawable and draws nothing.
final class StubRenderer: DocumentRenderer {
    func load(_ session: PdfEditSession, _ password: String?) -> Bool { true }
    func pageSize(_ pageIndex: Int) -> (width: Double, height: Double) { (200, 300) }
    func render(_ pageIndex: Int, _ dpi: Double) -> PdfRgbaImage? { nil }
    func close() {}
}
