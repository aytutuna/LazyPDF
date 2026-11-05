import Foundation

// Twin of windows/LazyPDF.Core/Compare/Comparison.Parts.cs: the parts of a page pair that are not its words: fonts, sizes
// and colours, pictures and annotations.

extension Comparison {
    private static let sizeTolerance = 0.1
    private static let placeTolerance = 1.0
    private static let minOverlap = 0.6

    /// Words that are equal on both sides but are set in another font, size or colour; neighbours with the same difference
    /// are one change.
    func compareFormats(_ work: PairWork, _ oldData: PageData, _ newData: PageData, _ hunks: [SequenceDiff.Hunk]) {
        var runDetail: String?
        var runOld = 0, runNew = 0, runCount = 0
        func flush() {
            if runCount > 0 {
                work.others.append(CompareChange(.changed, .format, work.pair.oldIndex, work.pair.newIndex,
                                                 oldData.words(runOld, runCount), newData.words(runNew, runCount),
                                                 oldData.quads(runOld, runCount), newData.quads(runNew, runCount), runDetail))
            }
            runCount = 0
        }
        func equal(_ i: Int, _ j: Int) {
            guard let detail = Self.formatDifference(oldData.formatChar(i), newData.formatChar(j)) else {
                flush()
                return
            }
            let same = runDetail.map { Ordinal.equal(detail, $0) } ?? false
            if !same || runOld + runCount != i || runNew + runCount != j { flush() }
            if runCount == 0 { (runDetail, runOld, runNew) = (detail, i, j) }
            runCount += 1
        }

        var a = 0, b = 0
        for hunk in hunks {
            while a < hunk.oldStart {
                equal(a, b)
                a += 1
                b += 1
            }
            (a, b) = (hunk.oldStart + hunk.oldCount, hunk.newStart + hunk.newCount)
        }
        while a < oldData.ids.count {
            equal(a, b)
            a += 1
            b += 1
        }
        flush()
    }

    private static func formatDifference(_ a: TextChar, _ b: TextChar) -> String? {
        var parts: [String] = []
        let fontA = a.font?.name ?? "", fontB = b.font?.name ?? ""
        if !Ordinal.equalIgnoringCase(fontA, fontB) { parts.append(CompareText.fontChange(fontA, fontB)) }
        if abs(a.size - b.size) > sizeTolerance { parts.append(CompareText.sizeChange(a.size, b.size)) }
        if a.color != b.color { parts.append(CompareText.colorChange(a.color, b.color)) }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }

    func compareImages(_ work: PairWork, _ oldPage: PdfPage, _ newPage: PdfPage) throws {
        let oldImages = try oldReader.images(oldPage)
        let newImages = try newReader.images(newPage)
        if oldImages.isEmpty && newImages.isEmpty { return }
        let pair = work.pair
        var usedOld = [Bool](repeating: false, count: oldImages.count)
        var usedNew = [Bool](repeating: false, count: newImages.count)

        func report(_ kind: ChangeKind, _ old: PageImage?, _ updated: PageImage?, _ detail: String?) {
            work.others.append(CompareChange(kind, .image, pair.oldIndex, pair.newIndex, "", "",
                                             old.map { [Self.boxQuad($0.bounds)] } ?? [], updated.map { [Self.boxQuad($0.bounds)] } ?? [], detail))
        }

        for j in 0..<newImages.count {
            let i = Self.find(oldImages, usedOld, newImages[j], sameHash: true, samePlace: true)
            if i < 0 { continue }
            usedOld[i] = true
            usedNew[j] = true
        }
        for j in 0..<newImages.count {
            if usedNew[j] { continue }
            let i = Self.find(oldImages, usedOld, newImages[j], sameHash: true, samePlace: false)
            if i < 0 { continue }
            usedOld[i] = true
            usedNew[j] = true
            report(.changed, oldImages[i], newImages[j], CompareText.imageMoved)
        }
        for j in 0..<newImages.count {
            if usedNew[j] { continue }
            let i = Self.find(oldImages, usedOld, newImages[j], sameHash: false, samePlace: true)
            if i < 0 { continue }
            usedOld[i] = true
            usedNew[j] = true
            report(.changed, oldImages[i], newImages[j], CompareText.imageReplaced)
        }
        for j in 0..<newImages.count where !usedNew[j] { report(.added, nil, newImages[j], nil) }
        for i in 0..<oldImages.count where !usedOld[i] { report(.removed, oldImages[i], nil, nil) }
    }

    /// The unused old picture with the same hash (or, without `sameHash`, a different one) at the same place (or the nearest
    /// one when places differ).
    private static func find(_ candidates: [PageImage], _ used: [Bool], _ image: PageImage, sameHash: Bool, samePlace: Bool) -> Int {
        var best = -1
        var bestDistance = Double.greatestFiniteMagnitude
        for i in 0..<candidates.count {
            if used[i] || Ordinal.equal(candidates[i].hash, image.hash) != sameHash { continue }
            let a = candidates[i].bounds
            let b = image.bounds
            let near = abs(a.left - b.left) <= placeTolerance && abs(a.right - b.right) <= placeTolerance
                && abs(a.bottom - b.bottom) <= placeTolerance && abs(a.top - b.top) <= placeTolerance
            if samePlace && sameHash && !near { continue }
            if samePlace && !sameHash && overlap(a, b) < minOverlap { continue }
            let distance = abs(a.left + a.right - b.left - b.right) + abs(a.bottom + a.top - b.bottom - b.top)
            if distance < bestDistance { (best, bestDistance) = (i, distance) }
        }
        return best
    }

    private static func overlap(_ a: PdfRect, _ b: PdfRect) -> Double {
        let both = a.intersect(b)
        let area = both.isEmpty ? 0 : both.width * both.height
        let union = a.width * a.height + b.width * b.height - area
        return union <= 0 ? 0 : area / union
    }

    func compareAnnotations(_ work: PairWork, _ oldPage: PdfPage, _ newPage: PdfPage) {
        let oldNotes = Self.notes(before, oldPage)
        let newNotes = Self.notes(after, newPage)
        if oldNotes.isEmpty && newNotes.isEmpty { return }
        let pair = work.pair
        var usedOld = [Bool](repeating: false, count: oldNotes.count)
        var matched: [(old: Int, new: Int)] = []
        for j in 0..<newNotes.count {
            guard let name = newNotes[j].name, !name.isEmpty else { continue }
            let found = oldNotes.indices.first { k in !usedOld[k] && (oldNotes[k].name.map { Ordinal.equal($0, name) } ?? false) }
            guard let i = found else { continue }
            usedOld[i] = true
            matched.append((i, j))
        }
        var done = Set(matched.map { $0.new })
        for j in 0..<newNotes.count {
            if done.contains(j) { continue }
            var best = -1
            var bestOverlap = Self.minOverlap - 1e-9
            for i in 0..<oldNotes.count {
                if usedOld[i] || !Ordinal.equal(oldNotes[i].subtype, newNotes[j].subtype) { continue }
                let value = Self.overlap(oldNotes[i].rect, newNotes[j].rect)
                if value > bestOverlap { (best, bestOverlap) = (i, value) }
            }
            if best < 0 { continue }
            usedOld[best] = true
            matched.append((best, j))
            done.insert(j)
        }

        for (i, j) in matched.sorted(by: { $0.new < $1.new }) {
            let a = oldNotes[i]
            let b = newNotes[j]
            var parts: [String] = []
            if !Ordinal.equal(a.contents ?? "", b.contents ?? "") { parts.append(CompareText.annotationText) }
            if !Self.sameRect(a.rect, b.rect) { parts.append(CompareText.annotationPosition) }
            if !Self.sameColor(a.color, b.color) { parts.append(CompareText.annotationColor) }
            if parts.isEmpty { continue }
            work.others.append(CompareChange(.changed, .annotation, pair.oldIndex, pair.newIndex, a.contents ?? "", b.contents ?? "",
                                             Self.noteQuads(a), Self.noteQuads(b), "\(b.subtype): \(parts.joined(separator: ", "))"))
        }
        for j in 0..<newNotes.count where !done.contains(j) {
            let b = newNotes[j]
            work.others.append(CompareChange(.added, .annotation, pair.oldIndex, pair.newIndex, "", b.contents ?? "", [], Self.noteQuads(b), b.subtype))
        }
        for i in 0..<oldNotes.count where !usedOld[i] {
            let a = oldNotes[i]
            work.others.append(CompareChange(.removed, .annotation, pair.oldIndex, pair.newIndex, a.contents ?? "", "", Self.noteQuads(a), [], a.subtype))
        }
    }

    /// Popups belong to their note and widgets are the form's; both are compared elsewhere or not at all.
    private static func notes(_ document: PdfDocument, _ page: PdfPage) -> [PdfAnnotation] {
        PdfAnnotations.read(document, page).filter { $0.type != .popup && $0.type != .widget }
    }

    private static func noteQuads(_ note: PdfAnnotation) -> [TextQuad] { [boxQuad(note.rect)] }

    private static func sameRect(_ a: PdfRect, _ b: PdfRect) -> Bool {
        abs(a.left - b.left) <= placeTolerance && abs(a.right - b.right) <= placeTolerance
            && abs(a.bottom - b.bottom) <= placeTolerance && abs(a.top - b.top) <= placeTolerance
    }

    private static func sameColor(_ a: [Double]?, _ b: [Double]?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) < 0.01 }
    }
}
