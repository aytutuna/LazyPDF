import XCTest
@testable import LazyPDFKit

// No C# twin: the Turkish Kit table that scripts/gen_l10n.py writes is what L10n looks the Swift texts up in.

final class KitStringsTests: XCTestCase {
    private func table() throws -> [String: String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("l10n").appendingPathComponent("out").appendingPathComponent("apple")
            .appendingPathComponent("tr.lproj").appendingPathComponent("Kit.strings")
        var result: [String: String] = [:]
        for line in String(decoding: try Data(contentsOf: url), as: UTF8.self).split(separator: "\n") where line.hasPrefix("\"") && line.hasSuffix("\";") {
            let pair = line.dropFirst().dropLast(2).components(separatedBy: "\" = \"")
            guard pair.count == 2 else { continue }
            result[unquote(pair[0])] = unquote(pair[1])
        }
        return result
    }

    private func unquote(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: "\n").replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
    }

    func test_theTurkishTableTranslatesTheWordsOfTheAnnotationsLayer() throws {
        let tr = try table()
        L10n.withTable(tr, language: "tr") {
            XCTAssertEqual(AnnotationText.statusName(.rejected), "Reddedildi")
            XCTAssertEqual(L10n.bare(AnnotationText.statusSetBy(.rejected, "Deniz")), "Reddedildi, Deniz tarafından ayarlandı")
            XCTAssertEqual(AnnotationText.kindName(.freeText), "Metin kutusu")
        }
        XCTAssertEqual(AnnotationText.statusName(.rejected), "Rejected")
    }
}
