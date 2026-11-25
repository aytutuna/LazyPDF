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

// Twin of windows/LazyPDF.Core/Filters/Jbig2Generic.cs. Ported to Swift from pdf.js (src/core/jbig2.js: decodeBitmap,
// decodeBitmapTemplate0, decodeRefinement) and changed: bitmaps are flat byte arrays, the template bits follow the
// order of T.88 whatever the adaptive pixels are, skipped pixels and typical prediction of refinement rows (TPGRON)
// are done, MMR goes through Ccitt.

/// The generic region (6.2) and generic refinement region (6.3) decoding procedures.
enum Jbig2Generic {
    // 6.2.5.7, Figures 8 to 11: the context of the pseudo pixel that carries the typical prediction bit.
    private static let reusedContexts = [0x9b25, 0x0795, 0x00e5, 0x0195]

    // 6.3.5.6, Figures 14 and 15.
    private static let refinementReusedContexts = [0x0020, 0x0008]

    /// The pixels the template looks at, in the order of the context bits from the highest. The adaptive pixels
    /// (`at`, x then y for each) sit where Figures 3 to 6 put them.
    private static func template(_ template: Int, _ at: [Int]) -> (x: [Int], y: [Int]) {
        switch template {
        case 0:
            return ([at[6], -1, 0, 1, at[4], at[2], -2, -1, 0, 1, 2, at[0], -4, -3, -2, -1],
                    [at[7], -2, -2, -2, at[5], at[3], -1, -1, -1, -1, -1, at[1], 0, 0, 0, 0])
        case 1:
            return ([-1, 0, 1, 2, -2, -1, 0, 1, 2, at[0], -3, -2, -1],
                    [-2, -2, -2, -2, -1, -1, -1, -1, -1, at[1], 0, 0, 0])
        case 2:
            return ([-1, 0, 1, -2, -1, 0, 1, at[0], -2, -1],
                    [-2, -2, -2, -1, -1, -1, -1, at[1], 0, 0])
        default:
            return ([-3, -2, -1, 0, 1, at[0], -4, -3, -2, -1],
                    [-1, -1, -1, -1, -1, at[1], 0, 0, 0, 0])
        }
    }

    /// 6.2.5: an arithmetic coded generic region. `skip` marks pixels that are not coded (halftone
    /// regions); `at` has the x and y of every adaptive pixel (four of them for template 0).
    static func decode(_ budget: Jbig2Budget, _ arith: Jbig2Arith, _ width: Int, _ height: Int, _ template: Int, _ typicalPrediction: Bool, _ skip: Jbig2Bitmap?, _ at: [Int]) throws -> Jbig2Bitmap {
        let bitmap = try Jbig2Bitmap(width, height, budget)
        if width == 0 || height == 0 { return bitmap }
        let contexts = arith.gb
        if template == 0 && skip == nil && width >= 4 && at[0] == 3 && at[1] == -1 && at[2] == -3 && at[3] == -1 && at[4] == 2 && at[5] == -2 && at[6] == -2 && at[7] == -2 {
            decodeTemplate0(arith, contexts, bitmap, typicalPrediction)
            return bitmap
        }

        let (tx, ty) = Jbig2Generic.template(template, at)
        let length = tx.count
        // A template pixel that is the next one's neighbour on the left keeps its place in the label of the following
        // pixel, shifted by one bit, so only the others are read again.
        var reuseMask = 0, minX = 0, maxX = 0, minY = 0, maxY = 0
        var changing: [Int] = []
        for k in 0..<length {
            minX = min(minX, tx[k])
            maxX = max(maxX, tx[k])
            minY = min(minY, ty[k])
            maxY = max(maxY, ty[k])
            if k < length - 1 && ty[k] == ty[k + 1] && tx[k] == tx[k + 1] - 1 { reuseMask |= 1 << (length - 1 - k) }
            else { changing.append(k) }
        }
        let changes = changing.count
        var changingX = [Int](repeating: 0, count: changes)
        var changingY = [Int](repeating: 0, count: changes)
        var changingBit = [Int](repeating: 0, count: changes)
        for c in 0..<changes {
            let k = changing[c]
            changingX[c] = tx[k]
            changingY[c] = ty[k]
            changingBit[c] = 1 << (length - 1 - k)
        }
        // Inside this box every template pixel is inside the bitmap.
        let safeLeft = -minX, safeTop = -minY, safeRight = width - maxX, safeBottom = height - maxY

        var px = bitmap.pixels
        bitmap.pixels = []
        defer { bitmap.pixels = px }
        let pseudoPixelContext = reusedContexts[template]
        var ltp = 0
        for i in 0..<height {
            if typicalPrediction {
                ltp ^= arith.bit(contexts, pseudoPixelContext)
                if ltp != 0 {
                    if i > 0 {
                        for j in 0..<width { px[i * width + j] = px[(i - 1) * width + j] }
                    }
                    continue
                }
            }
            var label = 0
            for j in 0..<width {
                if j >= safeLeft && j < safeRight && i >= safeTop && i < safeBottom {
                    label = (label << 1) & reuseMask
                    for c in 0..<changes where px[(i + changingY[c]) * width + j + changingX[c]] != 0 {
                        label |= changingBit[c]
                    }
                } else {
                    label = 0
                    for k in 0..<length {
                        let j0 = j + tx[k], i0 = i + ty[k]
                        if j0 >= 0 && j0 < width && i0 >= 0 && i0 < height && px[i0 * width + j0] != 0 { label |= 1 << (length - 1 - k) }
                    }
                }
                if let skip, skip.pixels[i * width + j] != 0 { continue }
                px[i * width + j] = UInt8(arith.bit(contexts, label))
            }
        }
        return bitmap
    }

    // The common case, template 0 with its adaptive pixels where the standard has them: the label is updated, not rebuilt.
    private static func decodeTemplate0(_ arith: Jbig2Arith, _ contexts: Jbig2Contexts, _ bitmap: Jbig2Bitmap, _ typicalPrediction: Bool) {
        let width = bitmap.width, height = bitmap.height
        var px = bitmap.pixels
        bitmap.pixels = []
        defer { bitmap.pixels = px }
        var ltp = 0
        for i in 0..<height {
            let rowAt = i * width
            if typicalPrediction {
                ltp ^= arith.bit(contexts, reusedContexts[0])
                if ltp != 0 {
                    if i > 0 {
                        for j in 0..<width { px[rowAt + j] = px[rowAt - width + j] }
                    }
                    continue
                }
            }
            // Rows above the first read as white.
            let has1 = i >= 1, has2 = i >= 2
            let at1 = rowAt - width, at2 = rowAt - 2 * width
            var label = 0
            if has2 { label |= (Int(px[at2]) << 13) | (Int(px[at2 + 1]) << 12) | (Int(px[at2 + 2]) << 11) }
            if has1 { label |= (Int(px[at1]) << 7) | (Int(px[at1 + 1]) << 6) | (Int(px[at1 + 2]) << 5) | (Int(px[at1 + 3]) << 4) }
            for j in 0..<width {
                let pixel = arith.bit(contexts, label)
                px[rowAt + j] = UInt8(pixel)
                label = ((label & 0x7bf7) << 1) | pixel
                if has2 && j + 3 < width { label |= Int(px[at2 + j + 3]) << 11 }
                if has1 && j + 4 < width { label |= Int(px[at1 + j + 4]) << 4 }
            }
        }
    }

    /// 6.2.6: an MMR coded generic region from `start` to `end`; `used` is
    /// the number of bytes the coded rows took.
    static func mmr(_ budget: Jbig2Budget, _ data: [UInt8], _ start: Int, _ end: Int, _ width: Int, _ height: Int, _ used: inout Int) throws -> Jbig2Bitmap {
        let bitmap = try Jbig2Bitmap(width, height, budget)
        used = 0
        if width == 0 || height == 0 { return bitmap }
        if start > end { throw PdfReadException.damaged("A JBIG2 MMR region has no data.") }
        let packed = Ccitt.decodeMmr(Array(data[start..<end]), width, height, &used)
        let stride = (width + 7) / 8
        var px = bitmap.pixels
        bitmap.pixels = []
        defer { bitmap.pixels = px }
        for y in 0..<height {
            for x in 0..<width { px[y * width + x] = (packed[y * stride + (x >> 3)] >> UInt8(7 - (x & 7))) & 1 }
        }
        return bitmap
    }

    /// 6.3.5: a refinement of `reference`, which sits at (`offsetX`, `offsetY`)
    /// of the new bitmap. `at` has the two adaptive pixels of template 0 (the coding one first).
    static func refine(_ budget: Jbig2Budget, _ arith: Jbig2Arith, _ width: Int, _ height: Int, _ template: Int, _ reference: Jbig2Bitmap,
                       _ offsetX: Int, _ offsetY: Int, _ typicalPrediction: Bool, _ at: [Int]) throws -> Jbig2Bitmap {
        let bitmap = try Jbig2Bitmap(width, height, budget)
        if width == 0 || height == 0 { return bitmap }
        let cx: [Int], cy: [Int], rx: [Int], ry: [Int]
        if template == 0 {
            cx = [0, 1, -1, at[0]]
            cy = [-1, -1, 0, at[1]]
            rx = [0, 1, -1, 0, 1, -1, 0, 1, at[2]]
            ry = [-1, -1, 0, 0, 0, 1, 1, 1, at[3]]
        } else {
            cx = [-1, 0, 1, -1]
            cy = [-1, -1, -1, 0]
            rx = [0, -1, 0, 1, 0, 1]
            ry = [-1, 0, 0, 0, 1, 1]
        }
        var px = bitmap.pixels
        bitmap.pixels = []
        defer { bitmap.pixels = px }
        let contexts = arith.gr
        let pseudoPixelContext = refinementReusedContexts[template]
        var ltp = 0
        for i in 0..<height {
            if typicalPrediction { ltp ^= arith.bit(contexts, pseudoPixelContext) }
            for j in 0..<width {
                // 6.3.5.6: where the 3 by 3 pixels of the reference around this one agree, so does the new pixel.
                if ltp != 0 {
                    let center = referencePixel(reference, j - offsetX, i - offsetY)
                    var same = true
                    var dy = -1
                    while dy <= 1 && same {
                        for dx in -1...1 where referencePixel(reference, j - offsetX + dx, i - offsetY + dy) != center {
                            same = false
                            break
                        }
                        dy += 1
                    }
                    if same {
                        px[i * width + j] = UInt8(center)
                        continue
                    }
                }
                var label = 0
                for k in 0..<cx.count {
                    let i0 = i + cy[k], j0 = j + cx[k]
                    label <<= 1
                    if i0 >= 0 && i0 < height && j0 >= 0 && j0 < width { label |= Int(px[i0 * width + j0]) }
                }
                for k in 0..<rx.count {
                    label = (label << 1) | referencePixel(reference, j + rx[k] - offsetX, i + ry[k] - offsetY)
                }
                px[i * width + j] = UInt8(arith.bit(contexts, label))
            }
        }
        return bitmap
    }

    private static func referencePixel(_ reference: Jbig2Bitmap, _ x: Int, _ y: Int) -> Int {
        x < 0 || y < 0 || x >= reference.width || y >= reference.height ? 0 : Int(reference.pixels[y * reference.width + x])
    }
}
