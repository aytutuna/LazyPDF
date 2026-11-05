import Foundation
@testable import LazyPDFKit

// Twin of windows/LazyPDF.Core.Tests/Fonts/Programs/ProgramFonts.cs: installed fonts the program tests read. A
// missing file gives nil and the test returns early. The Windows fonts folder is the C# one; on the other systems
// the tests that need it return early.

enum ProgramFonts {
    private static let otfCandidates = [
        "C:\\Program Files\\Android\\Android Studio\\jbr\\lib\\fonts\\Inter-Regular.otf",
        "/usr/share/fonts/opentype/inter/Inter-Regular.otf",
    ]

    private static let namedCandidates = [
        "C:\\Program Files\\Android\\Android Studio\\jbr\\lib\\fonts\\DroidSerif-Regular.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    ]

    private static func read(_ path: String) -> [UInt8]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return [UInt8](data)
    }

    /// A TrueType font whose post table (format 2) carries glyph names; the Windows system fonts use format 3.
    static func named() -> [UInt8]? {
        for path in namedCandidates {
            if let data = read(path) { return data }
        }
        return nil
    }

    static func windows(_ name: String) -> [UInt8]? {
        guard let root = ProcessInfo.processInfo.environment["WINDIR"] else { return nil }
        return read(root + "\\Fonts\\" + name)
    }

    static func otf() -> [UInt8]? {
        for path in otfCandidates {
            if let data = read(path) { return data }
        }
        return nil
    }

    /// Position of a table's directory entry in a plain sfnt file, -1 when absent.
    static func directoryEntry(_ font: [UInt8], _ tag: String) -> Int {
        let count = (Int(font[4]) << 8) | Int(font[5])
        for i in 0..<count {
            let at = 12 + 16 * i
            if Latin1.string(Array(font[at..<at + 4])) == tag { return at }
        }
        return -1
    }

    static func tableOffset(_ font: [UInt8], _ tag: String) -> Int {
        let e = directoryEntry(font, tag)
        return e < 0 ? -1 : (Int(font[e + 8]) << 24) | (Int(font[e + 9]) << 16) | (Int(font[e + 10]) << 8) | Int(font[e + 11])
    }

    /// The generator the damage tests use in place of System.Random: the same bytes on every run.
    struct Random {
        private var state: UInt64

        init(_ seed: UInt64) {
            state = seed
        }

        mutating func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(bound))
        }
    }
}
