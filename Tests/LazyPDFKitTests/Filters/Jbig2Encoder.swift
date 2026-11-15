import Foundation
import XCTest
@testable import LazyPDFKit

// Twin of windows/LazyPDF.Core.Tests/Filters/Jbig2Encoder.cs, as far as the tests of this side need it: the MQ encoder of
// T.88 Annex E, the generic region procedure run backwards, and segment bytes. The text, symbol and halftone encoders are
// left out; the streams they make are the golden files, which are read here, not made.

extension DotNetRandom {
    /// System.Random.Next(min, max).
    mutating func next(_ low: Int, _ high: Int) -> Int { low + next(high - low) }
}

/// A bilevel image, one byte per pixel, 1 black.
final class Bm {
    let width: Int
    let height: Int
    var px: [UInt8]

    init(_ width: Int, _ height: Int) {
        self.width = width
        self.height = height
        px = [UInt8](repeating: 0, count: width * height)
    }

    subscript(x: Int, y: Int) -> Int {
        get { x < 0 || y < 0 || x >= width || y >= height ? 0 : Int(px[y * width + x]) }
        set { px[y * width + x] = UInt8(newValue) }
    }

    /// Strokes and blocks like printed text, with a few stray dots, from a fixed seed.
    static func text(_ width: Int, _ height: Int, _ seed: Int) -> Bm {
        let bm = Bm(width, height)
        var random = DotNetRandom(seed)
        for _ in 0..<(width * height / 60 + 3) {
            let w = random.next(1, 9), h = random.next(1, 14)
            let x = random.next(width), y = random.next(height)
            let hollow = random.next(3) == 0
            for j in 0..<h {
                for i in 0..<w {
                    let edge = i == 0 || j == 0 || i == w - 1 || j == h - 1
                    if x + i < width && y + j < height && (!hollow || edge) { bm[x + i, y + j] = 1 }
                }
            }
        }
        for _ in 0..<(width * height / 80) {
            let x = random.next(width), y = random.next(height)
            bm[x, y] = bm[x, y] ^ 1
        }
        return bm
    }

    /// What the filter gives for this page: packed rows with black 0.
    func packed() -> [UInt8] {
        let stride = (width + 7) / 8
        var bytes = [UInt8](repeating: 0xff, count: stride * height)
        for y in 0..<height {
            for x in 0..<width where px[y * width + x] != 0 { bytes[y * stride + (x >> 3)] &= ~UInt8(0x80 >> (x & 7)) }
        }
        return bytes
    }
}

/// The MQ encoder (E.2) and the context sets of one coded segment, the mirror of `Jbig2Arith`.
final class ArithEncoder {
    private static let qe: [Int] = [
        0x5601, 0x3401, 0x1801, 0x0AC1, 0x0521, 0x0221, 0x5601, 0x5401, 0x4801, 0x3801, 0x3001, 0x2401, 0x1C01, 0x1601, 0x5601,
        0x5401, 0x5101, 0x4801, 0x3801, 0x3401, 0x3001, 0x2801, 0x2401, 0x2201, 0x1C01, 0x1801, 0x1601, 0x1401, 0x1201, 0x1101,
        0x0AC1, 0x09C1, 0x08A1, 0x0521, 0x0441, 0x02A1, 0x0221, 0x0141, 0x0111, 0x0085, 0x0049, 0x0025, 0x0015, 0x0009, 0x0005,
        0x0001, 0x5601,
    ]
    private static let nmps: [Int] = [
        1, 2, 3, 4, 5, 38, 7, 8, 9, 10, 11, 12, 13, 29, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32,
        33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 45, 46,
    ]
    private static let nlps: [Int] = [
        1, 6, 9, 12, 29, 33, 6, 14, 14, 14, 17, 18, 20, 21, 14, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28,
        29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 46,
    ]

    private var out: [UInt8] = [0]
    private var c: UInt32 = 0
    private var a = 0x8000
    private var ct = 12

    let gb = Jbig2Contexts(1 << 16)
    let gr = Jbig2Contexts(1 << 13)
    private let ints = (0..<13).map { _ in Jbig2Contexts(512) }

    /// A.2: a value, or nil for the out-of-band value.
    func integer(_ procedure: Int, _ value: Int?) {
        let contexts = ints[procedure]
        var prev = 1
        func put(_ bit: Int) {
            self.bit(contexts, prev, bit)
            prev = prev < 256 ? (prev << 1) | bit : (((prev << 1) | bit) & 511) | 256
        }
        func bits(_ v: Int, _ count: Int) {
            for i in stride(from: count - 1, through: 0, by: -1) { put((v >> i) & 1) }
        }
        let magnitude = value.map { abs($0) } ?? 0
        put(value == nil || value! < 0 ? 1 : 0)
        if magnitude < 4 { put(0); bits(magnitude, 2) }
        else if magnitude < 20 { put(1); put(0); bits(magnitude - 4, 4) }
        else if magnitude < 84 { put(1); put(1); put(0); bits(magnitude - 20, 6) }
        else if magnitude < 340 { put(1); put(1); put(1); put(0); bits(magnitude - 84, 8) }
        else if magnitude < 4436 { put(1); put(1); put(1); put(1); put(0); bits(magnitude - 340, 12) }
        else { put(1); put(1); put(1); put(1); put(1); bits(magnitude - 4436, 32) }
    }

    func bit(_ contexts: Jbig2Contexts, _ pos: Int, _ d: Int) {
        var index = Int(contexts[pos]) >> 1, mps = Int(contexts[pos]) & 1
        let qe = Self.qe[index]
        a -= qe
        if d == mps {
            if a & 0x8000 == 0 {
                if a < qe { a = qe } else { c = c &+ UInt32(qe) }
                index = Self.nmps[index]
                renorm()
            } else {
                c = c &+ UInt32(qe)
            }
        } else {
            if a < qe { c = c &+ UInt32(qe) } else { a = qe }
            if index == 0 || index == 6 || index == 14 { mps = 1 - mps }
            index = Self.nlps[index]
            renorm()
        }
        contexts[pos] = UInt8((index << 1) | mps)
    }

    private func renorm() {
        repeat {
            a <<= 1
            c <<= 1
            ct -= 1
            if ct == 0 { byteOut() }
        } while a & 0x8000 == 0
    }

    private func byteOut() {
        if out[out.count - 1] == 0xff {
            out.append(UInt8(truncatingIfNeeded: c >> 20))
            c &= 0xfffff
            ct = 7
        } else if c < 0x8000000 {
            out.append(UInt8(truncatingIfNeeded: c >> 19))
            c &= 0x7ffff
            ct = 8
        } else {
            out[out.count - 1] &+= 1
            if out[out.count - 1] == 0xff {
                c &= 0x7ffffff
                out.append(UInt8(truncatingIfNeeded: c >> 20))
                c &= 0xfffff
                ct = 7
            } else {
                out.append(UInt8(truncatingIfNeeded: c >> 19))
                c &= 0x7ffff
                ct = 8
            }
        }
    }

    /// E.2.9 FLUSH, ending the data with the marker 0xFF 0xAC.
    func finish() -> [UInt8] {
        let temp = c &+ UInt32(a)
        c |= 0xffff
        if c >= temp { c -= 0x8000 }
        c <<= UInt32(ct)
        byteOut()
        c <<= UInt32(ct)
        byteOut()
        if out[out.count - 1] == 0xff { out.removeLast() }
        out.append(0xff)
        out.append(0xac)
        return Array(out.dropFirst())
    }
}

enum Jbig2Encode {
    /// The data of a symbol dictionary segment (7.4.2) with one symbol, coded with the arithmetic coder and exported.
    static func oneSymbolDictionary(_ symbol: Bm) -> [UInt8] {
        let e = ArithEncoder()
        e.integer(Jbig2Arith.iadh, symbol.height)
        e.integer(Jbig2Arith.iadw, symbol.width)
        generic(e, symbol, 0, false)
        e.integer(Jbig2Arith.iadw, nil)
        e.integer(Jbig2Arith.iaex, 0)
        e.integer(Jbig2Arith.iaex, 1)
        return Jbig2Segments.cat(Jbig2Segments.u16(0), Jbig2Segments.at(defaultAt(0)), Jbig2Segments.u32(1), Jbig2Segments.u32(1), e.finish())
    }

    /// The data of a text region segment (7.4.3) of one instance of the only symbol at (x, y), reference corner at the top left.
    static func oneInstanceText(_ width: Int, _ height: Int, x: Int, y: Int) -> [UInt8] {
        let e = ArithEncoder()
        e.integer(Jbig2Arith.iadt, 0)
        e.integer(Jbig2Arith.iadt, y)
        e.integer(Jbig2Arith.iafs, x)
        // One symbol has a symbol id of no bits.
        e.integer(Jbig2Arith.iads, nil)
        // Flags: the top left reference corner.
        return Jbig2Segments.cat(Jbig2Segments.regionInfo(width, height), Jbig2Segments.u16(1 << 4), Jbig2Segments.u32(1), e.finish())
    }

    private static let reused = [0x9b25, 0x0795, 0x00e5, 0x0195]

    /// The nominal adaptive pixels of Figures 3 to 6 and 7.
    static func defaultAt(_ template: Int) -> [Int] { template == 0 ? [3, -1, -3, -1, 2, -2, -2, -2] : template == 1 ? [3, -1] : [2, -1] }

    // Offsets of the template pixels in the order of the context bits from the highest (Figures 3 to 6).
    private static func pixels(_ template: Int, _ at: [Int]) -> [(x: Int, y: Int)] {
        switch template {
        case 0: return [(at[6], at[7]), (-1, -2), (0, -2), (1, -2), (at[4], at[5]), (at[2], at[3]), (-2, -1), (-1, -1), (0, -1), (1, -1), (2, -1), (at[0], at[1]), (-4, 0), (-3, 0), (-2, 0), (-1, 0)]
        case 1: return [(-1, -2), (0, -2), (1, -2), (2, -2), (-2, -1), (-1, -1), (0, -1), (1, -1), (2, -1), (at[0], at[1]), (-3, 0), (-2, 0), (-1, 0)]
        case 2: return [(-1, -2), (0, -2), (1, -2), (-2, -1), (-1, -1), (0, -1), (1, -1), (at[0], at[1]), (-2, 0), (-1, 0)]
        default: return [(-3, -1), (-2, -1), (-1, -1), (0, -1), (1, -1), (at[0], at[1]), (-4, 0), (-3, 0), (-2, 0), (-1, 0)]
        }
    }

    /// 6.2: codes `bm` with the generic region procedure.
    static func generic(_ e: ArithEncoder, _ bm: Bm, _ template: Int, _ typicalPrediction: Bool, _ at: [Int]? = nil) {
        let list = pixels(template, at ?? defaultAt(template))
        var ltp = 0
        for y in 0..<bm.height {
            if typicalPrediction {
                var same = true
                for x in 0..<bm.width { same = same && bm[x, y] == bm[x, y - 1] }
                let next = same ? 1 : 0
                e.bit(e.gb, reused[template], next ^ ltp)
                ltp = next
                if same { continue }
            }
            for x in 0..<bm.width {
                var label = 0
                for (dx, dy) in list { label = (label << 1) | bm[x + dx, y + dy] }
                e.bit(e.gb, label, bm[x, y])
            }
        }
    }
}

/// Segment and field bytes (7.2 and 7.4).
enum Jbig2Segments {
    static func u32(_ v: Int) -> [UInt8] { [UInt8(truncatingIfNeeded: v >> 24), UInt8(truncatingIfNeeded: v >> 16), UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)] }

    static func u16(_ v: Int) -> [UInt8] { [UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)] }

    static func cat(_ parts: [UInt8]...) -> [UInt8] { parts.flatMap { $0 } }

    /// A segment: header, then data. The page association is page 1, or 0 for the globals.
    static func segment(_ number: Int, _ type: Int, _ data: [UInt8], _ referred: [Int] = [], page: Int = 1) -> [UInt8] {
        var header = u32(number)
        header.append(UInt8(type))
        if referred.count <= 4 {
            header.append(UInt8(referred.count << 5))
        } else {
            header += u32(0xe0000000 | referred.count)
            header += [UInt8](repeating: 0, count: (referred.count + 8) / 8)
        }
        for r in referred {
            if number <= 256 { header.append(UInt8(r)) } else if number <= 65536 { header += u16(r) } else { header += u32(r) }
        }
        header.append(UInt8(page))
        header += u32(data.count)
        return header + data
    }

    static func pageInfo(_ width: Int, _ height: Int, _ flags: Int = 0) -> [UInt8] {
        cat(u32(width), u32(height), u32(0), u32(0), [UInt8(flags)], u16(0))
    }

    static func regionInfo(_ width: Int, _ height: Int, _ x: Int = 0, _ y: Int = 0, _ op: Int = 0) -> [UInt8] {
        cat(u32(width), u32(height), u32(x), u32(y), [UInt8(op)])
    }

    static func at(_ values: [Int]) -> [UInt8] { values.map { UInt8(bitPattern: Int8($0)) } }

    /// A generic region segment's data (7.4.6) around the coded bytes.
    static func genericData(_ bm: Bm, _ coded: [UInt8], _ template: Int, _ mmr: Bool, _ typicalPrediction: Bool, _ adaptive: [Int]?, x: Int = 0, y: Int = 0, op: Int = 0) -> [UInt8] {
        let flags = (mmr ? 1 : 0) | template << 1 | (typicalPrediction ? 8 : 0)
        return cat(regionInfo(bm.width, bm.height, x, y, op), [UInt8(flags)], mmr ? [] : at(adaptive ?? Jbig2Encode.defaultAt(template)), coded)
    }

    /// A whole embedded stream: page information and one immediate generic region.
    static func generic(_ bm: Bm, _ template: Int, _ typicalPrediction: Bool, _ adaptive: [Int]? = nil) -> [UInt8] {
        let e = ArithEncoder()
        Jbig2Encode.generic(e, bm, template, typicalPrediction, adaptive)
        return cat(segment(0, 48, pageInfo(bm.width, bm.height)),
                   segment(1, 38, genericData(bm, e.finish(), template, false, typicalPrediction, adaptive)))
    }
}

/// The streams of the golden folder, which the Windows tests make with the encoders there.
enum Jbig2Samples {
    private static let folder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures").appendingPathComponent("golden").appendingPathComponent("filters")

    static func file(_ name: String) throws -> [UInt8] {
        [UInt8](try Data(contentsOf: folder.appendingPathComponent(name)))
    }

    /// The names of the streams the input of the golden test uses, each once.
    static func names() throws -> [String] {
        var seen: [String] = []
        for line in try Golden.input("filters", "jbig2-input.txt").split(separator: "\n") where line.hasPrefix("jbig2 ") {
            let name = String(line.split(separator: " ")[1])
            if !seen.contains(name) { seen.append(name) }
        }
        return seen
    }

    static func globals() throws -> [UInt8] { try file("globals.bin") }

    /// A 64 by 40 picture whose text region draws symbols of the globals.
    static func withGlobals() throws -> [UInt8] { try file("with-globals.bin") }

    /// The /DecodeParms dictionary that names `globals`.
    static func parameters(_ globals: [UInt8]) -> PdfDictionary {
        let parameters = PdfDictionary()
        parameters["JBIG2Globals"] = PdfStream(PdfDictionary(), data: globals)
        return parameters
    }

    /// The page of the picture with globals, as the filter returns it.
    static func withGlobalsPage() throws -> [UInt8] {
        try PdfFilters.decode(try withGlobals(), PdfName("JBIG2Decode"), parameters(try globals()))
    }
}
