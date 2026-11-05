import Foundation

// Twin of windows/LazyPDF.Core/Export/ExportLayout.cs: reads pages into the `ExportDocument` the writers share:
// paragraphs from the text layer's lines, headings by size, bold and italic runs, lists, tables (drawn grids and aligned
// columns), pictures in place, running heads and page numbers left out of the flow.
//
// The C# CancellationToken is the task's. A page index out of range is thrown as `ArgumentException`, where the C# throws
// ArgumentOutOfRangeException: a page range typed by a user can cause it.

public enum ExportLayout {
    private static let minPictureSide = 4.0

    // What the model holds, in bytes, as far as it can be told before it is built. A run keeps a record,
    // a line and a paragraph's copy besides its characters; a picture is listed three times and each
    // occurrence costs the writers markup and a relationship; a ruled cell is a string reference in a list.
    private static let maxModel = 1 << 30
    private static let runBytes = 320
    private static let pictureBytes = 1024
    private static let cellBytes = 16

    /// Analyses `pages` (0-based, in the order given; nil for all). Pictures need the `codec` only for JPEG 2000, JBIG2
    /// and masks on a JPEG. Throws `ArgumentException` when a page index is out of range, and `PdfReadException` when the
    /// pages hold more text than the export keeps in memory.
    public static func analyze(_ document: PdfDocument, _ pages: [Int]? = nil, _ codec: ImageCodec? = nil) throws -> ExportDocument {
        let interpreter = ContentInterpreter(document)
        interpreter.walkPatterns = false
        let images = ExportImages(document, codec)
        var work: [PageWork] = []
        var held = 0
        let count = document.pages.count
        for index in pages ?? Array(0..<count) {
            try Task.checkCancellation()
            if index < 0 || index >= count { throw ArgumentException("pages") }
            work.append(try collect(document, interpreter, images, index))
            held += work[work.count - 1].cost()
            if held > maxModel { throw PdfReadException(.unsupported, ExportText.tooLarge) }
        }

        let dropped = ExportStructure.runningHeads(work.map { (height: $0.height, rows: $0.blocks.filter { !$0.isTable }.flatMap { $0.rows }) })
        for page in work { page.assemble(dropped) }

        let paragraphs = work.flatMap { $0.flow }.compactMap { $0 as? ExPara }
        let body = ExportStructure.bodySize(paragraphs)
        ExportStructure.headings(paragraphs, body)
        let lists = ExportStructure.lists(work.flatMap { $0.flow })

        let result = work.map { w in
            ExportPage(w.index, w.width, w.height, w.flow.compactMap { b -> ExportBlock? in
                if let p = b as? ExPara { return paragraph(p, lists) }
                return b as? ExportBlock
            }, w.lines, w.pictures)
        }
        return ExportDocument(PdfText.read(document, document.info, "Title"), result, body, images.leftOut)
    }

    private static func paragraph(_ p: ExPara, _ lists: [ExPara: ExportListItem]) -> ExportParagraph {
        var runs = ExportFlow.merge(p.runs)
        if !runs.isEmpty { runs[runs.count - 1].text = ExportTrim.end(runs[runs.count - 1].text) }
        return ExportParagraph(p.box, runs, p.heading, lists[p])
    }

    private static func collect(_ document: PdfDocument, _ interpreter: ContentInterpreter, _ images: ExportImages, _ index: Int) throws -> PageWork {
        let page = document.pages[index]
        let geometry = PageGeometry(page)
        let text = TextPage.create(interpreter, page)
        let scan = ExportScan(geometry, true)
        interpreter.run(page, scan)

        var lines = text.lines.map { ExLine.from(text, $0, geometry) }
        ExportFlow.joinMarkers(&lines)
        let all = lines.compactMap { $0 }
        // A file that marks all its text as artifact is mistagged; its text is the page.
        if all.filter({ $0.isArtifact }).count * 10 > all.count * 9 { for l in all { l.isArtifact = false } }

        let ruled = ExportGrid.find(scan.rules, all)
        for t in 0..<ruled.count { for l in ruled[t].lines { l.table = t } }

        let work = PageWork(index, geometry.width, geometry.height, all.map { ExportTextLine($0.box, $0.runs) })
        var emitted = [Bool](repeating: false, count: ruled.count)
        for block in text.blocks {
            var group: [ExLine] = []
            func flush() {
                if !group.isEmpty { work.items.append(WorkBlock(block.isTable, ExportFlow.rows(group))) }
                group = []
            }
            var i = max(0, block.lines.start)
            while i < block.lines.end && i < lines.count {
                defer { i += 1 }
                guard let line = lines[i] else { continue }
                if line.table < 0 {
                    group.append(line)
                    continue
                }
                flush()
                if !emitted[line.table] { work.items.append(ruled[line.table].table) }
                emitted[line.table] = true
            }
            flush()
        }

        let scanned = !text.chars.isEmpty && text.chars.filter { $0.renderMode == 3 }.count * 5 >= text.chars.count * 4
        let m = geometry.matrix
        let shown = PdfMatrix(m.a, m.b, m.c, m.d, m.e, m.f)
        for info in scan.images {
            let box = geometry.toDisplay(info.bounds)
            if box.width < minPictureSide || box.height < minPictureSide { continue }
            // The page picture under the invisible text of an OCR'd scan would only repeat it.
            if scanned && box.width >= 0.9 * geometry.width && box.height >= 0.9 * geometry.height { continue }
            let turn = ExportImageTurn.of(info.matrix.multiply(shown))
            guard let image = try images.get(info, turn) else { continue }
            // A JPEG that could not be turned lies sideways after a quarter turn; at its own shape it is not stretched as well.
            work.pictures.append(ExportPicture(image.isJpeg && turn >= 5 ? fitted(box, image) : box, image))
        }
        return work
    }

    private static func fitted(_ box: DisplayRect, _ image: ExportImage) -> DisplayRect {
        let scale = min(box.width / Double(image.width), box.height / Double(image.height))
        let w = Double(image.width) * scale, h = Double(image.height) * scale
        return DisplayRect(box.x + (box.width - w) / 2, box.y + (box.height - h) / 2, w, h)
    }

    private final class WorkBlock {
        let isTable: Bool
        let rows: [ExRow]

        init(_ isTable: Bool, _ rows: [ExRow]) {
            self.isTable = isTable
            self.rows = rows
        }
    }

    private final class PageWork {
        let index: Int
        let width: Double
        let height: Double
        let lines: [ExportTextLine]

        /// Text blocks and ruled tables in reading order.
        var items: [AnyObject] = []
        var pictures: [ExportPicture] = []

        /// The page's blocks: `ExPara` until headings and lists are known, then export blocks.
        var flow: [AnyObject] = []

        init(_ index: Int, _ width: Double, _ height: Double, _ lines: [ExportTextLine]) {
            self.index = index
            self.width = width
            self.height = height
            self.lines = lines
        }

        var blocks: [WorkBlock] { items.compactMap { $0 as? WorkBlock } }

        func cost() -> Int {
            var sum = 0
            for l in lines { for r in l.runs { sum += ExportLayout.runBytes + 2 * r.text.utf16.count } }
            sum += ExportLayout.pictureBytes * pictures.count
            for case let t as ExportTable in items { sum += ExportLayout.cellBytes * t.rows.count * t.columns }
            return sum
        }

        func assemble(_ dropped: Set<ExRow>) {
            for item in items {
                if let table = item as? ExportTable {
                    flow.append(table)
                    continue
                }
                guard let block = item as? WorkBlock else { continue }
                let rows = block.rows.filter { !dropped.contains($0) && !$0.cells.allSatisfy { $0.isArtifact } }
                if block.isTable, let aligned = ExportFlow.aligned(rows) {
                    flow.append(aligned)
                } else {
                    flow += ExportFlow.paragraphs(rows)
                }
            }
            for picture in pictures { place(picture) }
        }

        // Before the first block that lies lower than the picture's middle and shares some of its width.
        private func place(_ picture: ExportPicture) {
            let middle = picture.bounds.y + picture.bounds.height / 2
            let at = flow.firstIndex { b in
                let box = Self.box(b)
                return box.y + box.height / 2 > middle && box.x < picture.bounds.x + picture.bounds.width && box.x + box.width > picture.bounds.x
            }
            flow.insert(picture, at: at ?? flow.count)
        }

        private static func box(_ block: AnyObject) -> DisplayRect {
            if let p = block as? ExPara { return p.box }
            return (block as? ExportBlock)?.bounds ?? DisplayRect(0, 0, 0, 0)
        }
    }
}
