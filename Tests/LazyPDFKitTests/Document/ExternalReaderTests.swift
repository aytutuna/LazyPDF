import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Document/ExternalReaderTests.cs: pypdf as a third reader. Does nothing where
// Python or pypdf is missing (LAZYPDF_PYTHON names the interpreter, "python3" is tried otherwise).

final class ExternalReaderTests: XCTestCase {
    private static let script = """
        import sys, os, warnings, logging
        logging.disable(logging.CRITICAL)
        warnings.filterwarnings("ignore")
        from pypdf import PdfReader
        folder = sys.argv[1]
        for name in sorted(os.listdir(folder)):
            try:
                reader = PdfReader(os.path.join(folder, name), strict=True)
                if reader.is_encrypted:
                    reader.decrypt("")
                print(name, len(reader.pages), reader.metadata.title, reader.pages[1].extract_text().strip())
            except Exception as e:
                print(name, "ERROR", type(e).__name__, e)
        """

    private func run(_ folder: URL) -> String? {
        let python = ProcessInfo.processInfo.environment["LAZYPDF_PYTHON"] ?? "python3"
        func start(_ arguments: [String]) -> (status: Int32, output: String)? {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [python] + arguments
            process.currentDirectoryURL = folder
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            do {
                try process.run()
            } catch {
                return nil
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }
        guard let probe = start(["-c", "import pypdf"]), probe.status == 0 else { return nil }
        return start(["-c", Self.script, folder.path])?.output
    }

    func test_pypdfReadsWhatIsWritten() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var expected: [String: String] = [:]
        for kind in SaveFixtures.kinds {
            var document = try PdfDocument.open(SaveFixtures.make(kind))
            try SaveFixtures.edit(document, "Edited title")
            try Data(try document.saveIncremental()).write(to: folder.appendingPathComponent("\(kind)-update.pdf"))
            expected["\(kind)-update.pdf"] = "2 Edited title Changed"

            document = try PdfDocument.open(SaveFixtures.make(kind))
            for packed in [false, true] {
                let name = "\(kind)-rewrite\(packed ? "-packed" : "").pdf"
                try Data(try document.saveRewrite(PdfSaveOptions(useObjectStreams: packed, security: document.security)))
                    .write(to: folder.appendingPathComponent(name))
                expected[name] = "2 Original title Page two"
            }
        }

        guard let result = run(folder) else { return }
        let lines = result.components(separatedBy: "\n").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\r")) }
            .filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, expected.count)
        for (name, text) in expected { XCTAssertTrue(lines.contains("\(name) \(text)"), name) }
    }
}
