import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Office/OfficeFontSourceTests.cs. The input format is at the top of chain-input.txt.

final class OfficeFontSourceTests: XCTestCase {
    private final class FakeSource: FontSource {
        let families: Set<String>

        init(_ families: [String]) {
            self.families = Set(families.map { $0.lowercased() })
        }

        func find(_ family: String, _ style: FontStyles) -> FontFile? {
            families.contains(family.lowercased()) ? FontFile(Array("\(family)/\(style.rawValue)".utf8)) : nil
        }
    }

    private func source(_ list: Substring) -> FontSource? {
        list == "-" ? nil : FakeSource(list.split(separator: ",").map(String.init))
    }

    private func run(_ input: String) -> String {
        var output = ""
        for line in input.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty || line.hasPrefix("# ") { continue }
            let w = line.split(separator: "|", omittingEmptySubsequences: false)
            let family = String(decoding: Golden.unescape(String(w[2])), as: UTF8.self)
            let style: FontStyles = w[3] == "b" ? .bold : w[3] == "i" ? .italic : w[3] == "bi" ? [.bold, .italic] : .regular
            let found = OfficeFontSource(installed: source(w[0]), bundled: source(w[1])).find(family, style)
            output += "> \(line)\n"
            output += "< \(found.map { String(decoding: $0.data, as: UTF8.self) } ?? "none")\n"
        }
        return output
    }

    func test_goldenFile() throws {
        try Golden.check("office-fonts", "chain-output.txt", run(try Golden.input("office-fonts", "chain-input.txt")))
    }

    func test_installedFontComesBeforeTheBundledOne() {
        let found = OfficeFontSource(installed: FakeSource(["Calibri"]), bundled: FakeSource(["Carlito"])).find("Calibri", .regular)
        XCTAssertEqual(String(decoding: found!.data, as: UTF8.self), "Calibri/0")
    }

    // The fonts in fonts/ are what make the bundled families stand in for Word's: the advance of A in units of 2048.
    func test_bundledFontsKeepTheMetricsOfWordsFonts() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fonts")
        let cases = [("carlito/Carlito-Regular", 1185), ("liberation/LiberationSans-Regular", 1366),
                     ("liberation/LiberationSerif-Regular", 1479), ("liberation/LiberationMono-Regular", 1229)]
        for (file, advance) in cases {
            let bytes = [UInt8](try Data(contentsOf: folder.appendingPathComponent(file + ".ttf")))
            let font = try XCTUnwrap(TrueTypeFont.tryParse(bytes))
            XCTAssertEqual(font.unitsPerEm, 2048, file)
            XCTAssertEqual(font.getAdvance(font.glyphForCodePoint(65)), advance, file)
        }
    }
}
