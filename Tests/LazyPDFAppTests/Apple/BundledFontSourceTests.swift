import Foundation
import LazyPDFApp
import LazyPDFKit
import XCTest

// Mirrors windows/LazyPDF.App.Tests/BundledFontSourceTests.cs. The tests read fonts/ in the repo, the folder the
// Xcode projects copy flat into the bundle.

final class BundledFontSourceTests: XCTestCase {
    private let fonts = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fonts")

    // The repo keeps one folder per family; the bundle is flat.
    private func flatCopy() throws -> URL {
        let flat = FileManager.default.temporaryDirectory.appendingPathComponent("bundled-fonts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: flat, withIntermediateDirectories: true)
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: fonts, includingPropertiesForKeys: nil))
        for case let url as URL in walker where url.pathExtension == "ttf" {
            try FileManager.default.copyItem(at: url, to: flat.appendingPathComponent(url.lastPathComponent))
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: flat) }
        return flat
    }

    func test_shipsEveryFaceOfTheFamily() throws {
        let source = BundledFontSource(folder: try flatCopy())
        for family in ["Carlito", "Caladea", "Liberation Sans", "Liberation Serif", "Liberation Mono"] {
            for style: FontStyles in [.regular, .bold, .italic, [.bold, .italic]] {
                let file = try XCTUnwrap(source.find(family, style), "\(family) \(style.rawValue)")
                XCTAssertNotNil(TrueTypeFont.tryParse(file.data), family)
            }
        }
    }

    func test_pathLikeFamilyGivesNothing() throws {
        let source = BundledFontSource(folder: try flatCopy())
        for family in ["//host/share/x", "/etc/passwd", "../Carlito", "..\\Carlito"] {
            XCTAssertNil(source.find(family, .regular), family)
        }
    }

    func test_unknownFamilyOrFolderGivesNothing() throws {
        XCTAssertNil(BundledFontSource(folder: try flatCopy()).find("Comic Sans MS", .regular))
        XCTAssertNil(BundledFontSource(folder: URL(fileURLWithPath: "/no-such-fonts")).find("Carlito", .regular))
        XCTAssertNil(BundledFontSource(folder: nil).find("Carlito", .regular))
    }
}
