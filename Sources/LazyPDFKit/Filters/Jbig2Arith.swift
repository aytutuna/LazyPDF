/* Copyright 2012 Mozilla Foundation
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import Foundation

// Twin of windows/LazyPDF.Core/Filters/Jbig2Arith.cs. Ported to Swift from pdf.js (src/core/arithmetic_decoder.js
// and the integer procedures of src/core/jbig2.js) and changed: the contexts are plain byte arrays kept with the
// decoder, bytes past the end of the data read as 0xFF, and every value is range checked.

/// A set of contexts: one byte each, the state index in the upper seven bits and the more probable symbol in bit 0.
/// A class, as segments share and hand on the same contexts, with storage of its own so that every bit decoded
/// is one load and one store.
final class Jbig2Contexts {
    let count: Int
    private let bytes: UnsafeMutablePointer<UInt8>

    init(_ count: Int) {
        self.count = count
        bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: max(count, 1))
        bytes.initialize(repeating: 0, count: max(count, 1))
    }

    deinit { bytes.deallocate() }

    subscript(index: Int) -> UInt8 {
        get {
            precondition(index >= 0 && index < count)
            return bytes[index]
        }
        set {
            precondition(index >= 0 && index < count)
            bytes[index] = newValue
        }
    }

    func clone() -> Jbig2Contexts {
        let copy = Jbig2Contexts(count)
        copy.copy(from: self)
        return copy
    }

    /// Takes the first `count` contexts of `other`, or all of them if there are fewer.
    func copy(from other: Jbig2Contexts) {
        for i in 0..<min(count, other.count) { bytes[i] = other.bytes[i] }
    }
}

/// The MQ arithmetic decoder of T.88 Annex E (the QM coder of JPEG 2000 Annex C) with the context
/// sets one segment needs: the generic and refinement region contexts and the integer procedures of Annex A.
final class Jbig2Arith {
    private static let qe: [Int] = [
        0x5601, 0x3401, 0x1801, 0x0ac1, 0x0521, 0x0221, 0x5601, 0x5401, 0x4801, 0x3801, 0x3001, 0x2401, 0x1c01, 0x1601, 0x5601,
        0x5401, 0x5101, 0x4801, 0x3801, 0x3401, 0x3001, 0x2801, 0x2401, 0x2201, 0x1c01, 0x1801, 0x1601, 0x1401, 0x1201, 0x1101,
        0x0ac1, 0x09c1, 0x08a1, 0x0521, 0x0441, 0x02a1, 0x0221, 0x0141, 0x0111, 0x0085, 0x0049, 0x0025, 0x0015, 0x0009, 0x0005,
        0x0001, 0x5601,
    ]

    private static let nmps: [UInt8] = [
        1, 2, 3, 4, 5, 38, 7, 8, 9, 10, 11, 12, 13, 29, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32,
        33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 45, 46,
    ]

    private static let nlps: [UInt8] = [
        1, 6, 9, 12, 29, 33, 6, 14, 14, 14, 17, 18, 20, 21, 14, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28,
        29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 46,
    ]

    // The states where the less probable symbol swaps with the more probable one.
    private static let switchState: [Bool] = {
        var table = [Bool](repeating: false, count: 47)
        table[0] = true
        table[6] = true
        table[14] = true
        return table
    }()

    static let iadh = 0, iadw = 1, iaex = 2, iaai = 3, iadt = 4, iafs = 5, iads = 6, iait = 7, iari = 8, iardw = 9, iardh = 10, iardx = 11, iardy = 12
    private static let integerCount = 13

    private let data: [UInt8]
    private let end: Int
    private var bp: Int
    private var chigh = 0
    private var clow = 0
    private var a = 0
    private var ct = 0
    private var iaid: Jbig2Contexts?
    private var integers = [Jbig2Contexts?](repeating: nil, count: integerCount)

    /// Generic region contexts (the largest template has 16 bits).
    var gb: Jbig2Contexts

    /// Generic refinement region contexts (the largest template has 13 bits).
    var gr: Jbig2Contexts

    /// E.3.5 INITDEC: starts decoding the bytes from `start` up to `end`.
    init(_ data: [UInt8], _ start: Int, _ end: Int, refinementContexts: Jbig2Contexts? = nil, budget: Jbig2Budget? = nil) throws {
        try budget?.fixed(refinementContexts == nil ? 80_000 : 0)
        // A decoder that only refines (Huffman coded blocks, one for each symbol) has no use for the other contexts.
        gb = Jbig2Contexts(refinementContexts == nil ? 1 << 16 : 0)
        gr = refinementContexts ?? Jbig2Contexts(1 << 13)
        self.data = data
        self.end = min(end, data.count)
        bp = start
        chigh = at(start)
        byteIn()
        chigh = ((chigh << 7) & 0xffff) | ((clow >> 9) & 0x7f)
        clow = (clow << 7) & 0xffff
        ct -= 7
        a = 0x8000
    }

    private func at(_ index: Int) -> Int { index >= 0 && index < end ? Int(data[index]) : 0xff }

    // E.3.4 BYTEIN
    private func byteIn() {
        if at(bp) == 0xff {
            if at(bp + 1) > 0x8f {
                clow += 0xff00
                ct = 8
            } else {
                bp += 1
                clow += at(bp) << 9
                ct = 7
            }
        } else {
            bp += 1
            clow += bp < end ? Int(data[bp]) << 8 : 0xff00
            ct = 8
        }
        if clow > 0xffff {
            chigh += clow >> 16
            clow &= 0xffff
        }
    }

    /// E.3.2 DECODE: one bit under the context at `pos` of `contexts`.
    func bit(_ contexts: Jbig2Contexts, _ pos: Int) -> Int {
        let state = Int(contexts[pos])
        var index = state >> 1
        var mps = state & 1
        let qe = Jbig2Arith.qe[index]
        let d: Int
        var a = self.a - qe

        if chigh < qe {
            if a < qe {
                a = qe
                d = mps
                index = Int(Jbig2Arith.nmps[index])
            } else {
                a = qe
                d = 1 ^ mps
                if Jbig2Arith.switchState[index] { mps = d }
                index = Int(Jbig2Arith.nlps[index])
            }
        } else {
            chigh -= qe
            if a & 0x8000 != 0 {
                self.a = a
                return mps
            }
            if a < qe {
                d = 1 ^ mps
                if Jbig2Arith.switchState[index] { mps = d }
                index = Int(Jbig2Arith.nlps[index])
            } else {
                d = mps
                index = Int(Jbig2Arith.nmps[index])
            }
        }
        // E.3.3 RENORMD
        repeat {
            if ct == 0 { byteIn() }
            a <<= 1
            chigh = ((chigh << 1) & 0xffff) | ((clow >> 15) & 1)
            clow = (clow << 1) & 0xffff
            ct -= 1
        } while a & 0x8000 == 0
        self.a = a
        contexts[pos] = UInt8((index << 1) | mps)
        return d
    }

    /// A.2: one integer of the procedure whose contexts are `procedure` (`iadh` and so on).
    /// Nil for the out-of-band value.
    func integer(_ procedure: Int) throws -> Int? {
        let contexts: Jbig2Contexts
        if let known = integers[procedure] {
            contexts = known
        } else {
            contexts = Jbig2Contexts(512)
            integers[procedure] = contexts
        }
        var prev = 1
        let sign = readBits(contexts, &prev, 1)
        var v: Int
        if readBits(contexts, &prev, 1) == 0 { v = readBits(contexts, &prev, 2) }
        else if readBits(contexts, &prev, 1) == 0 { v = readBits(contexts, &prev, 4) + 4 }
        else if readBits(contexts, &prev, 1) == 0 { v = readBits(contexts, &prev, 6) + 20 }
        else if readBits(contexts, &prev, 1) == 0 { v = readBits(contexts, &prev, 8) + 84 }
        else if readBits(contexts, &prev, 1) == 0 { v = readBits(contexts, &prev, 12) + 340 }
        else { v = readBits(contexts, &prev, 32) + 4436 }
        if sign != 0 && v == 0 { return nil }
        if sign != 0 { v = -v }
        if v < Int(Int32.min) || v > Int(Int32.max) { throw PdfReadException.damaged("A JBIG2 integer is out of range.") }
        return v
    }

    private func readBits(_ contexts: Jbig2Contexts, _ prev: inout Int, _ length: Int) -> Int {
        var v = 0
        for _ in 0..<length {
            let b = bit(contexts, prev)
            prev = prev < 256 ? (prev << 1) | b : (((prev << 1) | b) & 511) | 256
            v = (v << 1) | b
        }
        return v
    }

    /// A.3: a symbol id of `codeLength` bits.
    func iaidValue(_ codeLength: Int) -> Int {
        let size = 1 << (codeLength + 1)
        let contexts: Jbig2Contexts
        if let known = iaid, known.count >= size {
            contexts = known
        } else {
            contexts = Jbig2Contexts(size)
            iaid = contexts
        }
        var prev = 1
        for _ in 0..<codeLength { prev = (prev << 1) | bit(contexts, prev) }
        return prev & ((1 << codeLength) - 1)
    }
}
