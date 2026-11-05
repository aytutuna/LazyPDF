import Foundation

// What Encoding.Latin1 is in the C# engine: one scalar per byte, U+0000 to U+00FF. Names, keywords and
// string text read from a file keep their bytes this way.
enum Latin1 {
    static func string(_ bytes: [UInt8]) -> String {
        var scalars = String.UnicodeScalarView()
        for byte in bytes { scalars.append(Unicode.Scalar(byte)) }
        return String(scalars)
    }

    /// A scalar past U+00FF becomes "?", as Encoding.Latin1 does.
    static func bytes(_ text: String) -> [UInt8] {
        text.unicodeScalars.map { $0.value <= 0xFF ? UInt8($0.value) : 0x3F }
    }
}
