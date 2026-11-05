import Foundation

// Twin of windows/LazyPDF.Core/Pages/PageOperations.cs: changes to the pages of an open document, made in memory; the
// caller commits them through `PdfEditSession.commit`. Pages are named by their index from 0 in the document as it is
// when the call starts. Anything that changes the set or order of pages leaves the page tree laid out again, so pages
// held from before the call are stale.
//
// An ArgumentException or ArgumentOutOfRangeException of the C# is a precondition here when only the caller's code can cause
// it (a page index, an angle). What a file or the user's input can cause (a box off the page, a size read from a neighbouring
// page, every page deleted) is thrown instead, as `PdfReadException.damaged` with the C# message.

public enum PageBox { case media, crop, trim, bleed, art }

/// How `PageOperations.resize` reaches the new size.
public enum ResizeMode {
    /// The content is scaled to fit, centred; the aspect ratio is kept.
    case scaleContent

    /// The boxes change and the content stays where it is: it is cut off or leaves white space.
    case changeBox
}

public enum PageOperations {
    static let maxPageSize = 14400.0

    private static func key(_ box: PageBox) -> String {
        switch box {
        case .media: return "MediaBox"
        case .crop: return "CropBox"
        case .trim: return "TrimBox"
        case .bleed: return "BleedBox"
        case .art: return "ArtBox"
        }
    }

    /// Turns the pages clockwise by `degrees`, a multiple of 90 (negative turns back). /Rotate stays 0, 90, 180 or 270.
    public static func rotate(_ document: PdfDocument, _ pages: [Int], _ degrees: Int) {
        precondition(degrees % 90 == 0, "A page turns in steps of 90 degrees.")
        for page in select(document, pages) {
            page.dictionary["Rotate"] = PdfNumber(((page.rotate &+ degrees) % 360 + 360) % 360)
        }
    }

    /// Sets a box, clipped to the media box (ISO 32000-1 14.11.2), or removes it with nil. The media box cannot be
    /// removed. A rectangle with no area, or none inside the media box, is refused.
    public static func setBox(_ document: PdfDocument, _ pages: [Int], _ box: PageBox, _ rect: PdfRect?) throws {
        precondition(rect != nil || box != .media, "A page needs a media box.")
        if let rect, rect.isEmpty { throw PdfReadException.damaged("The box has no area.") }
        for page in select(document, pages) {
            guard let value = rect else {
                page.dictionary.remove(key(box))
                continue
            }
            let set = box == .media ? value : value.intersect(page.mediaBox)
            if set.isEmpty { throw PdfReadException.damaged("The box lies outside the page.") }
            page.dictionary[key(box)] = set.toArray()
        }
        // A page keeps the values it had when the tree was read, so a removed box would still show.
        if rect == nil {
            let before = document.pages.map { $0.reference }
            document.refreshPages()
            // Pages that were found by scanning are in no tree, and the walk would not find them again.
            if document.pages.isEmpty && !before.isEmpty { try PageTree.set(document, before) }
        }
    }

    /// Gives the pages a size in points as they are shown (turned pages included). With `ResizeMode.scaleContent` the
    /// content, the annotation rectangles and the other boxes are mapped by a matrix written round the page's content;
    /// with `ResizeMode.changeBox` the media and crop boxes become that size from the crop box's lower-left corner and the
    /// trim, bleed and art boxes are removed.
    public static func resize(_ document: PdfDocument, _ pages: [Int], _ width: Double, _ height: Double, _ mode: ResizeMode) throws {
        if !(width > 0 && width <= maxPageSize && height > 0 && height <= maxPageSize) { throw PdfReadException.damaged("The size is out of range.") }
        for page in select(document, pages) {
            let crop = page.cropBox
            let turned = page.rotate % 180 != 0
            let w = (turned ? height : width) / page.userUnit, h = (turned ? width : height) / page.userUnit
            let dict = page.dictionary
            if mode == .changeBox {
                let media = PdfRect(crop.left, crop.bottom, crop.left + w, crop.bottom + h)
                dict["MediaBox"] = media.toArray()
                dict["CropBox"] = media.toArray()
                for key in ["TrimBox", "BleedBox", "ArtBox"] { dict.remove(key) }
                continue
            }
            let s = min(w / crop.width, h / crop.height)
            let e = (w - s * crop.width) / 2 - s * crop.left, f = (h - s * crop.height) / 2 - s * crop.bottom
            try wrapContents(document, dict, s, e, f)
            try mapPatterns(document, page, PdfMatrix(s, 0, 0, s, e, f))
            mapAnnotations(document, dict, s, e, f)
            let whole = PdfRect(0, 0, w, h)
            dict["MediaBox"] = whole.toArray()
            dict["CropBox"] = whole.toArray()
            for key in ["TrimBox", "BleedBox", "ArtBox"] {
                if let box = document.rect(dict[key]) {
                    dict[key] = PdfRect(s * box.left + e, s * box.bottom + f, s * box.right + e, s * box.top + f).toArray()
                } else {
                    dict.remove(key)
                }
            }
        }
    }

    /// Removes the automatic advance and the transition effect of the pages (ISO 32000-1 12.4.4).
    public static func removeTransitions(_ document: PdfDocument, _ pages: [Int]) {
        for page in select(document, pages) {
            page.dictionary.remove("Trans")
            page.dictionary.remove("Dur")
        }
    }

    static func select(_ document: PdfDocument, _ indexes: [Int]) -> [PdfPage] {
        let pages = document.pages
        var chosen: [PdfPage] = []
        for index in Set(indexes).sorted() {
            precondition(index >= 0 && index < pages.count, "There is no page \(index &+ 1).")
            chosen.append(pages[index])
        }
        return chosen
    }

    private static func wrapContents(_ document: PdfDocument, _ page: PdfDictionary, _ s: Double, _ e: Double, _ f: Double) throws {
        guard let contents = document.resolve(page["Contents"]) else { return }
        var parts: [PdfObject] = []
        let matrix = "q \(PdfNumber(s).text) 0 0 \(PdfNumber(s).text) \(PdfNumber(e).text) \(PdfNumber(f).text) cm\n"
        parts.append(try document.add(PdfStream(PdfDictionary(), data: Latin1.bytes(matrix))))
        if let array = contents as? PdfArray {
            parts.append(contentsOf: array.items)
        } else {
            parts.append(page["Contents"] ?? contents)
        }
        parts.append(try document.add(PdfStream(PdfDictionary(), data: Latin1.bytes("\nQ"))))
        page["Contents"] = PdfArray(parts)
    }

    // A pattern's matrix goes to the page's default space, which the cm round the content does not reach (8.7.3.1).
    // The page gets its own pattern objects, as the old ones may be shared with pages that keep their size.
    private static func mapPatterns(_ document: PdfDocument, _ page: PdfPage, _ scale: PdfMatrix) throws {
        guard let pageResources = page.resources, let patterns = document.dict(pageResources, "Pattern") else { return }
        let resources = pageResources.copy()
        let own = PdfDictionary()
        for (name, value) in patterns.entries {
            var made = value
            let resolved = document.resolve(value)
            let tiling = resolved as? PdfStream
            if let dictionary = tiling?.dictionary ?? (resolved as? PdfDictionary) {
                let matrix = PdfMatrix.fromArray(document.array(dictionary, "Matrix"), document.resolve) ?? PdfMatrix.identity
                let moved = matrix.multiply(scale)
                let copy = dictionary.copy()
                copy["Matrix"] = PdfArray([moved.a, moved.b, moved.c, moved.d, moved.e, moved.f].map { PdfNumber($0) })
                if let tiling {
                    made = try document.add(PdfStream(copy, data: document.rawData(tiling)))
                } else {
                    made = try document.add(copy)
                }
            }
            own[name] = made
        }
        resources["Pattern"] = own
        page.dictionary["Resources"] = resources
    }

    private static func mapAnnotations(_ document: PdfDocument, _ page: PdfDictionary, _ s: Double, _ e: Double, _ f: Double) {
        guard let annots = document.array(page, "Annots") else { return }
        for item in annots.items {
            guard let annotation = document.resolve(item) as? PdfDictionary else { continue }
            for key in ["Rect", "QuadPoints", "L", "Vertices", "CL"] {
                if let points = document.array(annotation, key) { annotation[key] = mapPoints(document, points, s, e, f) }
            }
            if let strokes = document.array(annotation, "InkList") {
                annotation["InkList"] = PdfArray(strokes.items.map { i in
                    (document.resolve(i) as? PdfArray).map { mapPoints(document, $0, s, e, f) } ?? i
                })
            }
            // /RD is a set of distances, not points: they scale and do not move.
            if let insets = document.array(annotation, "RD") {
                annotation["RD"] = PdfArray(insets.items.map { i in
                    (document.resolve(i) as? PdfNumber).map { PdfNumber(s * $0.value) as PdfObject } ?? i
                })
            }
        }
    }

    // Pairs of numbers as points; an array that is not that is left alone.
    private static func mapPoints(_ document: PdfDocument, _ points: PdfArray, _ s: Double, _ e: Double, _ f: Double) -> PdfObject {
        let numbers = points.items.compactMap { document.resolve($0) as? PdfNumber }
        if numbers.count != points.items.count || numbers.count % 2 != 0 { return points }
        var mapped: [PdfObject] = []
        for i in stride(from: 0, to: numbers.count, by: 2) {
            mapped.append(PdfNumber(s * numbers[i].value + e))
            mapped.append(PdfNumber(s * numbers[i + 1].value + f))
        }
        return PdfArray(mapped)
    }
}
