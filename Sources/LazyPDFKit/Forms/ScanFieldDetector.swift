import Foundation

// Twin of windows/LazyPDF.Core/Forms/ScanFieldDetector.cs: finds blanks on a scanned page from its pixels, where
// `FieldDetector` has no vector content to read. The page is drawn by the renderer and cut to black and white; long
// horizontal runs of ink become ruled lines, and two lines of one length with ink running down both ends become a box.
// Boxes split at the rules inside them; empty ones are proposed, as are lines with nothing written above them. The words
// beside a blank come from the page's text layer when OCR has put one there. There is no deskew, so a page turned by more
// than about a fifth of a degree loses its longer lines.
//
// The renderer's image is refused when it holds more pixels than `PdfImageSamples.maxPixels` or fewer bytes than its size
// says, where the C# would allocate or index past the end.

enum ScanFieldDetector {
    private static let dpi = 150.0
    private static let minBlank = 36.0
    private static let minSide = 6.0
    private static let labelReach = 150.0
    private static let slack = 3
    private static let maxGap = 2
    private static let maxSegments = 4_000
    private static let maxProposals = 200
    private static let maxInk = 0.03

    private struct Seg: Hashable {
        let x1: Int, x2: Int, y1: Int, y2: Int

        var width: Int { x2 - x1 + 1 }
        var thick: Int { y2 - y1 + 1 }
    }

    private struct Ink {
        let width: Int
        let height: Int
        let dark: [Bool]

        subscript(x: Int, y: Int) -> Bool { dark[y * width + x] }

        /// The share of the pixels of the rectangle (ends included) that are ink.
        func share(_ left: Int, _ top: Int, _ right: Int, _ bottom: Int) -> Double {
            let x1 = max(0, left), y1 = max(0, top)
            let x2 = min(width - 1, right), y2 = min(height - 1, bottom)
            if x2 < x1 || y2 < y1 { return 1 }
            var count = 0
            for y in y1...y2 {
                for x in x1...x2 where self[x, y] { count += 1 }
            }
            return Double(count) / Double((x2 - x1 + 1) * (y2 - y1 + 1))
        }

        /// The share of rows of y1 to y2 with ink within two pixels of x: a vertical rule that may waver.
        func down(_ x: Int, _ y1: Int, _ y2: Int) -> Double {
            var rows = 0
            if y1 <= y2 {
                for y in y1...y2 {
                    for d in -2...2 where x + d >= 0 && x + d < width && self[x + d, y] {
                        rows += 1
                        break
                    }
                }
            }
            return Double(rows) / Double(max(1, y2 - y1 + 1))
        }

        func column(_ x: Int, _ y1: Int, _ y2: Int) -> Double { share(x, y1, x, y2) }
    }

    private struct Candidate {
        let place: Seg
        let kind: FieldKind
        var cells = 0
        var multiline = false
        var onLine = false
    }

    static func detect(_ document: PdfDocument, _ page: PdfPage, _ form: PdfForm, _ names: inout Set<[UInt16]>,
                       _ renderer: PageRenderer, _ vector: [FieldProposal]) -> [FieldProposal] {
        guard let image = renderer.render(page.index, dpi), image.width >= 16, image.height >= 16 else { return [] }
        let (pixels, overflow) = image.width.multipliedReportingOverflow(by: image.height)
        if overflow || pixels > PdfImageSamples.maxPixels || image.rgba.count < pixels * 4 { return [] }
        let geometry = PageGeometry(page)
        let scale = Double(image.width) / geometry.width
        let ink = cut(image)
        let thickest = max(4, ink.width / 150)
        let segments = merge(self.segments(ink, Int(saturating32: (minSide * scale).rounded(.toNearestOrEven)), thickest), thickest)
        if segments.isEmpty || segments.count > maxSegments { return [] }

        var edges = Set<Seg>()
        var found: [Candidate] = []
        boxes(ink, segments, scale, &edges, &found)
        lines(ink, segments, scale, edges, &found)

        let text = TextPage.create(document, page)
        var taken = form.fields.flatMap { $0.widgets }.filter { $0.pageIndex == page.index }.map { $0.rect } + vector.map { $0.rect }
        var accepted: [FieldProposal] = []
        for c in stableSorted(found, { a, b in a.place.y1 != b.place.y1 ? a.place.y1 < b.place.y1 : a.place.x1 < b.place.x1 }) {
            if accepted.count >= maxProposals { break }
            let w = c.place
            let label: PageLine?
            let rect: PdfRect
            if c.onLine {
                // The field stands a point above its line, as tall as the label's text suggests.
                func above(_ height: Double) -> PdfRect {
                    userRect(geometry, scale, w.x1, w.y1 - Int(saturating32: ((height + 1) * scale).rounded(.toNearestOrEven)), w.x2 + 1,
                             w.y1 - Int(saturating32: scale.rounded(.toNearestOrEven)))
                }
                label = Self.label(text, above(14), false)
                rect = above(min(max((label?.bounds.height ?? 0) * 1.3, 14), 22))
            } else {
                rect = userRect(geometry, scale, w.x1, w.y1, w.x2 + 1, w.y2 + 1)
                label = Self.label(text, rect, c.kind == .checkBox)
            }
            if taken.contains(where: { FieldDetector.covers($0, rect) }) { continue }
            taken.append(rect)
            var proposal = FieldProposal(page.index, rect, c.kind, FieldDetector.unique(&names, label?.text, c.kind), FieldDetector.clean(label?.text))
            proposal.cells = c.cells
            proposal.multiline = c.multiline
            proposal.fromPixels = true
            accepted.append(proposal)
        }
        return accepted
    }

    private static func userRect(_ geometry: PageGeometry, _ scale: Double, _ x1: Int, _ y1: Int, _ x2: Int, _ y2: Int) -> PdfRect {
        geometry.toUser(DisplayRect(Double(x1) / scale, Double(y1) / scale, Double(x2 - x1) / scale, Double(y2 - y1) / scale))
    }

    // Otsu's threshold, kept between 100 and 190 so that a nearly blank page does not turn its noise into ink.
    private static func cut(_ image: PdfRgbaImage) -> Ink {
        let count = image.width * image.height
        var gray = [UInt8](repeating: 0, count: count)
        var histogram = [Int](repeating: 0, count: 256)
        for i in 0..<count {
            let o = i * 4
            gray[i] = UInt8(truncatingIfNeeded: (Int(image.rgba[o]) * 299 + Int(image.rgba[o + 1]) * 587 + Int(image.rgba[o + 2]) * 114) / 1000)
            histogram[Int(gray[i])] += 1
        }
        var sum = 0.0
        for t in 0..<256 { sum += Double(t) * Double(histogram[t]) }
        var below = 0.0, best = -1.0
        var weightBelow = 0, threshold = 128
        for t in 0..<256 {
            weightBelow += histogram[t]
            if weightBelow == 0 || weightBelow == count { continue }
            below += Double(t) * Double(histogram[t])
            let a = below / Double(weightBelow), b = (sum - below) / Double(count - weightBelow)
            let between = Double(weightBelow) * Double(count - weightBelow) * (a - b) * (a - b)
            if between > best {
                best = between
                threshold = t
            }
        }
        threshold = min(max(threshold, 100), 190)
        return Ink(width: image.width, height: image.height, dark: gray.map { Int($0) <= threshold })
    }

    private static func runs(_ ink: Ink, _ y: Int, _ minLength: Int) -> [(x1: Int, x2: Int)] {
        var result: [(x1: Int, x2: Int)] = []
        var x = 0
        while x < ink.width {
            if !ink[x, y] {
                x += 1
                continue
            }
            let start = x
            var end = x, gap = 0
            while x < ink.width {
                if ink[x, y] {
                    end = x
                    gap = 0
                } else {
                    gap += 1
                    if gap > maxGap { break }
                }
                x += 1
            }
            if end - start + 1 >= minLength { result.append((start, end)) }
            x = end + 1
        }
        return result
    }

    // Runs on neighbouring rows that begin and end together are the rows of one line; one that gets thick is a bar or a picture.
    private static func segments(_ ink: Ink, _ minLength: Int, _ thickest: Int) -> [Seg] {
        var done: [Seg] = []
        var open: [Seg] = []
        var y = 0
        while y < ink.height && done.count <= maxSegments {
            var next: [Seg] = []
            for (x1, x2) in runs(ink, y, minLength) {
                guard let at = open.firstIndex(where: { abs($0.x1 - x1) <= slack && abs($0.x2 - x2) <= slack }) else {
                    next.append(Seg(x1: x1, x2: x2, y1: y, y2: y))
                    continue
                }
                let s = open.remove(at: at)
                next.append(Seg(x1: min(s.x1, x1), x2: max(s.x2, x2), y1: s.y1, y2: y))
            }
            done.append(contentsOf: open.filter { $0.thick <= thickest })
            open = next
            y += 1
        }
        done.append(contentsOf: open.filter { $0.thick <= thickest })
        return done
    }

    // A line drawn thick, or a little off level, breaks into pieces on neighbouring rows; they are one line. Pieces that
    // still abut after that are the steps of a line too slanted to follow, and give nothing.
    private static func merge(_ segments: [Seg], _ thickest: Int) -> [Seg] {
        var sorted = stableSorted(segments) { a, b in a.y1 != b.y1 ? a.y1 < b.y1 : a.x1 < b.x1 }
        var i = 0
        while i < sorted.count {
            var j = i + 1
            while j < sorted.count && sorted[j].y1 <= sorted[i].y2 + 2 {
                let a = sorted[i]
                let b = sorted[j]
                let overlap = min(a.x2, b.x2) - max(a.x1, b.x1) + 1
                let same = Double(overlap) >= 0.7 * Double(min(a.width, b.width))
                let step = !same && overlap >= -slack - 1
                let joined = Seg(x1: min(a.x1, b.x1), x2: max(a.x2, b.x2), y1: min(a.y1, b.y1), y2: max(a.y2, b.y2))
                if !(same || step) || joined.thick > thickest {
                    j += 1
                    continue
                }
                sorted[i] = joined
                sorted.remove(at: j)
            }
            i += 1
        }
        return sorted.filter { a in
            !sorted.contains { b in
                b != a && abs(a.y1 - b.y1) <= thickest + 1 && min(a.x2, b.x2) - max(a.x1, b.x1) >= -slack - 1 && a.y1 != b.y1
            }
        }
    }

    private static func boxes(_ ink: Ink, _ segments: [Seg], _ scale: Double, _ edges: inout Set<Seg>, _ found: inout [Candidate]) {
        let minHeight = Int(saturating32: (minSide * scale).rounded(.toNearestOrEven)), maxHeight = ink.height / 2
        for i in 0..<segments.count {
            let top = segments[i]
            if Double(top.width) > 0.95 * Double(ink.width) { continue }
            for j in (i + 1)..<max(i + 1, segments.count) {
                let bottom = segments[j]
                let height = bottom.y1 - top.y2
                if height > maxHeight { break }
                if height < minHeight || abs(top.x1 - bottom.x1) > slack || abs(top.x2 - bottom.x2) > slack { continue }
                if ink.down(top.x1 + 1, top.y2, bottom.y1) < 0.9 || ink.down(top.x2 - 1, top.y2, bottom.y1) < 0.9 { continue }
                edges.insert(top)
                edges.insert(bottom)
                cells(ink, top, bottom, scale, &found)
                break
            }
        }
    }

    // The box between two lines, cut at the vertical rules inside it. Cells with ink in them are filled in already.
    private static func cells(_ ink: Ink, _ top: Seg, _ bottom: Seg, _ scale: Double, _ found: inout [Candidate]) {
        let x1 = min(top.x1, bottom.x1), x2 = max(top.x2, bottom.x2)
        let y1 = top.y1, y2 = bottom.y2
        let inner1 = top.y2 + 1, inner2 = bottom.y1 - 1
        var cuts = [x1]
        var x = x1 + slack + 1
        while x < x2 - slack - 1 {
            if ink.column(x, inner1, inner2) < 0.85 {
                x += 1
                continue
            }
            var end = x
            while end + 1 < x2 - slack - 1 && ink.column(end + 1, inner1, inner2) >= 0.85 { end += 1 }
            cuts.append((x + end) / 2)
            x = end + 1
        }
        cuts.append(x2)

        var spans: [(cell: Seg, empty: Bool)] = []
        for c in 0..<(cuts.count - 1) {
            // The rule on each side is part of the cell's border, not of what is written in it.
            let left = cuts[c] + slack + 1, right = cuts[c + 1] - slack - 1
            let empty = right - left >= 2 && ink.share(left, inner1 + 1, right, inner2 - 1) <= maxInk
            spans.append((Seg(x1: cuts[c], x2: cuts[c + 1], y1: y1, y2: y2), empty))
        }

        let mean = spans.map { Double($0.cell.width) }.reduce(0, +) / Double(spans.count)
        if spans.count >= 3 && spans.allSatisfy({ $0.empty }) && mean / scale <= 30 && spans.allSatisfy({ abs(Double($0.cell.width) - mean) <= 0.15 * mean }) {
            var candidate = Candidate(place: Seg(x1: x1, x2: x2, y1: y1, y2: y2), kind: .text)
            candidate.cells = spans.count
            found.append(candidate)
            return
        }
        for (cell, empty) in spans where empty {
            let w = Double(cell.width) / scale, h = Double(cell.thick) / scale
            if max(w, h) <= 30 && min(w, h) >= minSide && max(w, h) <= 1.35 * min(w, h) {
                found.append(Candidate(place: cell, kind: .checkBox))
            } else if w >= 24 && h >= 9 {
                var candidate = Candidate(place: cell, kind: .text)
                candidate.multiline = h >= 36
                found.append(candidate)
            }
        }
    }

    // A ruled line that is not the side of a box, with nothing above it where a person would write.
    private static func lines(_ ink: Ink, _ segments: [Seg], _ scale: Double, _ edges: Set<Seg>, _ found: inout [Candidate]) {
        let reach = Int(saturating32: (12 * scale).rounded(.toNearestOrEven))
        for line in segments {
            let width = Double(line.width) / scale
            if edges.contains(line) || width < minBlank || Double(line.width) > 0.8 * Double(ink.width) || Double(line.thick) > 3 * scale { continue }
            let from = line.y1 - reach, to = line.y1 - 2
            if from < 0 || ink.share(line.x1 + 2, from, line.x2 - 2, to) > 0.02 { continue }
            var candidate = Candidate(place: line, kind: .text)
            candidate.onLine = true
            found.append(candidate)
        }
    }

    private static func label(_ text: TextPage, _ rect: PdfRect, _ toRight: Bool) -> PageLine? {
        var beside: [(line: PageLine, gap: Double)] = []
        for l in text.lines where !FormFunctions.trim(l.text).isEmpty && FieldDetector.vertical(l.bounds, rect) {
            let gap = toRight ? l.bounds.left - rect.right : rect.left - l.bounds.right
            if gap >= -2 && gap <= labelReach { beside.append((l, gap)) }
        }
        if let nearest = stableSorted(beside, { $0.gap < $1.gap }).first { return nearest.line }
        let above = text.lines.filter { l in
            !FormFunctions.trim(l.text).isEmpty && l.bounds.bottom >= rect.top - 2 && l.bounds.bottom - rect.top <= 18
                && l.bounds.left >= rect.left - 10 && l.bounds.left <= rect.right
        }
        return stableSorted(above) { $0.bounds.bottom < $1.bounds.bottom }.first
    }
}
