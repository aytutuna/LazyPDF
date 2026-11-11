import Foundation

// Twin of windows/LazyPDF.Core/Annotations/PdfAnnotationWriter.cs: creates annotations on a page and changes them. Every
// annotation made or changed gets an /AP /N that carries all of its look, because the system renderer ignores /CA and
// /NeedAppearances. The document is edited in memory; the edit session commits it. Each call returns the annotation as
// it stands, and the values of the one passed in are stale afterwards.
//
// `fonts` is where fonts for text that Standard 14 cannot draw (Turkish ğ, ş, ı) come from. A call that adds objects
// throws, because PdfDocument.add does. The C# ArgumentException of a call that cannot be made (no area, no points, a
// reply to a direct annotation) is a thrown ArgumentException, since a click, a selection or a file can cause it; the
// missing font is an InvalidOperationException.

public final class PdfAnnotationWriter {
    let document: PdfDocument
    let appearance: AppearanceBuilder

    public init(_ document: PdfDocument, _ fonts: FontSource? = nil) {
        self.document = document
        appearance = AppearanceBuilder(document, fonts)
    }

    /// The characters that no installed font could draw in the free text, stamps and redraws since the last call, once
    /// each in code point order; they are left blank. Clears them.
    public func takeUndrawn() -> String { appearance.takeUndrawn() }

    func newAnnotation(_ subtype: String, _ rect: PdfRect, _ info: AnnotationInfo?, _ color: [Double]?, _ opacity: Double = 1) -> PdfDictionary {
        let d = PdfDictionary()
        d["Type"] = PdfName("Annot")
        d["Subtype"] = PdfName(subtype)
        d["Rect"] = rect.toArray()
        d["F"] = PdfNumber((info?.flags ?? .print).rawValue)
        d["NM"] = PdfText.toObject(UUID().uuidString.lowercased())
        if let color { d["C"] = Self.numbers(color) }
        if opacity < 1 { d["CA"] = PdfNumber(min(max(opacity, 0), 1)) }
        if let author = info?.author, !author.isEmpty { d["T"] = PdfText.toObject(author) }
        if let contents = info?.contents, !contents.isEmpty { d["Contents"] = PdfText.toObject(contents) }
        if let subject = info?.subject, !subject.isEmpty { d["Subj"] = PdfText.toObject(subject) }
        if let date = info?.date {
            d["CreationDate"] = PdfText.toObject(PdfDate.format(date))
            d["M"] = PdfText.toObject(PdfDate.format(date))
        }
        return d
    }

    static func setBorder(_ d: PdfDictionary, _ style: AnnotationStyle) {
        let bs = PdfDictionary()
        bs["Type"] = PdfName("Border")
        bs["W"] = PdfNumber(style.width)
        if let dash = style.dash, !dash.isEmpty {
            bs["S"] = PdfName("D")
            bs["D"] = numbers(dash)
        } else {
            bs["S"] = PdfName("S")
        }
        d["BS"] = bs
    }

    static func numbers(_ values: [Double]) -> PdfArray { PdfArray(values.map { PdfNumber($0) }) }

    /// Draws the appearance, adds the annotation to the page and reads it back.
    func place(_ page: PdfPage, _ d: PdfDictionary) throws -> PdfAnnotation {
        if !(try appearance.apply(d)) { throw ArgumentException("The annotation has no area to draw.") }
        return try attach(page, d)
    }

    func attach(_ page: PdfPage, _ d: PdfDictionary) throws -> PdfAnnotation {
        let reference = try document.add(d)
        if let annots = document.array(page.dictionary, "Annots") {
            annots.items.append(reference)
        } else {
            page.dictionary["Annots"] = PdfArray([reference])
        }
        return reread(d, reference, page.index)
    }

    // The dictionary has a /Subtype where this writer made it, so the parse cannot come back empty.
    private func reread(_ d: PdfDictionary, _ reference: PdfReference?, _ pageIndex: Int) -> PdfAnnotation {
        guard let annotation = PdfAnnotations.parse(document, d, reference, pageIndex) else {
            preconditionFailure("The annotation has no /Subtype.")
        }
        return annotation
    }

    static func inflate(_ r: PdfRect, _ by: Double) -> PdfRect { PdfRect(r.left - by, r.bottom - by, r.right + by, r.top + by) }

    static func boundsOf(_ points: [PdfPoint]) -> PdfRect {
        precondition(!points.isEmpty, "There are no points.")
        return PdfRect(points.map { $0.x }.min() ?? 0, points.map { $0.y }.min() ?? 0, points.map { $0.x }.max() ?? 0, points.map { $0.y }.max() ?? 0)
    }

    /// The appearance drawn again from the annotation's keys, replacing the one it had; false for a kind this layer does not draw.
    @discardableResult
    public func regenerate(_ annotation: PdfAnnotation) throws -> Bool {
        try appearance.apply(annotation.dictionary)
    }

    /// Shifts the annotation and the points it keeps; the appearance moves with /Rect.
    @discardableResult
    public func move(_ annotation: PdfAnnotation, _ dx: Double, _ dy: Double) throws -> PdfAnnotation {
        try edit(annotation, redraw: false) {
            map(annotation.dictionary, { $0 + dx }, { $0 + dy })
            annotation.dictionary["Rect"] = PdfRect(annotation.rect.left + dx, annotation.rect.bottom + dy,
                                                     annotation.rect.right + dx, annotation.rect.top + dy).toArray()
        }
    }

    /// Fits the annotation and its points into `rect`, then draws it again so that borders keep their width and text
    /// wraps anew. An image stamp or a stamp from another writer is left to scale.
    @discardableResult
    public func resize(_ annotation: PdfAnnotation, _ rect: PdfRect) throws -> PdfAnnotation {
        try edit(annotation, redraw: true) {
            let old = annotation.rect
            let sx = old.width > 0 ? rect.width / old.width : 1, sy = old.height > 0 ? rect.height / old.height : 1
            map(annotation.dictionary, { rect.left + ($0 - old.left) * sx }, { rect.bottom + ($0 - old.bottom) * sy })
            annotation.dictionary["Rect"] = rect.toArray()
        }
    }

    /// Sets the main colour (/C) and, when given, the interior colour (/IC); an empty array makes it transparent.
    @discardableResult
    public func setColor(_ annotation: PdfAnnotation, _ color: [Double], interior: [Double]? = nil) throws -> PdfAnnotation {
        try edit(annotation, redraw: true) {
            annotation.dictionary["C"] = Self.numbers(color)
            if let interior { annotation.dictionary["IC"] = Self.numbers(interior) }
        }
    }

    @discardableResult
    public func setOpacity(_ annotation: PdfAnnotation, _ opacity: Double) throws -> PdfAnnotation {
        try edit(annotation, redraw: true) {
            annotation.dictionary["CA"] = PdfNumber(min(max(opacity, 0), 1))
        }
    }

    /// Changes /Contents and /M. A free text box is drawn again with the new text, its rich text dropped as out of date.
    @discardableResult
    public func setContents(_ annotation: PdfAnnotation, _ text: String, date: DateTimeOffset? = nil) throws -> PdfAnnotation {
        try edit(annotation, redraw: annotation.type == .freeText) {
            let d = annotation.dictionary
            d["Contents"] = PdfText.toObject(text)
            if let modified = date { d["M"] = PdfText.toObject(PdfDate.format(modified)) }
            if annotation.type == .freeText { d.remove("RC") }
        }
    }

    // Runs a change and, when it asks for it, draws the appearance again. A drawing that fails (no font for the text)
    // leaves the annotation as it was.
    func edit(_ annotation: PdfAnnotation, redraw: Bool, _ change: () throws -> Void) throws -> PdfAnnotation {
        let d = annotation.dictionary
        let before = d.copy()
        do {
            try change()
            if redraw { _ = try regenerate(annotation) }
        } catch {
            for key in Set(d.entries.map { $0.key }) { d.remove(key) }
            for entry in before.entries { d[entry.key] = entry.value }
            throw error
        }
        return reread(d, annotation.reference, annotation.pageIndex)
    }

    /// Removes the annotation from its page and frees it, with its popup and every reply that leads back to it. False
    /// when the page no longer lists it.
    @discardableResult
    public func delete(_ annotation: PdfAnnotation) -> Bool {
        if annotation.pageIndex < 0 || annotation.pageIndex >= document.pages.count { return false }
        let page = document.pages[annotation.pageIndex]
        guard let annots = document.array(page.dictionary, "Annots") else { return false }
        if !annots.items.contains(where: { isSame($0, annotation) }) { return false }

        var doomed = [annotation]
        let onPage = PdfAnnotations.read(document, page)
        var i = 0
        while i < doomed.count {
            defer { i += 1 }
            guard let parent = doomed[i].reference else { continue }
            for other in onPage where other.inReplyTo?.number == parent.number {
                if !doomed.contains(where: { $0.dictionary === other.dictionary }) { doomed.append(other) }
            }
        }
        for gone in doomed {
            unlink(gone)
            if let popup = gone.popup { remove(annots, document.resolve(popup), popup) }
            remove(annots, gone.dictionary, gone.reference)
        }
        return true
    }

    // A widget also sits in its field's /Kids or the form's /Fields, a popup is named by its owner.
    private func unlink(_ gone: PdfAnnotation) {
        let d = gone.dictionary
        func isThis(_ item: PdfObject) -> Bool {
            if document.resolve(item) === d { return true }
            if let r = gone.reference, let x = item as? PdfReference { return x.number == r.number }
            return false
        }
        if gone.type == .widget {
            let holder = document.array(document.dict(d, "Parent"), "Kids") ?? document.array(document.dict(document.catalog, "AcroForm"), "Fields")
            holder?.items.removeAll(where: isThis)
        } else if gone.type == .popup, let owner = document.dict(d, "Parent"), isThis(owner["Popup"] ?? PdfNull.instance) {
            owner.remove("Popup")
        }
    }

    private func remove(_ annots: PdfArray, _ target: PdfObject?, _ reference: PdfReference?) {
        annots.items.removeAll { document.resolve($0) === target }
        if let reference { document.delete(reference.number) }
    }

    private func isSame(_ item: PdfObject, _ annotation: PdfAnnotation) -> Bool {
        document.resolve(item) === annotation.dictionary
    }

    // Applies a point mapping to every key that holds page coordinates. The arrays are replaced, not changed in place, so
    // that edit can put the old ones back.
    private func map(_ d: PdfDictionary, _ fx: (Double) -> Double, _ fy: (Double) -> Double) {
        for key in ["QuadPoints", "Vertices", "L", "CL"] {
            if let array = document.array(d, key) { d[key] = mapPairs(array, fx, fy) }
        }
        if let ink = document.array(d, "InkList") {
            d["InkList"] = PdfArray(ink.items.map { (path: PdfObject) -> PdfObject in
                if let inner = document.resolve(path) as? PdfArray { return mapPairs(inner, fx, fy) }
                return path
            })
        }
    }

    private func mapPairs(_ array: PdfArray, _ fx: (Double) -> Double, _ fy: (Double) -> Double) -> PdfArray {
        var items = array.items
        var i = 0
        while i + 1 < items.count {
            if let x = document.resolve(items[i]) as? PdfNumber, let y = document.resolve(items[i + 1]) as? PdfNumber {
                items[i] = PdfNumber(fx(x.value))
                items[i + 1] = PdfNumber(fy(y.value))
            }
            i += 2
        }
        return PdfArray(items)
    }
}
