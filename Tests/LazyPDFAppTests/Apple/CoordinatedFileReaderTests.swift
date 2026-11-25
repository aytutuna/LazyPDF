#if canImport(Darwin)
import XCTest
@testable import LazyPDFApp

// No Windows twin.

final class CoordinatedFileReaderTests: XCTestCase {
    func test_theBytesOfAFileAreRead() throws {
        let dir = TempDir(self)
        let url = dir.file("a.pdf", [1, 2, 3])

        XCTAssertEqual(try CoordinatedFileReader.read(url), Data([1, 2, 3]))
    }

    func test_aFileThatIsNotThereIsAnError() {
        let dir = TempDir(self)

        XCTAssertThrowsError(try CoordinatedFileReader.read(dir.sub("none.pdf")))
    }
}
#endif
