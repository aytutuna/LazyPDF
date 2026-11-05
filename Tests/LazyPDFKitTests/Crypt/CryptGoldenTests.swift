import XCTest

// Mirrors windows/LazyPDF.Core.Tests/Crypt/CryptGoldenTests.cs: the same cases. The golden files, the certificates
// and the sealed files are written by the Windows tests. Without Security.framework the publickey cases are left
// out of both sides of the comparison.

final class CryptGoldenTests: XCTestCase {
    func test_cryptOutputIsTheGoldenFile() throws {
        let actual = try CryptGolden.run(try Golden.input("crypt", "crypt-input.txt"))
        if CryptGolden.hasPublicKey {
            try Golden.check("crypt", "crypt-output.txt", actual)
            return
        }
        var lines = try Golden.input("crypt", "crypt-output.txt").split(separator: "\n", omittingEmptySubsequences: true).map { String($0) }
        var expected = ""
        while !lines.isEmpty {
            let asked = lines.removeFirst()
            let answer = lines.removeFirst()
            if !asked.hasPrefix("> publickey ") { expected += asked + "\n" + answer + "\n" }
        }
        XCTAssertEqual(Array(actual.utf8), Array(expected.utf8))
    }
}
