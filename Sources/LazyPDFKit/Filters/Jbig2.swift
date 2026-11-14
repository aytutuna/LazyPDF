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

// Twin of windows/LazyPDF.Core/Filters/Jbig2.cs. Ported to Swift from pdf.js (src/core/jbig2.js: segment headers,
// SimpleSegmentVisitor) and changed: the page is composed with every combination operator, a segment that fails
// does not stop the others, and every size and count is checked against the budget before anything is allocated.

/// JBIG2Decode (ISO 32000-1 7.4.7; ITU-T T.88): the segments of an embedded stream, the globals first,
/// drawn into one page that comes out as packed rows with 0 for black, as an image stream expects.
enum Jbig2 {
    /// Rows of packed pixels, each starting on a byte boundary, black 0 and white 1 (the filter inverts JBIG2's black 1).
    /// A segment that does not decode is left out; the stream is damaged only when none of its regions could be drawn,
    /// or at all when `whole` says a partial page is no use.
    static func decode(_ globals: [UInt8], _ data: [UInt8], _ maxSize: Int, _ width: Int = 0, _ height: Int = 0, _ whole: Bool = false) throws -> [UInt8] {
        // TODO: a budget for all the JBIG2 decodes of a document, so that many images cannot each use a full one.
        let decoder = Jbig2Decoder(maxSize, width, height, whole)
        try decoder.read(globals, globals: true)
        try decoder.read(data)
        return try decoder.finish()
    }
}

/// With `fitWidth` and `fitHeight` (the size the image dictionary gives) the page comes out
/// cut or padded with white to that size, so that the samples have the stride the image reads them with.
final class Jbig2Decoder {
    private let maxSize: Int
    private let fitWidth: Int
    private let fitHeight: Int
    private let whole: Bool

    private let budget = Jbig2Budget()
    private var segments = 0
    private var failed = 0
    private var drawn = 0
    private var firstError: PdfReadException?

    // The page (7.4.8). With an unknown height the bitmap grows with the regions and stripes, and `rows` is what is used.
    private var page: Jbig2Bitmap?
    private var heightKnown = false
    private var rows = 0
    private var defaultPixel: UInt8 = 0

    /// The most segments one decode reads, the globals and the image together.
    private static let maxSegments = 1 << 16

    /// The shortest segment header: number, flags, referred-to flags, page association and length.
    private static let minHeader = 11

    private var intermediate: [Int: Jbig2Bitmap] = [:]
    private var dictionaries: [Int: Jbig2SymbolDictionary] = [:]
    private var tables: [Int: Jbig2Huffman] = [:]
    private var patterns: [Int: [Jbig2Bitmap]] = [:]

    private struct Segment {
        var number: Int
        var type: Int
        var referred: [Int]
        var length: Int
        var headerEnd: Int
        var unknownLength: Bool
    }

    private struct Region {
        var width: Int
        var height: Int
        var x: Int
        var y: Int
        var op: Int
    }

    init(_ maxSize: Int, _ fitWidth: Int = 0, _ fitHeight: Int = 0, _ whole: Bool = false) {
        self.maxSize = maxSize
        // The size of a picture is a 32 bit number.
        self.fitWidth = min(fitWidth, Int(Int32.max))
        self.fitHeight = min(fitHeight, Int(Int32.max))
        self.whole = whole
    }

    /// What the image's own segments may make is tied to the size of the picture (the globals, which many pictures share,
    /// are not), which have a budget of their own and may hold dictionaries and tables only.
    private func startImage() {
        inGlobals = false
        budget.forImage(fitWidth > 0 && fitHeight > 0 ? fitWidth * fitHeight : 0)
    }

    private var inGlobals = false

    // How many segments in a row may fail without reading anything of their own before the rest of the data is given up on.
    private static let maxFailedRun = 16

    // The end of the segment being read: no field of it is read past that.
    private var limit = 0

    /// The segments of `data` one after the other (7.2), through the end of file segment.
    func read(_ data: [UInt8], globals: Bool = false) throws {
        inGlobals = globals
        if globals { budget.forGlobals() }
        else { startImage() }
        var position = 0
        var failedRun = 0
        // Zeros at the end are padding, a line break or a stray byte after the last segment is the end of the data, not a segment that failed.
        let last = data.lastIndex(where: { $0 != 0 }) ?? -1
        while position <= last {
            if data.count - position < Jbig2Decoder.minHeader { return }
            limit = data.count
            let segment: Segment
            do {
                segment = try readHeader(data, position)
            } catch let e as PdfReadException where e.problem == .damaged {
                fail(e)
                return
            }
            segments += 1
            if segments > Jbig2Decoder.maxSegments { throw Jbig2Budget.tooBig() }
            let start = segment.headerEnd
            let end = min(start + segment.length, data.count)
            // A segment that runs past the end of the data is read as far as it goes, unless a partial page is no use.
            if whole && !segment.unknownLength && start + segment.length > data.count {
                fail(PdfReadException.damaged("A JBIG2 segment is cut off."))
                return
            }
            do {
                // The handlers read nothing of the next segment: the fields they take are bounded by the end of this one.
                limit = end
                try process(segment, data, start, end)
                failedRun = 0
            } catch let e as PdfReadException where e.problem == .damaged {
                fail(e)
                // A segment that carries data may fail for what an earlier one left out; only empty ones are a run.
                if segment.length <= segment.headerEnd - position {
                    failedRun += 1
                    if failedRun > Jbig2Decoder.maxFailedRun {
                        fail(PdfReadException.damaged("A JBIG2 stream has nothing but segments that do not decode."))
                        return
                    }
                }
            }
            // Nothing after the end of the page or of the file is read.
            if segment.type == 49 || segment.type == 51 { return }
            position = end
        }
    }

    private func fail(_ e: PdfReadException) {
        failed += 1
        if firstError == nil { firstError = e }
    }

    /// 7.2: the segment header at `start`.
    private func readHeader(_ data: [UInt8], _ start: Int) throws -> Segment {
        var position = start
        let number = try u32(data, position)
        let flags = try u8(data, position + 4)
        let type = flags & 0x3f
        let wideAssociation = (flags & 0x40) != 0
        let referredFlags = try u8(data, position + 5)
        var count = referredFlags >> 5
        position += 6
        if count == 7 {
            count = try u32(data, position - 1) & 0x1fffffff
            // The retention bits take one bit for the segment itself and one for each one it refers to.
            let retainBytes = (count + 8) / 8
            position += 3 + retainBytes
        } else if count > 4 {
            throw PdfReadException.damaged("A JBIG2 segment header has bad referred-to flags.")
        }
        let numberSize = number <= 256 ? 1 : number <= 65536 ? 2 : 4
        // Each referred segment needs bytes in the header, so the count is bounded by the data.
        if count * numberSize > data.count - position { throw PdfReadException.damaged("A JBIG2 segment header is cut off.") }
        var referred = [Int](repeating: 0, count: count)
        for i in 0..<count {
            referred[i] = try numberSize == 1 ? u8(data, position) : numberSize == 2 ? u16(data, position) : u32(data, position)
            position += numberSize
        }
        position += wideAssociation ? 4 : 1
        var length = try u32(data, position)
        position += 4
        let unknown = length == 0xffffffff
        if unknown {
            // 7.2.7: only an immediate generic region may have an unknown length; it ends with a marker and the row count.
            if type != 38 { throw PdfReadException.damaged("A JBIG2 segment has no length.") }
            length = try unknownLength(data, position)
        }
        return Segment(number: number, type: type, referred: referred, length: length, headerEnd: position, unknownLength: unknown)
    }

    private func unknownLength(_ data: [UInt8], _ start: Int) throws -> Int {
        // The flags byte of the generic region follows its 17 byte region information.
        let mmr = (try u8(data, start + 17) & 1) != 0
        let first: UInt8 = mmr ? 0x00 : 0xff
        let second: UInt8 = mmr ? 0x00 : 0xac
        var i = start + 18
        while i + 6 <= data.count {
            if data[i] == first && data[i + 1] == second { return i + 6 - start }
            i += 1
        }
        throw PdfReadException.damaged("A JBIG2 segment of unknown length does not end.")
    }

    private func process(_ segment: Segment, _ data: [UInt8], _ start: Int, _ end: Int) throws {
        // The globals of an image hold dictionaries and tables; whatever else is there is not drawn.
        if inGlobals && !(segment.type == 0 || segment.type == 16 || segment.type == 53) { return }
        switch segment.type {
        case 0:
            try symbolDictionary(segment, data, start, end)
        case 4, 6, 7:
            try textRegion(segment, data, start, end)
        case 16:
            try patternDictionary(segment, data, start, end)
        case 20, 22, 23:
            try halftoneRegion(segment, data, start, end)
        case 36, 38, 39:
            try genericRegion(segment, data, start, end)
        case 40, 42, 43:
            try refinementRegion(segment, data, start, end)
        case 53:
            tables[segment.number] = try Jbig2Huffman.custom(data, start, end)
        case 48:
            try pageInformation(data, start, end)
        case 50:
            try endOfStripe(data, start, end)
        default:
            // Profiles, extensions, end of page and file, and types this reader does not know carry nothing to draw.
            break
        }
    }

    /// The symbols the referred dictionaries export, one after the other.
    private func inputSymbols(_ segment: Segment) throws -> [Jbig2Bitmap] {
        var symbols: [Jbig2Bitmap] = []
        for number in segment.referred {
            guard let dictionary = dictionaries[number] else { continue }
            symbols.append(contentsOf: dictionary.exported)
            if symbols.count > Jbig2Symbols.maxSymbols { throw Jbig2Budget.tooBig() }
            try budget.fixed(dictionary.exported.count * 8)
        }
        return symbols
    }

    /// The tables segments a segment refers to, in order, for the selections that name a custom table.
    private final class CustomTables {
        private let tables: [Jbig2Huffman]
        private var index = 0

        init(_ tables: [Jbig2Huffman]) { self.tables = tables }

        func next() throws -> Jbig2Huffman {
            if index >= tables.count { throw PdfReadException.damaged("A JBIG2 segment names a custom table it does not refer to.") }
            index += 1
            return tables[index - 1]
        }
    }

    private func tablesOf(_ segment: Segment) -> CustomTables {
        var found: [Jbig2Huffman] = []
        for number in segment.referred {
            if let table = tables[number] { found.append(table) }
        }
        return CustomTables(found)
    }

    // Selector 3 is a custom table; the standard ones are numbered from `first`.
    private static func select(_ selector: Int, _ first: Int, _ standardCount: Int, _ custom: CustomTables) throws -> Jbig2Huffman {
        if selector < standardCount { return Jbig2Huffman.standard(first + selector) }
        if selector == 3 { return try custom.next() }
        throw PdfReadException.damaged("A JBIG2 segment has a bad Huffman table selection.")
    }

    private func symbolDictionary(_ segment: Segment, _ data: [UInt8], _ start: Int, _ end: Int) throws {
        var position = start
        let flags = try u16(data, position)
        position += 2
        let p = Jbig2SymbolParams()
        p.huffman = (flags & 1) != 0
        p.refine = (flags & 2) != 0
        p.template = (flags >> 10) & 3
        p.refinementTemplate = (flags >> 12) & 1
        if !p.huffman { p.at = try Jbig2Decoder.readAt(data, &position, end, p.template == 0 ? 4 : 1) }
        if p.refine && p.refinementTemplate == 0 { p.refinementAt = try Jbig2Decoder.readAt(data, &position, end, 2) }
        let exported = try u32(data, position), added = try u32(data, position + 4)
        position += 8
        if exported > Jbig2Symbols.maxSymbols || added > Jbig2Symbols.maxSymbols { throw Jbig2Budget.tooBig() }
        p.exportedCount = exported
        p.newCount = added
        p.input = try inputSymbols(segment)

        if p.huffman {
            let custom = tablesOf(segment)
            p.deltaHeight = try Jbig2Decoder.select((flags >> 2) & 3, 4, 2, custom)
            p.deltaWidth = try Jbig2Decoder.select((flags >> 4) & 3, 2, 2, custom)
            p.bitmapSize = try (flags & 0x40) != 0 ? custom.next() : Jbig2Huffman.standard(1)
            p.aggregateInstances = try (flags & 0x80) != 0 ? custom.next() : Jbig2Huffman.standard(1)
        }

        // 7.4.2.2: the contexts a dictionary left, if it kept them, are where this one starts.
        var gb: Jbig2Contexts?, gr: Jbig2Contexts?
        if (flags & 0x100) != 0 {
            var last: Jbig2SymbolDictionary?
            for number in segment.referred {
                if let d = dictionaries[number] { last = d }
            }
            guard let last else { throw PdfReadException.damaged("A JBIG2 symbol dictionary reuses contexts of a dictionary it does not refer to.") }
            gb = last.gb
            gr = last.gr
        }
        var arith: Jbig2Arith?
        var reader: Jbig2Reader?
        if p.huffman {
            reader = Jbig2Reader(data, position, end)
            if let gr { p.refineContexts.copy(from: gr) }
        } else {
            let made = try Jbig2Arith(data, position, end, budget: budget)
            if let gb { made.gb = gb.clone() }
            if let gr { made.gr = gr.clone() }
            arith = made
        }
        let symbols = try Jbig2Symbols.decode(budget, arith, reader, p)
        // Only a dictionary that says so leaves its contexts behind.
        let retained = (flags & 0x200) != 0
        if retained { try budget.keep(1 << 17) }
        dictionaries[segment.number] = Jbig2SymbolDictionary(symbols, retained ? arith?.gb : nil, retained ? (arith?.gr ?? p.refineContexts) : nil)
    }

    private func textRegion(_ segment: Segment, _ data: [UInt8], _ start: Int, _ end: Int) throws {
        let region = try readRegion(data, start, end)
        var position = start + 17
        let flags = try u16(data, position)
        position += 2
        let p = Jbig2TextParams()
        p.huffman = (flags & 1) != 0
        p.refine = (flags & 2) != 0
        p.logStripSize = (flags >> 2) & 3
        p.referenceCorner = (flags >> 4) & 3
        p.transposed = (flags & 0x40) != 0
        p.combinationOperator = (flags >> 7) & 3
        p.defaultPixel = (flags >> 9) & 1
        // A signed five bit number.
        p.dsOffset = ((flags >> 10) & 0x1f) - ((flags & 0x4000) != 0 ? 32 : 0)
        p.refinementTemplate = (flags >> 15) & 1
        p.width = region.width
        p.height = region.height
        var huffmanFlags = 0
        if p.huffman {
            huffmanFlags = try u16(data, position)
            position += 2
        }
        if p.refine && p.refinementTemplate == 0 { p.refinementAt = try Jbig2Decoder.readAt(data, &position, end, 2) }
        let instances = try u32(data, position)
        position += 4
        if instances > Jbig2Text.maxInstances { throw Jbig2Budget.tooBig() }
        p.instances = instances
        p.symbols = try inputSymbols(segment)
        p.symbolCodeLength = Jbig2Text.codeLength(p.symbols.count)

        var arith: Jbig2Arith?
        var reader: Jbig2Reader?
        if p.huffman {
            let custom = tablesOf(segment)
            let made = Jbig2Reader(data, position, end)
            reader = made
            p.symbolIds = try Jbig2Decoder.symbolIdTable(made, p.symbols.count)
            p.firstS = try Jbig2Decoder.select(huffmanFlags & 3, 6, 2, custom)
            p.deltaS = try Jbig2Decoder.select((huffmanFlags >> 2) & 3, 8, 3, custom)
            p.deltaT = try Jbig2Decoder.select((huffmanFlags >> 4) & 3, 11, 3, custom)
            // The selections for the refinement values mean nothing in a region that does not refine.
            if p.refine {
                p.refineWidth = try Jbig2Decoder.select((huffmanFlags >> 6) & 3, 14, 2, custom)
                p.refineHeight = try Jbig2Decoder.select((huffmanFlags >> 8) & 3, 14, 2, custom)
                p.refineX = try Jbig2Decoder.select((huffmanFlags >> 10) & 3, 14, 2, custom)
                p.refineY = try Jbig2Decoder.select((huffmanFlags >> 12) & 3, 14, 2, custom)
                p.refineSize = try (huffmanFlags & 0x4000) != 0 ? custom.next() : Jbig2Huffman.standard(1)
            }
        } else {
            arith = try Jbig2Arith(data, position, end, budget: budget)
            try budget.fixed(2 << p.symbolCodeLength)
        }
        let bitmap = try Jbig2Text(budget, arith, reader, p, p.huffman ? Jbig2Contexts(1 << 13) : nil).decode()
        try store(segment, region, bitmap)
    }

    /// 7.4.3.1.7: the code lengths of the symbols, themselves coded with a table of 35 run codes.
    private static func symbolIdTable(_ reader: Jbig2Reader, _ count: Int) throws -> Jbig2Huffman {
        var runLengths = [Int](repeating: 0, count: 35)
        for i in 0..<runLengths.count { runLengths[i] = try reader.readBits(4) }
        let runCodes = try Jbig2Huffman.forLengths(runLengths)
        var lengths = [Int](repeating: 0, count: count)
        var i = 0
        while i < count {
            guard let code = try runCodes.decode(reader) else { throw PdfReadException.damaged("A JBIG2 symbol code table has an out-of-band value.") }
            let repeats: Int, length: Int
            switch code {
            case ..<32:
                lengths[i] = code
                i += 1
                continue
            case 32:
                if i == 0 { throw PdfReadException.damaged("A JBIG2 symbol code table repeats nothing.") }
                repeats = try reader.readBits(2) + 3
                length = lengths[i - 1]
            case 33:
                repeats = try reader.readBits(3) + 3
                length = 0
            default:
                repeats = try reader.readBits(7) + 11
                length = 0
            }
            if repeats > count - i { throw PdfReadException.damaged("A JBIG2 symbol code table is too long.") }
            for _ in 0..<repeats {
                lengths[i] = length
                i += 1
            }
        }
        reader.byteAlign()
        return try Jbig2Huffman.forLengths(lengths)
    }

    private func refinementRegion(_ segment: Segment, _ data: [UInt8], _ start: Int, _ end: Int) throws {
        let region = try readRegion(data, start, end)
        var position = start + 17
        let flags = try u8(data, position)
        position += 1
        let template = flags & 1
        let at = try template == 0 ? Jbig2Decoder.readAt(data, &position, end, 2) : [-1, -1, -1, -1]
        var reference: Jbig2Bitmap?
        for number in segment.referred {
            if let found = intermediate[number] { reference = found }
        }
        let source: Jbig2Bitmap
        if let reference {
            if reference.width != region.width || reference.height != region.height {
                throw PdfReadException.damaged("A JBIG2 refinement region is not the size of the region it refines.")
            }
            source = reference
        } else {
            // Nothing referred to: the page under the region is what gets refined.
            guard let page else { throw PdfReadException.damaged("A JBIG2 refinement region comes before the page information.") }
            source = try Jbig2Bitmap(region.width, region.height, budget)
            source.compose(page, -region.x, -region.y, 4)
        }
        let arith = try Jbig2Arith(data, position, end, budget: budget)
        let bitmap = try Jbig2Generic.refine(budget, arith, region.width, region.height, template, source, 0, 0, (flags & 2) != 0, at)
        try store(segment, region, bitmap)
    }

    private func patternDictionary(_ segment: Segment, _ data: [UInt8], _ start: Int, _ end: Int) throws {
        let flags = try u8(data, start)
        let width = try u8(data, start + 1), height = try u8(data, start + 2)
        let maxIndex = try u32(data, start + 3)
        patterns[segment.number] = try Jbig2Halftone.patterns(budget, data, start + 7, end, (flags & 1) != 0, (flags >> 1) & 3, width, height, maxIndex)
    }

    private func halftoneRegion(_ segment: Segment, _ data: [UInt8], _ start: Int, _ end: Int) throws {
        let region = try readRegion(data, start, end)
        var position = start + 17
        let flags = try u8(data, position)
        position += 1
        let p = Jbig2Halftone.Params()
        p.mmr = (flags & 1) != 0
        p.template = (flags >> 1) & 3
        p.enableSkip = (flags & 8) != 0
        p.combinationOperator = (flags >> 4) & 7
        p.defaultPixel = (flags >> 7) & 1
        p.width = region.width
        p.height = region.height
        p.gridWidth = try u32(data, position)
        p.gridHeight = try u32(data, position + 4)
        p.gridX = Int(Int32(truncatingIfNeeded: try u32(data, position + 8)))
        p.gridY = Int(Int32(truncatingIfNeeded: try u32(data, position + 12)))
        p.vectorX = try u16(data, position + 16)
        p.vectorY = try u16(data, position + 18)
        position += 20
        var found: [Jbig2Bitmap]?
        for number in segment.referred {
            if let list = patterns[number] { found = list }
        }
        guard let list = found else { throw PdfReadException.damaged("A JBIG2 halftone region has no pattern dictionary.") }
        try store(segment, region, try Jbig2Halftone.region(budget, data, position, end, p, list))
    }

    private func readRegion(_ data: [UInt8], _ start: Int, _ end: Int, _ heightFollows: Bool = false) throws -> Region {
        if end - start < 17 { throw PdfReadException.damaged("A JBIG2 region segment is cut off.") }
        let width = try u32(data, start)
        var height = try u32(data, start + 4)
        let x = try u32(data, start + 8), y = try u32(data, start + 12)
        // A region of unknown length may give an unknown height too; the row count it ends with says it.
        if heightFollows { height = min(height, Int(Int32.max)) }
        if width > Int(Int32.max) || height > Int(Int32.max) { throw Jbig2Budget.tooBig() }
        return Region(width: width, height: height, x: min(x, Int(Int32.max)), y: min(y, Int(Int32.max)), op: Int(data[start + 16]) & 7)
    }

    private func genericRegion(_ segment: Segment, _ data: [UInt8], _ start: Int, _ end: Int) throws {
        var end = end
        var region = try readRegion(data, start, end, segment.unknownLength)
        if segment.unknownLength {
            if end - start < 22 { throw PdfReadException.damaged("A JBIG2 region segment is cut off.") }
            // The row count the segment ends with is the height that was coded.
            let coded = try u32(data, end - 4)
            region.height = min(region.height, coded)
            end -= 4
        }
        var position = start + 17
        let flags = try u8(data, position)
        position += 1
        let mmr = (flags & 1) != 0
        let template = (flags >> 1) & 3
        let typicalPrediction = (flags & 8) != 0
        let bitmap: Jbig2Bitmap
        if mmr {
            var used = 0
            bitmap = try Jbig2Generic.mmr(budget, data, position, end, region.width, region.height, &used)
        } else {
            let at = try Jbig2Decoder.readAt(data, &position, end, template == 0 ? 4 : 1)
            let arith = try Jbig2Arith(data, position, end, budget: budget)
            bitmap = try Jbig2Generic.decode(budget, arith, region.width, region.height, template, typicalPrediction, nil, at)
        }
        try store(segment, region, bitmap)
    }

    /// An intermediate region is kept for a refinement; an immediate one goes onto the page.
    private func store(_ segment: Segment, _ region: Region, _ bitmap: Jbig2Bitmap) throws {
        if segment.type == 4 || segment.type == 20 || segment.type == 36 || segment.type == 40 {
            intermediate[segment.number] = bitmap
            return
        }
        try draw(region, bitmap)
    }

    private static func readAt(_ data: [UInt8], _ position: inout Int, _ end: Int, _ pairs: Int) throws -> [Int] {
        if end - position < pairs * 2 { throw PdfReadException.damaged("A JBIG2 segment is cut off.") }
        var at = [Int](repeating: 0, count: pairs * 2)
        for i in 0..<at.count {
            at[i] = Int(Int8(bitPattern: data[position]))
            position += 1
        }
        return at
    }

    private func pageInformation(_ data: [UInt8], _ start: Int, _ end: Int) throws {
        // A PDF image holds one page; later page information is not for this image.
        if page != nil { return }
        if end - start < 19 { throw PdfReadException.damaged("A JBIG2 page information segment is cut off.") }
        let width = try u32(data, start), height = try u32(data, start + 4)
        let flags = Int(data[start + 16])
        if width == 0 || width > Int(Int32.max) { throw PdfReadException.damaged("A JBIG2 page has no width.") }
        heightKnown = height != 0xffffffff
        if heightKnown && height > Int(Int32.max) { throw Jbig2Budget.tooBig() }
        // The page is about to be allocated: a page whose rows alone pass the limit is refused first.
        if heightKnown && height * ((width + 7) / 8) > maxSize { throw FilterBuffer.tooBig() }
        defaultPixel = UInt8((flags >> 2) & 1)
        let known = heightKnown ? height : 0
        let made = try Jbig2Bitmap(width, known, budget)
        page = made
        rows = known
        if defaultPixel != 0 { made.fill(1) }
    }

    private func endOfStripe(_ data: [UInt8], _ start: Int, _ end: Int) throws {
        if end - start < 4 { throw PdfReadException.damaged("A JBIG2 end of stripe segment is cut off.") }
        let row = try u32(data, start)
        if page == nil || heightKnown { return }
        if row >= Int(Int32.max) { throw Jbig2Budget.tooBig() }
        try reach(row + 1)
    }

    /// Makes room for rows down to `rows` in a page of unknown height and counts them as used.
    private func reach(_ needed: Int) throws {
        let current = page!
        if needed > current.height {
            // Doubling keeps the total of what is allocated, which the budget counts, within twice the page.
            var capacity = min(max(needed, current.height * 2), Int(Int32.max))
            // Doubling must not take a page that fits past the limit.
            if current.width > 0 && capacity > PdfImageSamples.maxPixels / current.width { capacity = max(needed, PdfImageSamples.maxPixels / current.width) }
            let grown = try Jbig2Bitmap(current.width, capacity, budget)
            if defaultPixel != 0 { grown.fill(1) }
            grown.pixels.replaceSubrange(0..<current.pixels.count, with: current.pixels)
            page = grown
        }
        rows = max(rows, needed)
    }

    private func draw(_ region: Region, _ bitmap: Jbig2Bitmap) throws {
        if page == nil { throw PdfReadException.damaged("A JBIG2 region comes before the page information.") }
        if !heightKnown && region.y < Int(Int32.max) - region.height { try reach(region.y + region.height) }
        page!.compose(bitmap, region.x, region.y, region.op)
        drawn += 1
    }

    /// The page as packed rows, black 0.
    func finish() throws -> [UInt8] {
        guard let page else { throw firstError ?? PdfReadException.damaged("A JBIG2 stream has no page.") }
        // A page that is not whole is wrong in the parts that failed; only some callers can use it.
        if failed > 0 && (drawn == 0 || whole) { throw firstError! }
        let width = page.width
        let fit = fitWidth > 0 && fitHeight > 0
        let outWidth = fit ? fitWidth : width, outRows = fit ? fitHeight : rows
        let stride = (outWidth + 7) / 8
        if outRows * stride > maxSize { throw FilterBuffer.tooBig() }
        var output = [UInt8](repeating: 0xff, count: outRows * stride)
        let pixels = page.pixels
        for y in 0..<min(rows, outRows) {
            for x in 0..<min(width, outWidth) where pixels[y * width + x] != 0 {
                output[y * stride + (x >> 3)] &= ~UInt8(0x80 >> (x & 7))
            }
        }
        return output
    }

    private func u8(_ data: [UInt8], _ at: Int) throws -> Int {
        if at >= 0 && at < data.count && at < limit { return Int(data[at]) }
        throw PdfReadException.damaged("A JBIG2 segment is cut off.")
    }

    private func u16(_ data: [UInt8], _ at: Int) throws -> Int { (try u8(data, at) << 8) | (try u8(data, at + 1)) }

    private func u32(_ data: [UInt8], _ at: Int) throws -> Int {
        let high = try u16(data, at)
        return (high << 16) | (try u16(data, at + 2))
    }
}
