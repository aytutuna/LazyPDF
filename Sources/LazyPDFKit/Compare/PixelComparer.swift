import Foundation

// Twin of windows/LazyPDF.Core/Compare/PixelComparer.cs: compares two rendered pages pixel by pixel. The old page is first
// brought onto the new one's grid (resized if the sizes differ, turned and shifted by what a search over a shrunken copy
// finds, which is what a re-scan needs), then a pixel differs when no pixel near its place on the other page is close in
// colour.

/// `threshold`: how far a colour channel must differ, 0 to 255, to count. `tolerance`: a pixel that matches one within this
/// many pixels of its place is not a difference; this absorbs edges that fall differently on the grid. `align`: find the turn
/// and shift of the old page first. `minPixels`: regions with fewer differing pixels are noise and dropped.
public struct PixelOptions: Equatable {
    public let threshold: Int
    public let tolerance: Int
    public let align: Bool
    public let minPixels: Int

    public init(threshold: Int = 40, tolerance: Int = 1, align: Bool = true, minPixels: Int = 4) {
        self.threshold = threshold
        self.tolerance = tolerance
        self.align = align
        self.minPixels = minPixels
    }
}

/// `region` is in page points as displayed, origin top left.
public struct PixelDifference: Equatable {
    public let region: DisplayRect
    public let pixels: Int

    public init(_ region: DisplayRect, _ pixels: Int) {
        self.region = region
        self.pixels = pixels
    }
}

/// `shiftX`: how far the old page had to move right, in pixels of the new one. `shiftY`: down. `degrees`: how far it had to
/// turn, clockwise on screen.
public struct PixelAlignment: Equatable {
    public let shiftX: Double
    public let shiftY: Double
    public let degrees: Double

    public init(_ shiftX: Double, _ shiftY: Double, _ degrees: Double) {
        self.shiftX = shiftX
        self.shiftY = shiftY
        self.degrees = degrees
    }
}

/// `similarity` is 0 to 1: one minus the differing pixels over the pixels either page inks. `overlay` is the new page faded,
/// with ink only the new page has in green and ink only the old page has in red.
public struct PixelComparison {
    public let differences: [PixelDifference]
    public let similarity: Double
    public let alignment: PixelAlignment
    public let overlay: PdfRgbaImage

    public init(_ differences: [PixelDifference], _ similarity: Double, _ alignment: PixelAlignment, _ overlay: PdfRgbaImage) {
        self.differences = differences
        self.similarity = similarity
        self.alignment = alignment
        self.overlay = overlay
    }
}

public enum PixelComparer {
    private static let maxRegions = 5000
    private static let inkLevel = 200

    /// Renders both pages at `dpi` and compares them; nil when either cannot be drawn.
    public static func compare(_ before: PageRenderer, _ beforePage: Int, _ after: PageRenderer, _ afterPage: Int, _ dpi: Double,
                               _ options: PixelOptions? = nil) throws -> PixelComparison? {
        guard let a = before.render(beforePage, dpi), let b = after.render(afterPage, dpi) else { return nil }
        return try compare(a, b, dpi, options)
    }

    /// `dpi` is the resolution of `after`, to put regions in points. Throws `ArgumentException` when an image is empty or
    /// its data is too short.
    public static func compare(_ before: PdfRgbaImage, _ after: PdfRgbaImage, _ dpi: Double, _ options: PixelOptions? = nil) throws -> PixelComparison {
        let options = options ?? PixelOptions()
        try check(before)
        try check(after)
        let w = after.width, h = after.height
        let planes = Self.planes(after)
        let oldPlanes = Self.planes(before)
        let oldLuma = luma(oldPlanes)
        let newLuma = luma(planes)

        var warp = PixelWarp.none
        if options.align {
            let fitted = before.width == w && before.height == h ? oldLuma : PixelAligner.resample(oldLuma, before.width, before.height, w, h, .none, 255)
            warp = PixelAligner.estimate(fitted, newLuma, w, h)
        }
        let same = warp == .none && before.width == w && before.height == h
        let moved = same ? oldPlanes : oldPlanes.map { PixelAligner.resample($0, before.width, before.height, w, h, warp, 255) }

        let mask = differences(moved, planes, w, h, options)
        let grow = max(1, PixelAligner.roundedInt(dpi / 50))
        let (regions, keep) = Self.regions(mask, w, h, grow, options.minPixels)

        let oldAligned = luma(moved)
        var ink = 0, differing = 0
        for i in 0..<mask.count {
            if Int(oldAligned[i]) < inkLevel || Int(newLuma[i]) < inkLevel { ink += 1 }
            if keep[i] { differing += 1 }
        }
        let similarity = ink == 0 ? (differing == 0 ? 1 : 0) : min(max(1 - Double(differing) / Double(ink), 0), 1)

        let toPoints = 72 / dpi
        let found = regions.map {
            PixelDifference(DisplayRect(Double($0.left) * toPoints, Double($0.top) * toPoints,
                                        Double($0.right - $0.left + 1) * toPoints, Double($0.bottom - $0.top + 1) * toPoints), $0.pixels)
        }
        let alignment = PixelAlignment(warp.shiftX, warp.shiftY, warp.radians * 180 / Double.pi)
        return PixelComparison(found, similarity, alignment, overlay(newLuma, oldAligned, keep, w, h))
    }

    private static func check(_ image: PdfRgbaImage) throws {
        let (pixels, overflow) = image.width.multipliedReportingOverflow(by: image.height)
        let (bytes, overflowed) = pixels.multipliedReportingOverflow(by: 4)
        if image.width <= 0 || image.height <= 0 || overflow || overflowed || image.rgba.count < bytes {
            throw ArgumentException("The image is empty or its data is too short.")
        }
    }

    private static func planes(_ image: PdfRgbaImage) -> [[UInt8]] {
        let n = image.width * image.height
        var planes = [[UInt8]](repeating: [UInt8](repeating: 0, count: n), count: 3)
        for i in 0..<n {
            // Straight alpha over white, as the page is shown.
            let a = Int(image.rgba[i * 4 + 3])
            for c in 0..<3 { planes[c][i] = UInt8(truncatingIfNeeded: (Int(image.rgba[i * 4 + c]) * a + 255 * (255 - a)) / 255) }
        }
        return planes
    }

    private static func luma(_ planes: [[UInt8]]) -> [UInt8] {
        var luma = [UInt8](repeating: 0, count: planes[0].count)
        for i in 0..<luma.count {
            luma[i] = UInt8(truncatingIfNeeded: (Int(planes[0][i]) * 77 + Int(planes[1][i]) * 151 + Int(planes[2][i]) * 28) >> 8)
        }
        return luma
    }

    private static func differences(_ a: [[UInt8]], _ b: [[UInt8]], _ w: Int, _ h: Int, _ options: PixelOptions) -> [Bool] {
        var mask = [Bool](repeating: false, count: w * h)
        var low = [UInt8](repeating: 0, count: w * h)
        var high = [UInt8](repeating: 0, count: w * h)
        for c in 0..<3 {
            extremes(b[c], w, h, options.tolerance, &low, &high)
            mark(a[c], low, high, options.threshold, &mask)
            extremes(a[c], w, h, options.tolerance, &low, &high)
            mark(b[c], low, high, options.threshold, &mask)
        }
        return mask
    }

    private static func mark(_ value: [UInt8], _ low: [UInt8], _ high: [UInt8], _ threshold: Int, _ mask: inout [Bool]) {
        for i in 0..<value.count {
            if Int(low[i]) - Int(value[i]) > threshold || Int(value[i]) - Int(high[i]) > threshold { mask[i] = true }
        }
    }

    /// The smallest and largest value in the (2r+1) square around each pixel, in two passes.
    private static func extremes(_ source: [UInt8], _ w: Int, _ h: Int, _ tolerance: Int, _ low: inout [UInt8], _ high: inout [UInt8]) {
        // A reach past the page sees all of it; the clamp only keeps the sums below from overflowing.
        let r = max(-(w + h), min(tolerance, w + h))
        var rowLow = [UInt8](repeating: 0, count: source.count)
        var rowHigh = [UInt8](repeating: 0, count: source.count)
        for y in 0..<h {
            for x in 0..<w {
                var lo: UInt8 = 255, hi: UInt8 = 0
                var xx = max(0, x - r)
                while xx <= min(w - 1, x + r) {
                    let v = source[y * w + xx]
                    if v < lo { lo = v }
                    if v > hi { hi = v }
                    xx += 1
                }
                rowLow[y * w + x] = lo
                rowHigh[y * w + x] = hi
            }
        }
        for y in 0..<h {
            for x in 0..<w {
                var lo: UInt8 = 255, hi: UInt8 = 0
                var yy = max(0, y - r)
                while yy <= min(h - 1, y + r) {
                    lo = min(lo, rowLow[yy * w + x])
                    hi = max(hi, rowHigh[yy * w + x])
                    yy += 1
                }
                low[y * w + x] = lo
                high[y * w + x] = hi
            }
        }
    }

    private struct Region {
        let left: Int
        let top: Int
        let right: Int
        let bottom: Int
        let pixels: Int
    }

    /// Differing pixels within 2 x grow of each other make one region. `keep` marks the pixels of the regions that stay.
    private static func regions(_ mask: [Bool], _ w: Int, _ h: Int, _ grow: Int, _ minPixels: Int) -> (regions: [Region], keep: [Bool]) {
        var keep = [Bool](repeating: false, count: mask.count)
        let near = dilate(mask, w, h, grow)
        var label = [Int](repeating: 0, count: mask.count)
        var regions: [Region] = []
        var stack: [Int] = []
        var members: [Int] = []
        var labels = 0
        var start = 0
        while start < near.count && regions.count < maxRegions {
            defer { start += 1 }
            if !near[start] || label[start] != 0 { continue }
            labels += 1
            let id = labels
            var left = w, top = h, right = -1, bottom = -1, pixels = 0
            members.removeAll(keepingCapacity: true)
            label[start] = id
            stack.append(start)
            while let p = stack.popLast() {
                let x = p % w, y = p / w
                if mask[p] {
                    pixels += 1
                    members.append(p)
                    left = min(left, x)
                    right = max(right, x)
                    top = min(top, y)
                    bottom = max(bottom, y)
                }
                for ny in max(0, y - 1)...min(h - 1, y + 1) {
                    for nx in max(0, x - 1)...min(w - 1, x + 1) {
                        let q = ny * w + nx
                        if !near[q] || label[q] != 0 { continue }
                        label[q] = id
                        stack.append(q)
                    }
                }
            }
            if pixels < minPixels { continue }
            regions.append(Region(left: left, top: top, right: right, bottom: bottom, pixels: pixels))
            for p in members { keep[p] = true }
        }
        return (regions, keep)
    }

    private static func dilate(_ mask: [Bool], _ w: Int, _ h: Int, _ r: Int) -> [Bool] {
        var across = [Bool](repeating: false, count: mask.count)
        for y in 0..<h {
            var last = -1_000_000
            for x in 0..<w {
                if mask[y * w + x] { last = x }
                if x - last <= r { across[y * w + x] = true }
            }
            last = 1_000_000_000
            for x in stride(from: w - 1, through: 0, by: -1) {
                if mask[y * w + x] { last = x }
                if last - x <= r { across[y * w + x] = true }
            }
        }
        var result = [Bool](repeating: false, count: mask.count)
        for x in 0..<w {
            var last = -1_000_000
            for y in 0..<h {
                if across[y * w + x] { last = y }
                if y - last <= r { result[y * w + x] = true }
            }
            last = 1_000_000_000
            for y in stride(from: h - 1, through: 0, by: -1) {
                if across[y * w + x] { last = y }
                if last - y <= r { result[y * w + x] = true }
            }
        }
        return result
    }

    private static func overlay(_ newLuma: [UInt8], _ oldLuma: [UInt8], _ keep: [Bool], _ w: Int, _ h: Int) -> PdfRgbaImage {
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<newLuma.count {
            let faded = UInt8(truncatingIfNeeded: Int(255 - Double(255 - Int(newLuma[i])) * 0.35))
            var (r, g, b) = (faded, faded, faded)
            if keep[i] { (r, g, b) = newLuma[i] < oldLuma[i] ? (0, 170, 0) : (220, 0, 0) }
            rgba[i * 4] = r
            rgba[i * 4 + 1] = g
            rgba[i * 4 + 2] = b
            rgba[i * 4 + 3] = 255
        }
        return PdfRgbaImage(w, h, rgba)
    }
}
