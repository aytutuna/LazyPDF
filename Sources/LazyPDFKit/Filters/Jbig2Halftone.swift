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

// Twin of windows/LazyPDF.Core/Filters/Jbig2Halftone.cs. Ported to Swift from pdf.js (src/core/jbig2.js:
// decodePatternDictionary, decodeHalftoneRegion) and changed: skipped cells, every combination operator, MMR planes
// read one after the other, and limits on patterns and the grid.

/// 6.7 and 6.6: pattern dictionaries and the halftone regions that draw with them.
enum Jbig2Halftone {
    /// The most patterns one dictionary may hold.
    static let maxPatterns = 1 << 16

    /// The most cells a halftone grid may have.
    static let maxCells = 1 << 25

    /// 6.7.5: the collective bitmap of all patterns, cut up.
    static func patterns(_ budget: Jbig2Budget, _ data: [UInt8], _ start: Int, _ end: Int, _ mmr: Bool, _ template: Int, _ width: Int, _ height: Int, _ maxIndex: Int) throws -> [Jbig2Bitmap] {
        if width < 1 || height < 1 { throw PdfReadException.damaged("A JBIG2 pattern dictionary has a bad size.") }
        if maxIndex >= maxPatterns { throw Jbig2Budget.tooBig() }
        let count = maxIndex + 1
        try budget.keep(count * (width * height + 64))
        let collective: Jbig2Bitmap
        if mmr {
            var used = 0
            collective = try Jbig2Generic.mmr(budget, data, start, end, count * width, height, &used)
        } else {
            let arith = try Jbig2Arith(data, start, end, budget: budget)
            let at = template == 0 ? [-width, 0, -3, -1, 2, -2, -2, -2] : [-width, 0]
            collective = try Jbig2Generic.decode(budget, arith, count * width, height, template, false, nil, at)
        }
        var patterns: [Jbig2Bitmap] = []
        patterns.reserveCapacity(count)
        for i in 0..<count { patterns.append(try collective.columns(i * width, width, budget)) }
        return patterns
    }

    /// 6.6.5: what a halftone region segment says (7.4.5.1).
    final class Params {
        var mmr = false
        var template = 0
        var enableSkip = false
        var combinationOperator = 0
        var defaultPixel = 0
        var width = 0
        var height = 0
        var gridWidth = 0
        var gridHeight = 0
        var gridX = 0
        var gridY = 0
        var vectorX = 0
        var vectorY = 0
    }

    static func region(_ budget: Jbig2Budget, _ data: [UInt8], _ start: Int, _ end: Int, _ p: Params, _ patterns: [Jbig2Bitmap]) throws -> Jbig2Bitmap {
        if patterns.isEmpty { throw PdfReadException.damaged("A JBIG2 halftone region has no patterns.") }
        // Each is checked alone first: the fields are 32 bits wide, and their product need not fit a 64 bit number.
        if p.gridWidth > maxCells || p.gridHeight > maxCells || p.gridWidth * p.gridHeight > maxCells { throw Jbig2Budget.tooBig() }
        let gridWidth = p.gridWidth, gridHeight = p.gridHeight
        let region = try Jbig2Bitmap(p.width, p.height, budget)
        if p.defaultPixel != 0 { region.fill(1) }
        let patternWidth = patterns[0].width, patternHeight = patterns[0].height
        try budget.chargeWork(max(gridWidth, 1) * max(gridHeight, 1))

        var skip: Jbig2Bitmap?
        if p.enableSkip {
            // 6.6.5.1: the cells whose pattern would fall outside the region are not coded.
            let marks = try Jbig2Bitmap(gridWidth, gridHeight, budget)
            for m in 0..<gridHeight {
                for n in 0..<gridWidth {
                    let x = cellX(p, m, n), y = cellY(p, m, n)
                    if x + patternWidth <= 0 || x >= p.width || y + patternHeight <= 0 || y >= p.height { marks.pixels[m * gridWidth + n] = 1 }
                }
            }
            skip = marks
        }

        // Annex C: the gray values are coded as bit planes, the highest first, each the exclusive or of itself and the plane above.
        let planeCount = Jbig2Text.codeLength(patterns.count)
        var planes = [Jbig2Bitmap?](repeating: nil, count: planeCount)
        let arith: Jbig2Arith? = try p.mmr ? nil : Jbig2Arith(data, start, end, budget: budget)
        let at = p.template == 0 ? [3, -1, -3, -1, 2, -2, -2, -2] : [p.template == 1 ? 3 : 2, -1]
        var position = start
        var j = planeCount - 1
        while j >= 0 {
            let plane: Jbig2Bitmap
            if p.mmr {
                var used = 0
                plane = try Jbig2Generic.mmr(budget, data, position, end, gridWidth, gridHeight, &used)
                position += used
            } else {
                plane = try Jbig2Generic.decode(budget, arith!, gridWidth, gridHeight, p.template, false, skip, at)
            }
            if j < planeCount - 1 {
                let above = planes[j + 1]!.pixels
                for i in 0..<plane.pixels.count { plane.pixels[i] ^= above[i] }
            }
            planes[j] = plane
            j -= 1
        }

        // 6.6.5.2: a pattern at each cell of the grid.
        for m in 0..<gridHeight {
            for n in 0..<gridWidth {
                var index = 0
                for j in 0..<planeCount { index |= Int(planes[j]!.pixels[m * gridWidth + n]) << j }
                let pattern = patterns[min(index, patterns.count - 1)]
                let x = cellX(p, m, n), y = cellY(p, m, n)
                if x + patternWidth <= 0 || x >= p.width || y + patternHeight <= 0 || y >= p.height { continue }
                try budget.chargeWork(patternWidth * patternHeight)
                region.compose(pattern, x, y, p.combinationOperator)
            }
        }
        return region
    }

    private static func cellX(_ p: Params, _ m: Int, _ n: Int) -> Int { (p.gridX + m * p.vectorY + n * p.vectorX) >> 8 }

    private static func cellY(_ p: Params, _ m: Int, _ n: Int) -> Int { (p.gridY + m * p.vectorX - n * p.vectorY) >> 8 }
}
