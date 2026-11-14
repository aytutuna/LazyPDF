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

// Twin of windows/LazyPDF.Core/Filters/Jbig2Text.cs. Ported to Swift from pdf.js (src/core/jbig2.js: decodeTextRegion,
// decodeSymbolDictionary) and changed: refinement with Huffman coding, all four combination operators, transposed
// placement as 6.4.5 gives it, retained contexts, and limits on the symbols, instances and work a stream may ask for.

/// What the text region decoding procedure (6.4, Table 9) is given.
final class Jbig2TextParams {
    var huffman = false
    var refine = false
    var width = 0
    var height = 0
    var defaultPixel = 0
    var instances = 0
    var logStripSize = 0
    var referenceCorner = 0
    var transposed = false
    var combinationOperator = 0
    var dsOffset = 0
    var refinementTemplate = 0
    var refinementAt = [-1, -1, -1, -1]
    var symbols: [Jbig2Bitmap] = []

    /// The bits of a symbol id: coded with the IAID procedure, or a fixed length code when there is no `symbolIds` table.
    var symbolCodeLength = 0

    var symbolIds: Jbig2Huffman?
    var firstS: Jbig2Huffman?
    var deltaS: Jbig2Huffman?
    var deltaT: Jbig2Huffman?
    var refineWidth: Jbig2Huffman?
    var refineHeight: Jbig2Huffman?
    var refineX: Jbig2Huffman?
    var refineY: Jbig2Huffman?
    var refineSize: Jbig2Huffman?
}

/// 6.4: the symbol instances of a text region, arithmetic or Huffman coded.
final class Jbig2Text {
    /// The most instances a region may have, whatever its header says.
    static let maxInstances = 1 << 22

    private let budget: Jbig2Budget
    private let arith: Jbig2Arith?
    private let reader: Jbig2Reader?
    private let p: Jbig2TextParams
    private let refinementContexts: Jbig2Contexts?

    init(_ budget: Jbig2Budget, _ arith: Jbig2Arith?, _ reader: Jbig2Reader?, _ p: Jbig2TextParams, _ refinementContexts: Jbig2Contexts?) {
        self.budget = budget
        self.arith = arith
        self.reader = reader
        self.p = p
        self.refinementContexts = refinementContexts
    }

    /// ceil(log2(n)), the length of the codes of n symbols.
    static func codeLength(_ n: Int) -> Int { n <= 1 ? 0 : Int.bitWidth - (n - 1).leadingZeroBitCount }

    private func value(_ table: Jbig2Huffman?, _ procedure: Int) throws -> Int {
        let v = try p.huffman ? table!.decode(reader!) : arith!.integer(procedure)
        guard let v else { throw PdfReadException.damaged("A JBIG2 text region has an out-of-band value where there is none.") }
        return v
    }

    func decode() throws -> Jbig2Bitmap {
        if p.instances > Jbig2Text.maxInstances { throw Jbig2Budget.tooBig() }
        let bitmap = try Jbig2Bitmap(p.width, p.height, budget)
        if p.defaultPixel != 0 { bitmap.fill(1) }
        let stripSize = 1 << p.logStripSize
        let bottom = (p.referenceCorner & 1) == 0, right = (p.referenceCorner & 2) != 0

        var stripT = -(try value(p.deltaT, Jbig2Arith.iadt))
        var firstS = 0
        var placed = 0
        while placed < p.instances {
            stripT += try value(p.deltaT, Jbig2Arith.iadt)
            firstS += try value(p.firstS, Jbig2Arith.iafs)
            var currentS = firstS
            while true {
                var currentT = 0
                if stripSize > 1 { currentT = try p.huffman ? reader!.readBits(p.logStripSize) : value(nil, Jbig2Arith.iait) }
                let t = stripSize * stripT + currentT
                var symbol = try symbolAt(try symbolId())
                if p.refine, try refined() { symbol = try refine(symbol) }
                let w = symbol.width, h = symbol.height

                // 6.4.5 step vi, then viii: the reference corner is at (S, T), or at (T, S) when transposed.
                if p.transposed ? bottom : right { currentS += (p.transposed ? h : w) - 1 }
                var left = p.transposed ? t : currentS
                var top = p.transposed ? currentS : t
                if right { left -= w - 1 }
                if bottom { top -= h - 1 }
                try budget.chargeWork(w * h + 256)
                if left > Int(Int32.min) && left < Int(Int32.max) && top > Int(Int32.min) && top < Int(Int32.max) {
                    bitmap.compose(symbol, left, top, p.combinationOperator)
                }
                // Step x
                if p.transposed ? !bottom : !right { currentS += (p.transposed ? h : w) - 1 }
                placed += 1

                guard let deltaS = try delta(p.deltaS, Jbig2Arith.iads), placed < p.instances else { break }
                // The sum is made in 32 bits.
                currentS += Int(Int32(truncatingIfNeeded: deltaS + p.dsOffset))
            }
        }
        return bitmap
    }

    private func symbolId() throws -> Int {
        if !p.huffman { return arith!.iaidValue(p.symbolCodeLength) }
        if p.symbolIds == nil { return try reader!.readBits(p.symbolCodeLength) }
        return try value(p.symbolIds, 0)
    }

    private func symbolAt(_ id: Int) throws -> Jbig2Bitmap {
        if id >= 0 && id < p.symbols.count { return p.symbols[id] }
        throw PdfReadException.damaged("A JBIG2 text region uses a symbol that is not there.")
    }

    private func refined() throws -> Bool { try p.huffman ? reader!.readBit() != 0 : value(nil, Jbig2Arith.iari) != 0 }

    private func delta(_ table: Jbig2Huffman?, _ procedure: Int) throws -> Int? {
        try p.huffman ? table!.decode(reader!) : arith!.integer(procedure)
    }

    /// 6.4.11: the symbol refined by a small bitmap coded in the region.
    private func refine(_ symbol: Jbig2Bitmap) throws -> Jbig2Bitmap {
        let rdw = try value(p.refineWidth, Jbig2Arith.iardw)
        let rdh = try value(p.refineHeight, Jbig2Arith.iardh)
        let rdx = try value(p.refineX, Jbig2Arith.iardx)
        let rdy = try value(p.refineY, Jbig2Arith.iardy)
        let width = symbol.width + rdw, height = symbol.height + rdh
        if width < 0 || height < 0 || width > Int(Int32.max) || height > Int(Int32.max) { throw PdfReadException.damaged("A JBIG2 refined symbol has a bad size.") }
        try budget.chargeWork(width * height)
        // The sums are made in 32 bits.
        return try refineWith(symbol, width, height, Int(Int32(truncatingIfNeeded: (rdw >> 1) + rdx)), Int(Int32(truncatingIfNeeded: (rdh >> 1) + rdy)))
    }

    /// The refinement coded in the arithmetic data, or in a size and a block of its own when Huffman coded.
    func refineWith(_ reference: Jbig2Bitmap, _ width: Int, _ height: Int, _ dx: Int, _ dy: Int) throws -> Jbig2Bitmap {
        if !p.huffman { return try Jbig2Generic.refine(budget, arith!, width, height, p.refinementTemplate, reference, dx, dy, false, p.refinementAt) }
        let size = try value(p.refineSize, 0)
        let reader = self.reader!
        reader.byteAlign()
        if size < 0 || size > reader.end - reader.position { throw PdfReadException.damaged("A JBIG2 refinement is longer than its segment.") }
        let block = try Jbig2Arith(reader.data, reader.position, reader.position + size, refinementContexts: refinementContexts)
        let result = try Jbig2Generic.refine(budget, block, width, height, p.refinementTemplate, reference, dx, dy, false, p.refinementAt)
        reader.position += size
        return result
    }
}
