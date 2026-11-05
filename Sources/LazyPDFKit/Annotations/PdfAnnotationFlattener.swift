import Foundation

// Twin of windows/LazyPDF.Core/Annotations/PdfAnnotationFlattener.cs: burns annotation appearances into the page
// content (ISO 32000-1 12.5.5) and takes the annotations out of the page. Hidden annotations and those marked NoView
// have no appearance on screen and are left alone, as are annotations without an appearance stream.
//
// The internal overload the Forms layer uses, Flatten(document, page, Func), is flatten(_:_:include:) here.

public enum PdfAnnotationFlattener {
    /// What "all" means: every kind that only shows something. Links, form widgets, popups, attachments and redaction
    /// marks do more than that and have to be named to be flattened.
    public static let defaultTypes: Set<AnnotationType> = [
        .text, .freeText, .line, .square, .circle, .polygon, .polyLine, .highlight, .underline, .squiggly,
        .strikeOut, .stamp, .caret, .ink, .other,
    ]

    /// Flattens the annotations of every page; the number of annotations burned in.
    @discardableResult
    public static func flattenAll(_ document: PdfDocument, _ types: Set<AnnotationType>? = nil) throws -> Int {
        var count = 0
        for page in document.pages { count += try flatten(document, page, types) }
        return count
    }

    /// Flattens the page's annotations of `types` (nil: `defaultTypes`) and returns how many were burned in. Their
    /// popups and replies go with them.
    @discardableResult
    public static func flatten(_ document: PdfDocument, _ page: PdfPage, _ types: Set<AnnotationType>? = nil) throws -> Int {
        let types = types ?? defaultTypes
        return try flatten(document, page, include: { types.contains($0.type) })
    }

    /// The same for the annotations `include` picks; the Forms layer flattens chosen widgets with it.
    @discardableResult
    static func flatten(_ document: PdfDocument, _ page: PdfPage, include: (PdfAnnotation) -> Bool) throws -> Int {
        let all = PdfAnnotations.read(document, page)
        var drawn: [(annotation: PdfAnnotation, form: PdfReference, stream: PdfStream)] = []
        let off = Set(PdfLayers.read(document).layers.filter { !$0.isOn }.map { $0.reference.number })
        for a in all {
            if !include(a) || a.flags.contains(.hidden) || a.flags.contains(.noView) { continue }
            // What a hidden layer holds is not on show, so it is not burned in.
            if let group = a.dictionary["OC"] as? PdfReference, off.contains(group.number) { continue }
            if let form = appearance(document, a.dictionary) { drawn.append((a, form.reference, form.stream)) }
        }
        if drawn.isEmpty { return 0 }

        let resources = ContentResources.forEdit(document, page)
        let content = ContentWriter()
        for (annotation, reference, stream) in drawn {
            if !stream.dictionary.containsKey("Subtype") { stream.dictionary["Subtype"] = PdfName("Form") }
            let name = ContentResources.add(document, resources, "XObject", reference, "Fm")
            let noRotate = annotation.flags.contains(.noRotate) && page.rotate != 0
            content.paint(name, noRotate ? upright(document, stream, annotation.rect, page) : placement(document, stream, annotation.rect))
        }
        try surround(document, page, content.toArray())

        var gone = Set(drawn.map { ObjectIdentifier($0.annotation.dictionary) })
        var numbers = Set(drawn.compactMap { $0.annotation.reference?.number })
        // Popups and replies of a flattened annotation, replies of replies included.
        var grew = true
        while grew {
            grew = false
            for a in all {
                var child = false
                if a.type == .popup, let p = a.dictionary["Parent"] as? PdfReference, numbers.contains(p.number) { child = true }
                if let r = a.inReplyTo, numbers.contains(r.number) { child = true }
                if child && gone.insert(ObjectIdentifier(a.dictionary)).inserted {
                    grew = true
                    if let reference = a.reference { numbers.insert(reference.number) }
                }
            }
        }
        if let annots = document.array(page.dictionary, "Annots") {
            annots.items.removeAll { item in
                if let d = document.resolve(item) as? PdfDictionary { return gone.contains(ObjectIdentifier(d)) }
                return false
            }
        }
        for number in numbers { document.delete(number) }
        return drawn.count
    }

    private static func appearance(_ document: PdfDocument, _ annotation: PdfDictionary) -> (reference: PdfReference, stream: PdfStream)? {
        guard let ap = document.dict(annotation, "AP"), let normal = ap["N"] else { return nil }
        var value = normal
        if let states = document.resolve(normal) as? PdfDictionary {
            guard let state = document.name(annotation, "AS"), let chosen = states[state] else { return nil }
            value = chosen
        }
        guard let stream = document.resolve(value) as? PdfStream else { return nil }
        let reference = value as? PdfReference ?? (stream.number > 0 ? PdfReference(stream.number, stream.generation) : nil)
        guard let found = reference else { return nil }
        return (found, stream)
    }

    // The algorithm of 12.5.5: the form's box through its matrix, then fitted to /Rect.
    private static func placement(_ document: PdfDocument, _ form: PdfStream, _ rect: PdfRect) -> PdfMatrix {
        let box = document.rect(form.dictionary, "BBox") ?? PdfRect(0, 0, rect.width, rect.height)
        let matrix = PdfMatrix.fromArray(document.array(form.dictionary, "Matrix")) { document.resolve($0) } ?? PdfMatrix.identity
        let transformed = matrix.transform(box)
        let sx = transformed.width > 0 ? rect.width / transformed.width : 1, sy = transformed.height > 0 ? rect.height / transformed.height : 1
        return PdfMatrix(sx, 0, 0, sy, rect.left - transformed.left * sx, rect.bottom - transformed.bottom * sy)
    }

    // NoRotate (12.5.3): the appearance stays upright on the shown page, at its natural size, with the corner of the
    // rectangle that is shown top left kept where it is.
    private static func upright(_ document: PdfDocument, _ form: PdfStream, _ rect: PdfRect, _ page: PdfPage) -> PdfMatrix {
        let box = document.rect(form.dictionary, "BBox") ?? PdfRect(0, 0, rect.width, rect.height)
        let matrix = PdfMatrix.fromArray(document.array(form.dictionary, "Matrix")) { document.resolve($0) } ?? PdfMatrix.identity
        let natural = matrix.transform(box)
        let geometry = PageGeometry(page)
        let anchor = geometry.toDisplay(rect)
        let unit = page.userUnit
        func at(_ u: Double, _ v: Double) -> (x: Double, y: Double) {
            geometry.toUser(anchor.x + (u - natural.left) * unit, anchor.y + (natural.top - v) * unit)
        }
        let origin = at(natural.left, natural.bottom)
        let right = at(natural.left + 1, natural.bottom)
        let up = at(natural.left, natural.bottom + 1)
        let a = right.x - origin.x, b = right.y - origin.y, c = up.x - origin.x, d = up.y - origin.y
        return PdfMatrix(a, b, c, d, origin.x - a * natural.left - c * natural.bottom, origin.y - b * natural.left - d * natural.bottom)
    }

    // Wraps the page's own content in q ... Q, closing any q it left open, so that nothing it left in the graphics state
    // reaches the annotations.
    private static func surround(_ document: PdfDocument, _ page: PdfPage, _ annotations: [UInt8]) throws {
        var open = 0
        for operation in ContentParser.parse(page.contents()) {
            if operation.operator == "q" {
                open += 1
            } else if operation.operator == "Q" && open > 0 {
                open -= 1
            }
        }
        var closing: [UInt8] = []
        for _ in 0..<min(open, 256) { closing.append(contentsOf: [0x51, 0x0A]) }
        let head = try document.add(PdfStream(PdfDictionary(), data: [0x71, 0x0A]))
        let tail = try document.add(PdfStream(PdfDictionary(), data: closing + [0x51, 0x0A] + annotations))
        var items: [PdfObject] = [head]
        let existing = page.dictionary["Contents"]
        if let array = document.resolve(existing) as? PdfArray {
            items.append(contentsOf: array.items)
        } else if let existing, document.resolve(existing) is PdfStream {
            items.append(existing)
        }
        items.append(tail)
        page.dictionary["Contents"] = PdfArray(items)
    }
}
