import Foundation

// Twin of windows/LazyPDF.Core/Compare/PixelAligner.cs: finds the turn and shift between two pages on a shrunken copy. Each
// page is deskewed on its own (the angle that makes its rows of ink sharpest), so the turn between them is the difference;
// the old page is turned by that and the shift is read off the row and column profiles. A search at full size then settles
// the last pixels.

/// The turn and shift that bring an old picture onto a new one: the new picture is sampled at
/// `R(-angle) * (p - centre - shift) + centre`, scaled when the sizes differ.
struct PixelWarp: Equatable {
    let radians: Double
    let shiftX: Double
    let shiftY: Double

    init(_ radians: Double, _ shiftX: Double, _ shiftY: Double) {
        self.radians = radians
        self.shiftX = shiftX
        self.shiftY = shiftY
    }

    static let none = PixelWarp(0, 0, 0)
}

enum PixelAligner {
    private static let smallSide = 512
    private static let maxDegrees = 3.0
    private static let gain = 1.05
    private static let refineSamples = 100_000
    private static let refineReach = 3

    /// The warp for two brightness grids of the same size.
    static func estimate(_ oldLuma: [UInt8], _ newLuma: [UInt8], _ width: Int, _ height: Int) -> PixelWarp {
        let factor = max(1, Int((Double(max(width, height)) / Double(smallSide)).rounded(.up)))
        let (smallOld, w, h) = shrink(oldLuma, width, height, factor)
        let (smallNew, _, _) = shrink(newLuma, width, height, factor)

        let degrees = deskew(smallOld, w, h) - deskew(smallNew, w, h)
        let turned = degrees == 0 ? smallOld : resample(smallOld, w, h, w, h, PixelWarp(degrees * Double.pi / 180, 0, 0), 0)
        let shiftY = correlate(profile(turned, w, h, rows: true), profile(smallNew, w, h, rows: true)).shift
        let shiftX = correlate(profile(turned, w, h, rows: false), profile(smallNew, w, h, rows: false)).shift
        let start = PixelWarp(degrees * Double.pi / 180, (shiftX * Double(factor)).rounded(.toNearestOrEven), (shiftY * Double(factor)).rounded(.toNearestOrEven))
        return refine(oldLuma, newLuma, width, height, start)
    }

    /// The turn, in degrees, that makes the rows of ink in the picture sharpest; 0 unless that is clearly better than leaving it.
    private static func deskew(_ ink: [UInt8], _ w: Int, _ h: Int) -> Double {
        func sharpness(_ degrees: Double) -> Double {
            let turned = degrees == 0 ? ink : resample(ink, w, h, w, h, PixelWarp(degrees * Double.pi / 180, 0, 0), 0)
            let rows = profile(turned, w, h, rows: true)
            var sum = 0.0
            for i in stride(from: 1, to: rows.count, by: 1) { sum += (rows[i] - rows[i - 1]) * (rows[i] - rows[i - 1]) }
            return sum
        }
        let straight = sharpness(0)
        var bestScore = straight, best = 0.0
        var degrees = -maxDegrees
        while degrees <= maxDegrees + 1e-9 {
            let score = sharpness(degrees)
            if score > bestScore { (best, bestScore) = (degrees, score) }
            degrees += 0.5
        }
        let centre = best
        degrees = centre - 0.5
        while degrees <= centre + 0.5 + 1e-9 {
            let score = sharpness(degrees)
            if score > bestScore { (best, bestScore) = (degrees, score) }
            degrees += 0.1
        }
        // Math.Round(best, 3): scaled, rounded half to even, scaled back.
        return bestScore > straight * gain ? (best * 1000).rounded(.toNearestOrEven) / 1000 : 0
    }

    /// Box average of a grid, as ink: 255 where the page is black.
    private static func shrink(_ luma: [UInt8], _ width: Int, _ height: Int, _ factor: Int) -> (ink: [UInt8], width: Int, height: Int) {
        let w = max(1, width / factor), h = max(1, height / factor)
        var ink = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                var sum = 0, count = 0
                for yy in stride(from: y * factor, to: min(height, (y + 1) * factor), by: 1) {
                    for xx in stride(from: x * factor, to: min(width, (x + 1) * factor), by: 1) {
                        sum += Int(luma[yy * width + xx])
                        count += 1
                    }
                }
                ink[y * w + x] = UInt8(truncatingIfNeeded: 255 - sum / max(count, 1))
            }
        }
        return (ink, w, h)
    }

    private static func profile(_ ink: [UInt8], _ w: Int, _ h: Int, rows: Bool) -> [Double] {
        var profile = [Double](repeating: 0, count: rows ? h : w)
        for y in 0..<h {
            for x in 0..<w { profile[rows ? y : x] += Double(ink[y * w + x]) }
        }
        return profile
    }

    /// The shift s that makes `old[i]` best match `updated[i + s]`, by normalised cross-correlation over a quarter of the
    /// length each way. The peak is read between the samples (a parabola through the three around it), so that a shift of
    /// half a pixel does not look like a worse match than a whole one.
    private static func correlate(_ old: [Double], _ updated: [Double]) -> (score: Double, shift: Double) {
        let n = old.count
        var sumA = 0.0, sumB = 0.0
        for v in old { sumA += v }
        for v in updated { sumB += v }
        let meanA = sumA / Double(n), meanB = sumB / Double(n)
        var normA = 0.0, normB = 0.0
        for v in old { normA += (v - meanA) * (v - meanA) }
        for v in updated { normB += (v - meanB) * (v - meanB) }
        if normA < 1e-9 || normB < 1e-9 { return (0, 0) }
        let scale = 1 / (normA * normB).squareRoot()
        let reach = n / 4
        var scores = [Double](repeating: 0, count: 2 * reach + 1)
        var best = reach
        for s in -reach...reach {
            var sum = 0.0
            for i in stride(from: max(0, -s), to: min(n, n - s), by: 1) { sum += (old[i] - meanA) * (updated[i + s] - meanB) }
            scores[s + reach] = sum * scale
            // Ties go to the smaller shift, so a blank margin does not pull a page sideways.
            if scores[s + reach] > scores[best] + 1e-12 || (abs(scores[s + reach] - scores[best]) <= 1e-12 && abs(s) < abs(best - reach)) { best = s + reach }
        }
        if best == 0 || best == scores.count - 1 { return (scores[best], Double(best - reach)) }
        let left = scores[best - 1], middle = scores[best], right = scores[best + 1]
        let curve = left - 2 * middle + right
        if curve >= -1e-12 { return (middle, Double(best - reach)) }
        let offset = 0.5 * (left - right) / curve
        return (middle - 0.25 * (left - right) * offset, Double(best - reach) + offset)
    }

    /// Looks around the estimate at full size: shifts up to `refineReach` pixels and a few hundredths of a degree either way,
    /// keeping the one with the least brightness difference over a sample of the page.
    private static func refine(_ oldLuma: [UInt8], _ newLuma: [UInt8], _ width: Int, _ height: Int, _ start: PixelWarp) -> PixelWarp {
        let step = max(1, Int((Double(width) * Double(height) / Double(refineSamples)).squareRoot()))
        var best = start
        var bestCost = cost(oldLuma, newLuma, width, height, start, step, Int.max)
        for turn in [0, -0.05, 0.05, -0.1, 0.1] {
            for dy in -refineReach...refineReach {
                for dx in -refineReach...refineReach {
                    let warp = PixelWarp(start.radians + turn * Double.pi / 180, start.shiftX + Double(dx), start.shiftY + Double(dy))
                    let value = cost(oldLuma, newLuma, width, height, warp, step, bestCost)
                    if value < bestCost {
                        bestCost = value
                        best = warp
                    }
                }
            }
        }
        return best
    }

    private static func cost(_ oldLuma: [UInt8], _ newLuma: [UInt8], _ w: Int, _ h: Int, _ warp: PixelWarp, _ step: Int, _ limit: Int) -> Int {
        let map = Mapping(w, h, w, h, warp)
        var total = 0
        var y = 0
        while y < h {
            var x = 0
            while x < w {
                let (sx, sy) = map.source(x, y)
                let ix = roundedInt(sx), iy = roundedInt(sy)
                let value = ix < 0 || iy < 0 || ix >= w || iy >= h ? 255 : Int(oldLuma[iy * w + ix])
                total += abs(value - Int(newLuma[y * w + x]))
                x += step
            }
            if total >= limit { return total }
            y += step
        }
        return total
    }

    /// `(int)Math.Round(x)`, which in C# does not fail for a value that is not finite or too large; a Swift `Int(x)` would trap.
    static func roundedInt(_ x: Double) -> Int {
        if x.isNaN { return 0 }
        let r = x.rounded(.toNearestOrEven)
        if r >= 9e18 { return Int.max }
        if r <= -9e18 { return Int.min }
        return Int(r)
    }

    /// Samples `source` onto a grid of the new page's size, bilinear, with `fill` outside it.
    static func resample(_ source: [UInt8], _ sourceWidth: Int, _ sourceHeight: Int, _ width: Int, _ height: Int, _ warp: PixelWarp, _ fill: UInt8) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: width * height)
        let map = Mapping(width, height, sourceWidth, sourceHeight, warp)
        for y in 0..<height {
            for x in 0..<width {
                let (sx, sy) = map.source(x, y)
                if !(sx >= -0.5 && sy >= -0.5 && sx <= Double(sourceWidth) - 0.5 && sy <= Double(sourceHeight) - 0.5) {
                    result[y * width + x] = fill
                    continue
                }
                var x0 = Int(sx.rounded(.down)), y0 = Int(sy.rounded(.down))
                let fx = sx - Double(x0), fy = sy - Double(y0)
                let x1 = min(sourceWidth - 1, x0 + 1), y1 = min(sourceHeight - 1, y0 + 1)
                x0 = max(0, x0)
                y0 = max(0, y0)
                let top = Double(source[y0 * sourceWidth + x0]) * (1 - fx) + Double(source[y0 * sourceWidth + x1]) * fx
                let bottom = Double(source[y1 * sourceWidth + x0]) * (1 - fx) + Double(source[y1 * sourceWidth + x1]) * fx
                result[y * width + x] = UInt8(truncatingIfNeeded: roundedInt(top * (1 - fy) + bottom * fy))
            }
        }
        return result
    }

    private struct Mapping {
        private let cosine: Double, sine: Double, cx: Double, cy: Double
        private let shiftX: Double, shiftY: Double, scaleX: Double, scaleY: Double

        init(_ width: Int, _ height: Int, _ sourceWidth: Int, _ sourceHeight: Int, _ warp: PixelWarp) {
            cosine = Foundation.cos(warp.radians)
            sine = Foundation.sin(warp.radians)
            cx = Double(width - 1) / 2.0
            cy = Double(height - 1) / 2.0
            (shiftX, shiftY) = (warp.shiftX, warp.shiftY)
            (scaleX, scaleY) = (Double(sourceWidth) / Double(width), Double(sourceHeight) / Double(height))
        }

        func source(_ x: Int, _ y: Int) -> (x: Double, y: Double) {
            let px = Double(x) - cx - shiftX, py = Double(y) - cy - shiftY
            let ux = cosine * px + sine * py + cx, uy = -sine * px + cosine * py + cy
            return ((ux + 0.5) * scaleX - 0.5, (uy + 0.5) * scaleY - 0.5)
        }
    }
}
