import Foundation

// The files of Tests/Fixtures/golden/signatures: a certificate and its key written by the C# (PdfDigitalIdInteropTests)
// and the PFX file the Swift writer made from them, which the C# opens.

enum SignatureFixtures {
    static let folder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures").appendingPathComponent("golden").appendingPathComponent("signatures")

    static let password = "pass word"

    static func read(_ name: String) throws -> [UInt8] {
        [UInt8](try Data(contentsOf: folder.appendingPathComponent(name)))
    }
}
