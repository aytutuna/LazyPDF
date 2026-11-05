import Foundation

// Twin of windows/LazyPDF.Core/Export/ExportLines.cs: a line of the page text with its box in display points and its
// characters grouped into styled runs.

final class ExLine: Hashable {
    let box: DisplayRect
    let runs: [ExportRun]
    let size: Double
    let allBold: Bool
    let before: TextBreak
    let block: Int

    /// Every character is marked /Artifact (running heads, page numbers).
    var isArtifact: Bool

    /// Index of the ruled table that took the line, or -1.
    var table = -1

    init(box: DisplayRect, runs: [ExportRun], size: Double, allBold: Bool, before: TextBreak, block: Int, isArtifact: Bool = false) {
        self.box = box
        self.runs = runs
        self.size = size
        self.allBold = allBold
        self.before = before
        self.block = block
        self.isArtifact = isArtifact
    }

    static func == (a: ExLine, b: ExLine) -> Bool { a === b }

    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }

    var text: String { runs.map { $0.text }.joined() }

    var left: Double { box.x }
    var right: Double { box.x + box.width }
    var top: Double { box.y }
    var bottom: Double { box.y + box.height }
    var centerY: Double { box.y + box.height / 2 }

    static func from(_ page: TextPage, _ line: PageLine, _ geometry: PageGeometry) -> ExLine? {
        var runs: [ExportRun] = []
        var weights = SizeWeights()
        var letters = 0, bold = 0, total = 0, artifacts = 0
        var isBold = false, isItalic = false
        var size = 0.0
        var i = line.range.start
        while i < line.range.end && i < page.chars.count {
            defer { i += 1 }
            if i < 0 { continue }
            let c = page.chars[i]
            if c.text.isEmpty { continue }
            let space = c.isSpace
            if !space {
                total += 1
                if c.isArtifact { artifacts += 1 }
            }
            if !space, let font = c.font {
                (isBold, isItalic, size) = (font.isBold, font.isItalic, (c.size * 2).rounded(.toNearestOrEven) / 2)
                letters += 1
                if isBold { bold += 1 }
                weights.add(size, 1)
            }
            let text = space ? " " : c.text
            // Spaces stay in the run they follow, so one bold phrase is not cut at every space.
            if let last = runs.last, space || (last.bold == isBold && last.italic == isItalic && abs(last.size - size) <= 0.6) {
                runs[runs.count - 1].text += text
            } else if !space || !runs.isEmpty {
                runs.append(ExportRun(text, isBold, isItalic, size))
            }
        }
        trim(&runs)
        guard let first = runs.first else { return nil }
        return ExLine(
            box: geometry.toDisplay(line.bounds),
            runs: runs,
            size: weights.heaviest ?? first.size,
            allBold: letters > 0 && bold == letters,
            before: line.before,
            block: line.block,
            isArtifact: total > 0 && artifacts == total)
    }

    private static func trim(_ runs: inout [ExportRun]) {
        while let last = runs.last {
            let end = ExportTrim.end(last.text)
            if end == last.text { break }
            if end.isEmpty { runs.removeLast() } else { runs[runs.count - 1].text = end }
        }
        while let first = runs.first {
            let start = ExportTrim.start(first.text)
            if start == first.text { break }
            if start.isEmpty { runs.removeFirst() } else { runs[0].text = start }
        }
    }
}
