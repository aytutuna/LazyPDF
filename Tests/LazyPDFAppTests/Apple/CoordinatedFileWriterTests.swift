#if canImport(Darwin)
import XCTest
@testable import LazyPDFApp

// No Windows twin. The iOS target repeats these through a tab (ios/LazyPDFiOSTests/CoordinatedWriteTests).

final class CoordinatedFileWriterTests: XCTestCase {
    private func folder() throws -> TempDir {
        let dir = TempDir(self)
        try FileManager.default.createDirectory(at: dir.url, withIntermediateDirectories: true)
        return dir
    }

    func test_theBytesReplaceTheFileWhereItLies() throws {
        let dir = try folder()
        let url = dir.sub("a.pdf")
        try Data("old".utf8).write(to: url)

        try CoordinatedFileWriter().write(to: url) { try Data("new".utf8).write(to: $0) }

        XCTAssertEqual(try Data(contentsOf: url), Data("new".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.url.path), ["a.pdf"])
    }

    func test_aFileThatIsNotThereYetIsCreated() throws {
        let url = try folder().sub("new.pdf")

        try CoordinatedFileWriter().write(to: url) { try Data("bytes".utf8).write(to: $0) }

        XCTAssertEqual(try Data(contentsOf: url), Data("bytes".utf8))
    }

    func test_aFailedWriteLeavesTheFileAsItWas() throws {
        let url = try folder().sub("a.pdf")
        try Data("old".utf8).write(to: url)

        XCTAssertThrowsError(try CoordinatedFileWriter().write(to: url) { _ in throw CocoaError(.fileWriteUnknown) })

        XCTAssertEqual(try Data(contentsOf: url), Data("old".utf8))
    }
}
#endif
