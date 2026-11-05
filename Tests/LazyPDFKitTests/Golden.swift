import XCTest

// Twin of windows/LazyPDF.Core.Tests/Golden.cs. Swift only reads the golden files; C# writes them.

enum Golden {
    private static let folder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures").appendingPathComponent("golden")

    private static func text(_ layer: String, _ name: String) throws -> String {
        let url = folder.appendingPathComponent(layer).appendingPathComponent(name)
        return String(decoding: try Data(contentsOf: url), as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
    }

    static func input(_ layer: String, _ name: String) throws -> String {
        try text(layer, name)
    }

    /// Compares `actual` with the golden file Tests/Fixtures/golden/layer/name, byte for byte.
    static func check(_ layer: String, _ name: String, _ actual: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let expected = try text(layer, name)
        XCTAssertEqual(Array(actual.utf8), Array(expected.utf8), name, file: file, line: line)
    }

    static func unescape(_ text: String) -> [UInt8] {
        let scalars = Array(text.unicodeScalars)
        var bytes: [UInt8] = []
        var i = 0
        while i < scalars.count {
            if scalars[i] != "\\" {
                bytes.append(UInt8(truncatingIfNeeded: scalars[i].value))
                i += 1
                continue
            }
            i += 1
            guard i < scalars.count else { break }
            switch scalars[i] {
            case "n": bytes.append(10)
            case "r": bytes.append(13)
            case "t": bytes.append(9)
            case "x":
                let digits = String(String.UnicodeScalarView(scalars[(i + 1)..<min(i + 3, scalars.count)]))
                bytes.append(UInt8(digits, radix: 16) ?? 0)
                i += 2
            default: bytes.append(UInt8(truncatingIfNeeded: scalars[i].value))
            }
            i += 1
        }
        return bytes
    }

    static func escape(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                if scalar.value < 0x20 || scalar.value >= 0x7F {
                    result += "\\x" + String(format: "%02x", scalar.value & 0xFF)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result
    }

    static func escape(_ bytes: [UInt8]) -> String {
        escape(String(String.UnicodeScalarView(bytes.map { Unicode.Scalar($0) })))
    }
}
