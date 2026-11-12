import Foundation

// Twin of windows/LazyPDF.Core/Pages/PageOperations.Impose.cs: n-up and booklet sheets built from the pages of a
// document, each page placed as a form XObject.
//
// An ArgumentException of the C# is `PdfReadException.damaged` here when the user's input can cause it (a size, a gap,
// no pages) and a precondition for a page count per sheet the caller's code picks.

public enum ImposeMode {
    /// Several pages on each sheet, in reading order: across, then down.
    case nUp

    /// Saddle-stitch: two pages on each side of a landscape sheet, in the order that folds into a booklet.
    case booklet
}

public struct ImposeOptions {
    public var mode: ImposeMode
    /// Paper size in points, as the sheet is held. A booklet always uses the landscape orientation of it.
    public var sheetWidth: Double
    public var sheetHeight: Double
    /// 2, 4, 6, 9 or 16 for `nUp`; ignored for a booklet.
    public var perSheet: Int
    /// Space in points between pages and from the pages to the sheet edge.
    public var gap: Double
    public var border: Bool

    public init(mode: ImposeMode, sheetWidth: Double, sheetHeight: Double, perSheet: Int = 2, gap: Double = 0, border: Bool = false) {
        self.mode = mode
        self.sheetWidth = sheetWidth
        self.sheetHeight = sheetHeight
        self.perSheet = perSheet
        self.gap = gap
        self.border = border
    }
}

public struct ImposeResult {
    /// The sheets, a new document that is not saved yet.
    public let document: PdfDocument
    public let sheets: Int
    /// Annotations whose appearance was drawn into the page they sat on.
    public let annotationsFlattened: Int
    /// Annotations left out: links, and those with no appearance, hidden or not shown.
    public let annotationsDropped: Int
}

extension PageOperations {
    private static let grids: [Int: (columns: Int, rows: Int)] = [2: (2, 1), 4: (2, 2), 6: (3, 2), 9: (3, 3), 16: (4, 4)]

    /// A new document of sheets with the pages at these indexes (in this order) placed on them as form XObjects, each
    /// fitted to its cell and centred, with its rotation and crop box kept. Annotations that have an appearance are
    /// drawn into their page first and all others are dropped; the result counts both. A booklet pads with blank cells
    /// to a multiple of 4 pages. The source is not changed; bookmarks, labels, tags and other document data are not
    /// carried over.
    public static func impose(_ source: PdfDocument, _ pages: [Int], _ options: ImposeOptions) throws -> ImposeResult {
        if pages.isEmpty { throw PdfReadException.damaged("There are no pages to place.") }
        if !(options.sheetWidth > 0 && options.sheetWidth <= maxPageSize && options.sheetHeight > 0 && options.sheetHeight <= maxPageSize) {
            throw PdfReadException.damaged("The size is out of range.")
        }
        let booklet = options.mode == .booklet
        precondition(booklet || grids[options.perSheet] != nil, "A sheet holds 2, 4, 6, 9 or 16 pages.")
        if !(options.gap >= 0) { throw PdfReadException.damaged("The gap is negative.") }
        let (columns, rows) = booklet ? (2, 1) : grids[options.perSheet]!
        let width = booklet ? max(options.sheetWidth, options.sheetHeight) : options.sheetWidth
        let height = booklet ? min(options.sheetWidth, options.sheetHeight) : options.sheetHeight
        let gap = options.gap
        let cellWidth = (width - gap * Double(columns + 1)) / Double(columns)
        let cellHeight = (height - gap * Double(rows + 1)) / Double(rows)
        if !(cellWidth > 0 && cellHeight > 0) { throw PdfReadException.damaged("The gap leaves no room for the pages.") }

        let target = try PageAssembly.blank(source.version)
        let importer = PageImporter(source, target)
        let copies = try importer.importPages(pages)
        if let info = source.trailer["Info"], source.info != nil { target.trailer["Info"] = try importer.copyValue(info) }
        try PageTree.set(target, copies)

        var flattened = 0, dropped = 0
        var forms: [PdfReference] = []
        let shown = Array(target.pages)
        for page in shown {
            try Task.checkCancellation()
            flattened += try PdfAnnotationFlattener.flatten(target, page, include: { $0.type != .link && $0.type != .popup })
            dropped += target.array(page.dictionary, "Annots")?.items.count ?? 0
            let form = PdfDictionary()
            form["Type"] = PdfName("XObject")
            form["Subtype"] = PdfName("Form")
            form["FormType"] = PdfNumber(1)
            form["BBox"] = page.cropBox.toArray()
            form["Resources"] = page.resources ?? PdfDictionary()
            form["Filter"] = PdfName("FlateDecode")
            if let group = page.dictionary["Group"] { form["Group"] = group }
            forms.append(try target.add(PdfStream(form, data: PdfFilterEncoders.flate(page.contents()))))
        }

        // A booklet block of four pages a, b, c, d (first, second, second to last, last) prints d,a on the front and b,c on the back.
        var slots: [Int?] = Array(0..<pages.count)
        if booklet {
            while slots.count % 4 != 0 { slots.append(nil) }
            var folded: [Int?] = []
            let last = slots.count - 1
            for i in 0..<(slots.count / 4) { folded += [slots[last - 2 * i], slots[2 * i], slots[2 * i + 1], slots[last - 2 * i - 1]] }
            slots = folded
        }
        let perSheet = columns * rows
        var sheets: [PdfReference] = []
        var start = 0
        while start < slots.count {
            try Task.checkCancellation()
            let resources = PdfDictionary()
            let content = ContentWriter()
            var slot = 0
            while slot < perSheet && start + slot < slots.count {
                defer { slot += 1 }
                guard let index = slots[start + slot] else { continue }
                let crop = shown[index].cropBox
                let turn = shown[index].rotate
                let w = crop.width, h = crop.height, unit = shown[index].userUnit
                let sideways = turn % 180 != 0
                let shownWidth = (sideways ? h : w) * unit, shownHeight = (sideways ? w : h) * unit
                let fit = min(cellWidth / shownWidth, cellHeight / shownHeight)
                let placedWidth = shownWidth * fit, placedHeight = shownHeight * fit
                let column = slot % columns, row = slot / columns
                let x = gap + Double(column) * (cellWidth + gap) + (cellWidth - placedWidth) / 2
                let y = height - gap - Double(row + 1) * cellHeight - Double(row) * gap + (cellHeight - placedHeight) / 2
                // Turns the crop box upright with its lower-left corner at the origin.
                let upright: PdfMatrix
                switch turn {
                case 90: upright = PdfMatrix(0, -1, 1, 0, -crop.bottom, w + crop.left)
                case 180: upright = PdfMatrix(-1, 0, 0, -1, w + crop.left, h + crop.bottom)
                case 270: upright = PdfMatrix(0, 1, -1, 0, h + crop.bottom, -crop.left)
                default: upright = PdfMatrix(1, 0, 0, 1, -crop.left, -crop.bottom)
                }
                let name = ContentResources.add(target, resources, "XObject", forms[index], "Fm")
                content.save().concat(upright.multiply(.scale(fit * unit, fit * unit)).multiply(.translate(x, y)))
                content.op("Do", [PdfName(name)]).restore()
                if options.border { content.save().lineWidth(0.5).strokeGray(0).rect(x, y, placedWidth, placedHeight).stroke().restore() }
            }
            let sheet = PdfDictionary()
            sheet["Type"] = PdfName("Page")
            sheet["MediaBox"] = PdfRect(0, 0, width, height).toArray()
            sheet["CropBox"] = PdfRect(0, 0, width, height).toArray()
            sheet["Rotate"] = PdfNumber(0)
            sheet["Resources"] = resources
            let contentDictionary = PdfDictionary()
            contentDictionary["Filter"] = PdfName("FlateDecode")
            sheet["Contents"] = try target.add(PdfStream(contentDictionary, data: PdfFilterEncoders.flate(content.toArray())))
            sheets.append(try target.add(sheet))
            start += perSheet
        }
        try PageTree.set(target, sheets)
        for copy in copies { target.delete(copy.number) }
        return ImposeResult(document: target, sheets: sheets.count, annotationsFlattened: flattened, annotationsDropped: dropped)
    }
}
