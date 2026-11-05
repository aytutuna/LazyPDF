import Foundation

// Twin of windows/LazyPDF.Core/Accessibility/TagLayout.cs: reads the layout `TextPage` found and decides the elements of
// one page: headings by size and weight, lists by their markers, tables where every row has the same cells, paragraphs,
// figures for images. Header, footer and page number lines are left out, which makes them artifacts.

final class TagLayout {
    private static let maxHeadingLines = 4
    private static let maxBoldHeadingLines = 2

    private let document: PdfDocument
    private let page: PdfPage
    private let text: TextPage
    private let scan: TagScan
    private let stats: TagStats
    private let geometry: PageGeometry
    private let result: TagPage

    private init(_ document: PdfDocument, _ page: PdfPage, _ text: TextPage, _ scan: TagScan, _ stats: TagStats) {
        self.document = document
        self.page = page
        self.text = text
        self.scan = scan
        self.stats = stats
        geometry = PageGeometry(page)
        result = TagPage(page.index)
    }

    static func build(_ document: PdfDocument, _ page: PdfPage, _ text: TextPage, _ scan: TagScan, _ stats: TagStats) -> TagPage {
        let layout = TagLayout(document, page, text, scan, stats)
        for block in text.blocks {
            let lines = layout.linesOf(block)
            if lines.isEmpty { continue }
            if block.isTable, let table = layout.tryTable(lines) {
                layout.result.nodes.append(table)
            } else {
                layout.addText(lines)
            }
        }
        layout.addFigures()
        layout.addAnnotations()
        return layout.result
    }

    private func linesOf(_ block: TextBlock) -> [TagLine] {
        var lines: [TagLine] = []
        for i in stride(from: block.lines.start, to: block.lines.end, by: 1) {
            let line = TagLine(text, text.lines[i], geometry)
            if !isRunning(line) && !isArtifact(line) { lines.append(line) }
        }
        return lines
    }

    private func isArtifact(_ line: TagLine) -> Bool {
        var marked = 0, count = 0
        for i in stride(from: line.range.start, to: line.range.end, by: 1) {
            count += 1
            if text.chars[i].isArtifact { marked += 1 }
        }
        return count > 0 && marked * 2 >= count
    }

    private func isRunning(_ line: TagLine) -> Bool {
        guard let band = TagText.band(line, geometry.height) else { return false }
        if TagText.isPageNumber(line.text) { return true }
        guard let signature = TagText.signature(line.text) else { return false }
        return stats.repeated.contains(band + "|" + signature)
    }

    private func tryTable(_ lines: [TagLine]) -> TagNode? {
        var rows: [[TagLine]] = []
        for line in lines {
            if rows.isEmpty || line.before != .tab {
                rows.append([line])
            } else {
                rows[rows.count - 1].append(line)
            }
        }
        guard rows.count >= 2, rows[0].count >= 2, !rows.contains(where: { $0.count != rows[0].count }) else { return nil }
        if rows.allSatisfy({ $0.first.map { TagText.isLoneMarker($0.text) } ?? false }) { return nil }

        let table = TagNode("Table")
        for (r, row) in rows.enumerated() {
            let tr = TagNode("TR")
            for cell in row {
                let node = TagNode(r == 0 ? "TH" : "TD")
                node.area = cell.rect
                node.operations.append(contentsOf: operationsOf(cell.range))
                tr.children.append(node)
            }
            tr.area = Self.union(row.map { $0.rect })
            table.children.append(tr)
        }
        table.area = Self.union(rows.flatMap { $0 }.map { $0.rect })
        return table
    }

    private func addText(_ source: [TagLine]) {
        let lines = Self.mergeMarkers(source)
        let vertical = lines.contains { $0.isVertical }
        var i = 0
        while i < lines.count {
            if !vertical, let heading = tryHeading(lines, i) {
                result.nodes.append(heading.node)
                i = heading.next
                continue
            }
            if !vertical, let list = tryList(lines, i) {
                result.nodes.append(list.node)
                i = list.next
                continue
            }
            var end = i + 1
            while end < lines.count && (vertical || continuesParagraph(lines, end)) {
                end += 1
            }
            result.nodes.append(paragraph(lines, i, end))
            i = end
        }
    }

    private static func mergeMarkers(_ lines: [TagLine]) -> [TagLine] {
        var merged: [TagLine] = []
        var i = 0
        while i < lines.count {
            if i + 1 < lines.count && TagText.isLoneMarker(lines[i].text) && lines[i + 1].before == .tab {
                merged.append(TagLine.join(lines[i], lines[i + 1]))
                i += 1
            } else {
                merged.append(lines[i])
            }
            i += 1
        }
        return merged
    }

    private func continuesParagraph(_ lines: [TagLine], _ at: Int) -> Bool {
        let line = lines[at]
        return Self.gap(lines[at - 1], line) <= 0.5 * max(lines[at - 1].size, line.size)
            && lookOf(line) == nil && TagText.markerOf(line.text) == nil
    }

    private static func gap(_ above: TagLine, _ below: TagLine) -> Double {
        below.rect.y - (above.rect.y + above.rect.height)
    }

    private func lookOf(_ line: TagLine) -> HeadingLook? {
        let units = line.text.utf16
        if line.size <= 0 || units.count > 150 || units.filter({ DotNetText.isLetter($0) }).count < 2 { return nil }
        if line.size >= stats.bodySize * 1.15 { return HeadingLook(size: line.size, bold: line.bold) }
        if line.bold && !stats.bodyBold && line.size >= stats.bodySize - 0.25 && units.count <= 100 {
            return HeadingLook(size: line.size, bold: true)
        }
        return nil
    }

    private func tryHeading(_ lines: [TagLine], _ at: Int) -> (node: TagNode, next: Int)? {
        guard let look = lookOf(lines[at]) else { return nil }
        var end = at + 1
        while end < lines.count && lookOf(lines[end]) == look && Self.gap(lines[end - 1], lines[end]) <= 0.9 * look.size { end += 1 }
        let bodySized = look.size < stats.bodySize * 1.15
        if end - at > (bodySized ? Self.maxBoldHeadingLines : Self.maxHeadingLines) { return nil }
        if bodySized, let last = DotNetText.trimEnd(lines[end - 1].text).utf16.last, last == 0x2E || last == 0x2C || last == 0x3B {
            return nil
        }

        let node = TagNode("H")
        node.heading = look
        fill(node, lines, at, end)
        return (node, end)
    }

    private func tryList(_ lines: [TagLine], _ at: Int) -> (node: TagNode, next: Int)? {
        guard let first = TagText.markerOf(lines[at].text), lookOf(lines[at]) == nil else { return nil }
        var items: [(start: Int, end: Int, marker: ListMarker)] = []
        var i = at
        while i < lines.count, let marker = TagText.markerOf(lines[i].text), marker.numbered == first.numbered, lookOf(lines[i]) == nil {
            var end = i + 1
            while end < lines.count && TagText.markerOf(lines[end].text) == nil && lookOf(lines[end]) == nil
                && Self.gap(lines[end - 1], lines[end]) <= 0.5 * lines[end].size && lines[end].rect.x >= lines[i].rect.x - 0.5 * lines[end].size {
                end += 1
            }
            items.append((i, end, marker))
            i = end
        }
        if items.count < 2 { return nil }

        let list = TagNode("L")
        for (start, end, marker) in items {
            let item = TagNode("LI")
            let label = splitMarker(lines[start], marker.length)
            let labelOperations = operationsOf(label.label)
            let body = TagNode("LBody")
            body.operations.append(contentsOf: operationsOf(TextRange(label.bodyStart, lines[end - 1].range.end)))
            if !labelOperations.isEmpty && !labelOperations.contains(where: { body.operations.contains($0) }) {
                let lbl = TagNode("Lbl")
                lbl.area = lines[start].rect
                lbl.operations.append(contentsOf: labelOperations)
                item.children.append(lbl)
            } else {
                body.operations.insert(contentsOf: labelOperations.filter { !body.operations.contains($0) }, at: 0)
            }
            body.area = Self.union((start..<end).map { lines[$0].rect })
            item.children.append(body)
            item.area = body.area
            list.children.append(item)
        }
        list.area = Self.union(list.children.map { $0.area })
        return (list, i)
    }

    private func splitMarker(_ line: TagLine, _ length: Int) -> (label: TextRange, bodyStart: Int) {
        var i = line.range.start
        while i < line.range.end && text.chars[i].isSpace { i += 1 }
        let start = i
        var taken = 0
        while i < line.range.end && taken < length {
            taken += max(text.chars[i].text.utf16.count, 1)
            i += 1
        }
        var body = i
        while body < line.range.end && text.chars[body].isSpace { body += 1 }
        return (TextRange(start, i), body)
    }

    private func paragraph(_ lines: [TagLine], _ start: Int, _ end: Int) -> TagNode {
        let node = TagNode("P")
        fill(node, lines, start, end)
        return node
    }

    private func fill(_ node: TagNode, _ lines: [TagLine], _ start: Int, _ end: Int) {
        node.operations.append(contentsOf: operationsOf(TextRange(lines[start].range.start, lines[end - 1].range.end)))
        node.area = Self.union((start..<end).map { lines[$0].rect })
    }

    private func operationsOf(_ range: TextRange) -> [Int] {
        var found: [Int] = []
        var seen = Set<Int>()
        for i in stride(from: range.start, to: min(range.end, text.chars.count), by: 1) {
            let c = text.chars[i]
            if c.isArtifact || c.operatorIndex < 0 { continue }
            var operation = c.operatorIndex
            if let form = c.form {
                let key = ObjectIdentifier(form)
                guard let drawn = scan.formOperations[key], !scan.repeated.contains(key) else { continue }
                operation = drawn
            }
            if seen.insert(operation).inserted { found.append(operation) }
        }
        return found
    }

    private func addFigures() {
        var done = Set<Int>()
        for image in scan.images {
            if image.operation < 0 || !done.insert(image.operation).inserted { continue }
            let area = geometry.toDisplay(image.bounds)
            if area.width < 2 || area.height < 2 { continue }
            let figure = TagNode("Figure")
            figure.area = area
            figure.operations.append(image.operation)
            let at = result.nodes.firstIndex { $0.area.y > area.y + 1 && Self.overlap($0.area, area) }
            result.nodes.insert(figure, at: at ?? result.nodes.count)
        }
    }

    private static func overlap(_ a: DisplayRect, _ b: DisplayRect) -> Bool {
        let shared = min(a.x + a.width, b.x + b.width) - max(a.x, b.x)
        return shared > 0.3 * min(a.width, b.width)
    }

    private func addAnnotations() {
        guard let annots = document.array(page.dictionary, "Annots") else { return }
        for item in annots.items.prefix(5000) {
            guard let reference = item as? PdfReference, let d = document.resolve(item) as? PdfDictionary else { continue }
            let subtype = document.name(d, "Subtype") ?? ""
            if subtype == "Popup" || subtype == "TrapNet" || subtype == "PrinterMark" || subtype == "Watermark"
                || ((document.integer(d, "F") ?? 0) & 2) != 0 { continue }
            result.annotations.append(TagAnnotation(reference: reference, subtype: subtype, text: subtype == "Link" ? textUnder(d) : ""))
        }
    }

    private func textUnder(_ annotation: PdfDictionary) -> String {
        guard let rect = document.rect(annotation, "Rect") else { return "" }
        var found = ""
        var length = 0
        for c in text.chars {
            let center = c.quad.bounds
            let x = (center.left + center.right) / 2, y = (center.bottom + center.top) / 2
            if x >= rect.left && x <= rect.right && y >= rect.bottom && y <= rect.top {
                found += c.text
                length += c.text.utf16.count
            }
            if length > 300 { break }
        }
        return DotNetText.words(found)
    }

    // Every list handed in has at least one rectangle.
    private static func union(_ rects: [DisplayRect]) -> DisplayRect {
        rects.dropFirst().reduce(rects.first ?? DisplayRect(0, 0, 0, 0)) { a, b in
            let x = min(a.x, b.x), y = min(a.y, b.y)
            return DisplayRect(x, y, max(a.x + a.width, b.x + b.width) - x, max(a.y + a.height, b.y + b.height) - y)
        }
    }
}
