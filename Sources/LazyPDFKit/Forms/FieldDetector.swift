import Foundation

// Twin of windows/LazyPDF.Core/Forms/FieldDetector.cs: finds blanks on a page that look like they are meant to be filled
// in: ruled lines and underscore runs with nothing written on them, small empty squares and circles, empty boxes, rows of
// boxes (comb fields), and a gap after a label that ends with a colon. It reads the page through the content interpreter,
// so lines and text inside form XObjects count; scanned pages with no vector content give nothing. The C#
// CancellationToken of the renderer overload is the task's.

/// A field the detector suggests. Nothing is added until the caller accepts it with `PdfForm.addField`. `name` comes from
/// the label next to the blank, unique among the form's fields and the other proposals; `cells` is the number of boxes of a
/// comb field, 0 for any other; `fromPixels` says it was read from the pixels of a scanned page, which is a better guess
/// than a ruling in the file but still a guess.
public struct FieldProposal {
    public let pageIndex: Int
    public let rect: PdfRect
    public let kind: FieldKind
    public let name: String
    public let label: String?
    public var cells = 0
    public var multiline = false
    public var fromPixels = false

    public init(_ pageIndex: Int, _ rect: PdfRect, _ kind: FieldKind, _ name: String, _ label: String?) {
        self.pageIndex = pageIndex
        self.rect = rect
        self.kind = kind
        self.name = name
        self.label = label
    }

    /// The proposal as a spec for `PdfForm.addField`.
    public func toSpec() -> FieldSpec {
        var flags = FieldFlags.none
        if cells > 0 { flags.insert(.comb) }
        if multiline { flags.insert(.multiline) }
        return FieldSpec(kind, name, pageIndex, rect, flags: flags, maxLength: cells, tooltip: label,
                         borderColor: kind == .text && cells == 0 ? nil : [0])
    }
}

public enum FieldDetector {
    private static let minBlank = 36.0
    private static let labelReach = 150.0
    private static let overlap = 0.3

    private struct Candidate {
        let rect: PdfRect
        let kind: FieldKind
        let labelRight: Bool
        var label: String?
        var cells = 0
        var multiline = false

        init(_ rect: PdfRect, _ kind: FieldKind, _ labelRight: Bool, label: String? = nil, cells: Int = 0, multiline: Bool = false) {
            self.rect = rect
            self.kind = kind
            self.labelRight = labelRight
            self.label = label
            self.cells = cells
            self.multiline = multiline
        }
    }

    private struct RectKey: Hashable {
        let left: Double, bottom: Double, right: Double, top: Double

        init(_ r: PdfRect) {
            left = r.left + 0
            bottom = r.bottom + 0
            right = r.right + 0
            top = r.top + 0
        }
    }

    public static func detect(_ document: PdfDocument) -> [FieldProposal] {
        let form = PdfForm.read(document)
        var names = Set(form.fields.map { Array($0.name.utf16) })
        var found: [FieldProposal] = []
        for page in document.pages { found.append(contentsOf: detectPage(document, page, form, &names)) }
        return found
    }

    public static func detect(_ document: PdfDocument, _ pageIndex: Int) -> [FieldProposal] {
        precondition(pageIndex >= 0 && pageIndex < document.pages.count, "pageIndex")
        let form = PdfForm.read(document)
        var names = Set(form.fields.map { Array($0.name.utf16) })
        return detectPage(document, document.pages[pageIndex], form, &names)
    }

    /// As `detect(_:)`; a page that is a scan, with or without a text layer from OCR, is also drawn through `renderer` and
    /// read from its pixels (`ScanFieldDetector`).
    public static func detect(_ document: PdfDocument, _ renderer: PageRenderer) throws -> [FieldProposal] {
        let form = PdfForm.read(document)
        var names = Set(form.fields.map { Array($0.name.utf16) })
        let kinds = OcrTriage.classifyAll(document)
        var found: [FieldProposal] = []
        for page in document.pages {
            try Task.checkCancellation()
            found.append(contentsOf: detectPage(document, page, form, &names, renderer, kinds[page.index]))
        }
        return found
    }

    /// As above for one page.
    public static func detect(_ document: PdfDocument, _ pageIndex: Int, _ renderer: PageRenderer) -> [FieldProposal] {
        precondition(pageIndex >= 0 && pageIndex < document.pages.count, "pageIndex")
        let form = PdfForm.read(document)
        let page = document.pages[pageIndex]
        var names = Set(form.fields.map { Array($0.name.utf16) })
        return detectPage(document, page, form, &names, renderer, OcrTriage.classify(document, page))
    }

    private static func detectPage(_ document: PdfDocument, _ page: PdfPage, _ form: PdfForm, _ names: inout Set<[UInt16]>,
                                   _ renderer: PageRenderer, _ kind: OcrPageKind) -> [FieldProposal] {
        var found = detectPage(document, page, form, &names)
        if kind == .picture || kind == .ownLayer || kind == .foreignLayer { found.append(contentsOf: ScanFieldDetector.detect(document, page, form, &names, renderer, found)) }
        return found
    }

    private static func detectPage(_ document: PdfDocument, _ page: PdfPage, _ form: PdfForm, _ names: inout Set<[UInt16]>) -> [FieldProposal] {
        let scan = PageScan()
        ContentInterpreter(document).run(page, scan)
        let runs = scan.runs()
        let crop = page.cropBox
        let taken = form.fields.flatMap { $0.widgets }.filter { $0.pageIndex == page.index }.map { $0.rect }

        var candidates: [Candidate] = []
        boxes(scan, crop, &candidates)
        for (y, x1, x2) in stableSorted(scan.horizontal, { $0.y > $1.y }) {
            if x2 - x1 < minBlank || x2 - x1 > 0.95 * crop.width || closed(scan, y, x1, x2) { continue }
            let label = labelFor(runs, PdfRect(x1, y, x2, y + 14), toRight: false)
            if label == nil && x2 - x1 > 300 { continue }
            let height = label.map { min(max($0.box.height * 1.3, 14), 22) } ?? 16
            candidates.append(Candidate(PdfRect(x1, y + 1, x2, y + 1 + height), .text, false))
        }
        underscores(runs, &candidates)
        colons(runs, crop, &candidates)

        var accepted: [FieldProposal] = []
        var rects = taken
        for c in candidates {
            if rects.contains(where: { covers($0, c.rect) }) || occupied(scan, c.rect, c.kind) { continue }
            rects.append(c.rect)
            let label = c.label ?? labelFor(runs, c.rect, toRight: c.labelRight)?.text
            var proposal = FieldProposal(page.index, c.rect, c.kind, unique(&names, label, c.kind), clean(label))
            proposal.cells = c.cells
            proposal.multiline = c.multiline
            accepted.append(proposal)
        }
        return stableSorted(accepted) { a, b in a.rect.top != b.rect.top ? a.rect.top > b.rect.top : a.rect.left < b.rect.left }
    }

    private static func boxes(_ scan: PageScan, _ crop: PdfRect, _ candidates: inout [Candidate]) {
        let boxes = scan.boxes.filter { $0.width <= 0.95 * crop.width && $0.height <= 0.6 * crop.height }
        let combs = combRows(boxes)
        for comb in combs { candidates.append(Candidate(comb.rect, .text, false, cells: comb.cells)) }
        let used = Set(combs.flatMap { $0.members }.map { RectKey($0) })
        for box in boxes where !used.contains(RectKey(box)) {
            let widest = max(box.width, box.height)
            if widest <= 30 && abs(box.width - box.height) <= 0.3 * widest {
                candidates.append(Candidate(box, .checkBox, true))
            } else if box.width >= 24 && box.height >= 9 {
                candidates.append(Candidate(box, .text, false, cells: innerCells(scan, box), multiline: box.height >= 36))
            }
        }
        for circle in scan.circles { candidates.append(Candidate(circle, .radio, true)) }
    }

    // Three or more boxes of one size side by side are the cells of one comb field.
    private static func combRows(_ boxes: [PdfRect]) -> [(rect: PdfRect, cells: Int, members: [PdfRect])] {
        var rows: [(rect: PdfRect, cells: Int, members: [PdfRect])] = []
        let small = stableSorted(boxes.filter { $0.width >= 6 && $0.width <= 30 && $0.height >= 8 && $0.height <= 40 }) { a, b in
            a.bottom != b.bottom ? a.bottom < b.bottom : a.left < b.left
        }
        var run: [PdfRect] = []
        func end() {
            if run.count >= 3, let first = run.first, let last = run.last {
                rows.append((PdfRect(first.left, first.bottom, last.right, first.top), run.count, run))
            }
            run.removeAll()
        }
        for b in small {
            if let last = run.last {
                let gap = b.left - last.right
                let next = abs(b.bottom - last.bottom) <= 0.8 && abs(b.top - last.top) <= 0.8 && abs(b.width - last.width) <= 1
                    && gap >= -1.5 && gap <= 3
                if !next { end() }
            }
            run.append(b)
        }
        end()
        return rows
    }

    // Vertical rules standing evenly inside a wide box divide it into cells.
    private static func innerCells(_ scan: PageScan, _ box: PdfRect) -> Int {
        let inside = scan.vertical.filter { $0.x > box.left + 2 && $0.x < box.right - 2 && $0.y1 <= box.bottom + 2 && $0.y2 >= box.top - 2 }
            .map { $0.x }.sorted()
        if inside.count < 2 { return 0 }
        let cell = box.width / Double(inside.count + 1)
        for (i, x) in inside.enumerated() where abs(x - (box.left + cell * Double(i + 1))) > 0.15 * cell { return 0 }
        return inside.count + 1
    }

    // A ruled line closed in on both sides is the bottom of a cell, not an underline.
    private static func closed(_ scan: PageScan, _ y: Double, _ x1: Double, _ x2: Double) -> Bool {
        scan.vertical.contains { abs($0.x - x1) <= 2 && $0.y1 <= y + 2 && $0.y2 >= y + 8 }
            && scan.vertical.contains { abs($0.x - x2) <= 2 && $0.y1 <= y + 2 && $0.y2 >= y + 8 }
    }

    private static func underscores(_ runs: [ScanRun], _ candidates: inout [Candidate]) {
        for run in runs {
            var i = 0
            while i < run.glyphs.count {
                let mark = run.glyphs[i].text.utf16.first ?? 0
                var j = i
                while j < run.glyphs.count && run.glyphs[j].text == run.glyphs[i].text { j += 1 }
                if (mark == 0x5F && j - i >= 4) || (mark == 0x2E && j - i >= 8) {
                    let first = run.glyphs[i].box
                    let rect = PdfRect(first.left, first.bottom, run.glyphs[j - 1].box.right, first.bottom + max(14, first.height))
                    let before = run.glyphs.prefix(i).map { $0.text }.joined()
                    candidates.append(Candidate(rect, .text, false, label: FormFunctions.trim(before).isEmpty ? nil : before))
                }
                i = j
            }
        }
    }

    private static func colons(_ runs: [ScanRun], _ crop: PdfRect, _ candidates: inout [Candidate]) {
        for run in runs {
            let text = FormFunctions.trim(run.text)
            let units = Array(text.utf16)
            if units.last != 0x3A || units.count > 32 || units.filter({ $0 == 0x20 }).count > 3 { continue }
            let next = stableSorted(runs.filter { $0.box.left > run.box.right && vertical($0.box, run.box) }) { $0.box.left < $1.box.left }.first
            let start = run.box.right + 4
            let end = next.map { $0.box.left - 4 } ?? min(crop.right - 24, start + 200)
            if end - start < minBlank { continue }
            let height = max(14, run.box.height + 2)
            candidates.append(Candidate(PdfRect(start, run.box.bottom - 1, end, run.box.bottom - 1 + height), .text, false, label: run.text))
        }
    }

    static func vertical(_ a: PdfRect, _ b: PdfRect) -> Bool {
        min(a.top, b.top) - max(a.bottom, b.bottom) >= 0.4 * min(a.height, b.height)
    }

    // The text a blank belongs to: on its own line before it (after it for a check box or radio button), else just above it.
    private static func labelFor(_ runs: [ScanRun], _ rect: PdfRect, toRight: Bool) -> ScanRun? {
        var beside: [(run: ScanRun, gap: Double)] = []
        for r in runs where vertical(r.box, rect) && !FormFunctions.trim(r.text).isEmpty && !r.text.contains("____") {
            let gap = toRight ? r.box.left - rect.right : rect.left - r.box.right
            if gap >= -2 && gap <= labelReach { beside.append((r, gap)) }
        }
        if let nearest = stableSorted(beside, { $0.gap < $1.gap }).first { return nearest.run }
        let above = runs.filter { r in
            r.box.bottom >= rect.top - 2 && r.box.bottom - rect.top <= 18 && r.box.left >= rect.left - 10 && r.box.left <= rect.right
                && !FormFunctions.trim(r.text).isEmpty
        }
        return stableSorted(above) { $0.box.bottom < $1.box.bottom }.first
    }

    static func covers(_ existing: PdfRect, _ candidate: PdfRect) -> Bool {
        let common = existing.intersect(candidate)
        if common.isEmpty { return false }
        return common.width * common.height > overlap * min(existing.width * existing.height, candidate.width * candidate.height)
    }

    // Text printed in the blank means it is already filled, or that this is not a blank at all.
    private static func occupied(_ scan: PageScan, _ rect: PdfRect, _ kind: FieldKind) -> Bool {
        let inner = PdfRect(rect.left + 1, rect.bottom + 1, rect.right - 1, rect.top - 1)
        if inner.isEmpty { return false }
        return scan.glyphs.contains { g in
            let first = g.text.utf16.first ?? 0
            let cx = (g.box.left + g.box.right) / 2, cy = (g.box.bottom + g.box.top) / 2
            return !FormFunctions.trim(g.text).isEmpty && first != 0x5F && first != 0x2E
                && inner.left <= cx && cx <= inner.right && inner.bottom <= cy && cy <= inner.top
        }
    }

    static func clean(_ label: String?) -> String? {
        guard let label else { return nil }
        let swapped = String(decoding: label.utf16.map { $0 == 0x5F ? 0x20 : $0 }, as: UTF16.self)
        var units = Array(FormFunctions.trim(swapped).utf16)
        while let last = units.last, last == 0x3A || last == 0x2E || last == 0x20 { units.removeLast() }
        var start = 0
        while start < units.count, units[start] == 0x3A || units[start] == 0x2E || units[start] == 0x20 { start += 1 }
        let words = String(decoding: units[start...], as: UTF16.self).split(whereSeparator: { $0.unicodeScalars.allSatisfy { $0.properties.isWhitespace } })
        let text = words.joined(separator: " ")
        if text.isEmpty { return nil }
        let utf16 = Array(text.utf16)
        return utf16.count > 60 ? String(decoding: utf16.prefix(60), as: UTF16.self) : text
    }

    static func unique(_ names: inout Set<[UInt16]>, _ label: String?, _ kind: FieldKind) -> String {
        var base: String
        if let cleaned = clean(label) {
            base = String(decoding: cleaned.utf16.map { $0 == 0x2E ? 0x20 : $0 }, as: UTF16.self)
        } else {
            switch kind {
            case .checkBox: base = "Check"
            case .radio: base = "Radio"
            default: base = "Text"
            }
        }
        var name = base
        var n = 2
        while !names.insert(Array(name.utf16)).inserted {
            name = base + String(n)
            n += 1
        }
        return name
    }
}
