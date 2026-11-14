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

// Twin of windows/LazyPDF.Core/Filters/Jbig2Symbols.cs. Ported to Swift from pdf.js (src/core/jbig2.js:
// decodeSymbolDictionary) and changed: Huffman coding with refinement and aggregation, retained contexts, and
// limits on the number of symbols.

/// What the symbol dictionary decoding procedure (6.5, Table 13) is given.
final class Jbig2SymbolParams {
    var huffman = false
    var refine = false
    var template = 0
    var refinementTemplate = 0
    var at: [Int] = []
    var refinementAt = [-1, -1, -1, -1]
    var exportedCount = 0
    var newCount = 0
    var input: [Jbig2Bitmap] = []
    var deltaHeight: Jbig2Huffman?
    var deltaWidth: Jbig2Huffman?
    var bitmapSize: Jbig2Huffman?
    var aggregateInstances: Jbig2Huffman?

    /// The refinement contexts of a Huffman coded dictionary, whose refinements each have an arithmetic decoder of their own.
    let refineContexts = Jbig2Contexts(1 << 13)
}

/// The symbols a dictionary exports, and the contexts it leaves for a later one to continue from (7.4.2.2).
final class Jbig2SymbolDictionary {
    let exported: [Jbig2Bitmap]
    let gb: Jbig2Contexts?
    let gr: Jbig2Contexts?

    init(_ exported: [Jbig2Bitmap], _ gb: Jbig2Contexts?, _ gr: Jbig2Contexts?) {
        self.exported = exported
        self.gb = gb
        self.gr = gr
    }
}

/// 6.5: decodes the new symbols of a dictionary and picks the exported ones.
enum Jbig2Symbols {
    /// The most symbols one dictionary and what it refers to may hold.
    static let maxSymbols = 1 << 20

    static func decode(_ budget: Jbig2Budget, _ arith: Jbig2Arith?, _ reader: Jbig2Reader?, _ p: Jbig2SymbolParams) throws -> [Jbig2Bitmap] {
        if p.input.count + p.newCount > maxSymbols { throw Jbig2Budget.tooBig() }
        let huffman = p.huffman
        let total = p.input.count + p.newCount
        var codeLength = Jbig2Text.codeLength(total)
        // 6.5.8.2.3
        if huffman { codeLength = max(codeLength, 1) }
        else { try budget.fixed(2 << codeLength) }

        // The input symbols first, then the new ones as they are decoded; aggregate symbols may use both.
        var all = p.input
        var widths: [Int] = []
        var height = 0
        var classes = 0
        while all.count < total {
            // Every height class holds a symbol; a stream with empty ones is one that is cut off.
            classes += 1
            if classes > 2 * p.newCount + 16 { throw PdfReadException.damaged("A JBIG2 symbol dictionary has empty height classes.") }
            let nextHeight = height + (try delta(huffman, p.deltaHeight, arith, reader, Jbig2Arith.iadh))
            if nextHeight < 0 || nextHeight > Int(Int32.max) { throw PdfReadException.damaged("A JBIG2 symbol has a bad height.") }
            height = nextHeight
            var width = 0, totalWidth = 0
            widths.removeAll()
            while true {
                let next = try huffman ? p.deltaWidth!.decode(reader!) : arith!.integer(Jbig2Arith.iadw)
                guard let deltaWidth = next else { break }
                if all.count + widths.count >= total { throw PdfReadException.damaged("A JBIG2 symbol dictionary has more symbols than it says.") }
                width += deltaWidth
                if width < 0 || width > Int(Int32.max) { throw PdfReadException.damaged("A JBIG2 symbol has a bad width.") }
                totalWidth += width
                if p.refine {
                    let bitmap = try aggregate(budget, arith, reader, p, all, width, height, codeLength)
                    try budget.keep(bitmap.width * bitmap.height + 64)
                    all.append(bitmap)
                } else if huffman {
                    widths.append(width)
                } else {
                    try budget.keep(width * height + 64)
                    all.append(try Jbig2Generic.decode(budget, arith!, width, height, p.template, false, nil, p.at))
                }
            }
            if huffman && !p.refine { try heightClass(budget, reader!, p, &all, widths, height, totalWidth) }
        }

        // 6.5.10: runs of symbols that are not exported and are, alternating, over the input symbols and the new ones.
        var flags = [Bool](repeating: false, count: total)
        var index = 0, runs = 0
        var current = false
        while index < total {
            runs += 1
            if runs > total + 2 { throw PdfReadException.damaged("A JBIG2 symbol dictionary has bad export flags.") }
            let run = try delta(huffman, Jbig2Huffman.standard(1), arith, reader, Jbig2Arith.iaex)
            if run < 0 || run > total - index { throw PdfReadException.damaged("A JBIG2 symbol dictionary has bad export flags.") }
            for _ in 0..<run {
                flags[index] = current
                index += 1
            }
            current.toggle()
        }
        var exported: [Jbig2Bitmap] = []
        for i in 0..<total where flags[i] { exported.append(all[i]) }
        // The list is kept for the segments that refer to it.
        try budget.keep(exported.count * 8)
        return exported
    }

    private static func delta(_ huffman: Bool, _ table: Jbig2Huffman?, _ arith: Jbig2Arith?, _ reader: Jbig2Reader?, _ procedure: Int) throws -> Int {
        let value = try huffman ? table!.decode(reader!) : arith!.integer(procedure)
        guard let value else { throw PdfReadException.damaged("A JBIG2 symbol dictionary has an out-of-band value where there is none.") }
        return value
    }

    /// 6.5.9: the symbols of one height class are coded side by side in one bitmap, uncompressed or MMR.
    private static func heightClass(_ budget: Jbig2Budget, _ reader: Jbig2Reader, _ p: Jbig2SymbolParams, _ all: inout [Jbig2Bitmap], _ widths: [Int], _ height: Int, _ totalWidth: Int) throws {
        let size = try delta(true, p.bitmapSize, nil, reader, 0)
        reader.byteAlign()
        if size < 0 || size > reader.end - reader.position { throw PdfReadException.damaged("A JBIG2 symbol bitmap is longer than its segment.") }
        if totalWidth > Int(Int32.max) { throw Jbig2Budget.tooBig() }
        try budget.keep(totalWidth * height + 64 * widths.count)
        let collective: Jbig2Bitmap
        if size == 0 {
            collective = try Jbig2Bitmap(totalWidth, height, budget)
            let stride = (totalWidth + 7) / 8
            if reader.end - reader.position < stride * height { throw PdfReadException.damaged("A JBIG2 symbol bitmap is cut off.") }
            for y in 0..<height {
                for x in 0..<totalWidth {
                    collective.pixels[y * totalWidth + x] = (reader.data[reader.position + x / 8] >> UInt8(7 - (x & 7))) & 1
                }
                reader.position += stride
            }
        } else {
            var used = 0
            collective = try Jbig2Generic.mmr(budget, reader.data, reader.position, reader.position + size, totalWidth, height, &used)
            reader.position += size
        }
        var x0 = 0
        for width in widths {
            all.append(try collective.columns(x0, width, budget))
            x0 += width
        }
    }

    /// 6.5.8.2: a symbol made of other symbols or refined from one.
    private static func aggregate(_ budget: Jbig2Budget, _ arith: Jbig2Arith?, _ reader: Jbig2Reader?, _ p: Jbig2SymbolParams, _ all: [Jbig2Bitmap],
                                  _ width: Int, _ height: Int, _ codeLength: Int) throws -> Jbig2Bitmap {
        let huffman = p.huffman
        let instances = try delta(huffman, p.aggregateInstances, arith, reader, Jbig2Arith.iaai)
        let text = Jbig2TextParams()
        text.huffman = huffman
        text.refine = true
        text.width = width
        text.height = height
        text.instances = instances
        text.referenceCorner = 1
        text.refinementTemplate = p.refinementTemplate
        text.refinementAt = p.refinementAt
        text.symbols = all
        text.symbolCodeLength = codeLength
        if huffman {
            text.firstS = Jbig2Huffman.standard(6)
            text.deltaS = Jbig2Huffman.standard(8)
            text.deltaT = Jbig2Huffman.standard(11)
            text.refineWidth = Jbig2Huffman.standard(15)
            text.refineHeight = text.refineWidth
            text.refineX = text.refineWidth
            text.refineY = text.refineWidth
            text.refineSize = Jbig2Huffman.standard(1)
        }
        let decoder = Jbig2Text(budget, arith, reader, text, p.refineContexts)
        if instances > 1 { return try decoder.decode() }
        if instances < 1 { throw PdfReadException.damaged("A JBIG2 aggregate symbol has no instances.") }

        // 6.5.8.2.2: one symbol, refined.
        let id = try huffman ? reader!.readBits(codeLength) : arith!.iaidValue(codeLength)
        let rdx = try delta(huffman, Jbig2Huffman.standard(15), arith, reader, Jbig2Arith.iardx)
        let rdy = try delta(huffman, Jbig2Huffman.standard(15), arith, reader, Jbig2Arith.iardy)
        if id < 0 || id >= all.count { throw PdfReadException.damaged("A JBIG2 aggregate symbol uses a symbol that is not there.") }
        return try decoder.refineWith(all[id], width, height, rdx, rdy)
    }
}
