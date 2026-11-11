import Foundation

// Twin of windows/LazyPDF.Core/Annotations/PdfAnnotationWriter.Notes.cs: notes, text boxes, stamps, carets, attached
// files, redaction marks and links.
//
// AddJpegStamp throws PdfReadException (damaged) for a file that is not a JPEG, where the C# raises ArgumentException:
// the bytes come from a file the user chose.

extension PdfAnnotationWriter {
    private static let noteYellow: [Double] = [1, 0.9, 0.2]

    /// A sticky note. `rect` is the icon, 20 by 20 points as a rule; `icon` is /Name (Note, Comment, Key, Help, Paragraph...).
    @discardableResult
    public func addNote(_ page: PdfPage, _ rect: PdfRect, _ info: AnnotationInfo, icon: String = "Note", color: [Double]? = nil) throws -> PdfAnnotation {
        var withFlags = info
        withFlags.flags = info.flags.union([.noZoom, .noRotate])
        let d = newAnnotation("Text", rect, withFlags, color ?? Self.noteYellow)
        d["Name"] = PdfName(icon)
        d["Open"] = PdfBoolean(false)
        return try place(page, d)
    }

    // A reply is a note nobody should see on the page: hidden, kept in the list by /IRT.
    func addReply(_ parent: PdfAnnotation, _ info: AnnotationInfo, _ status: ReviewStatus?) throws -> PdfAnnotation {
        guard let target = parent.reference, parent.pageIndex >= 0, parent.pageIndex < document.pages.count else {
            throw ArgumentException("The annotation to answer is not an indirect object on a page.")
        }
        let rect = PdfRect(parent.rect.left, parent.rect.top - 20, parent.rect.left + 20, parent.rect.top)
        var flags = info
        flags.flags = [.hidden, .print, .noZoom, .noRotate]
        let d = newAnnotation("Text", rect, flags, Self.noteYellow)
        d["IRT"] = target
        d["RT"] = PdfName("R")
        d["Name"] = PdfName("Note")
        if let s = status {
            d["StateModel"] = PdfText.toObject(s == .marked || s == .unmarked ? "Marked" : "Review")
            d["State"] = PdfText.toObject(s.rawValue)
        }
        return try place(document.pages[parent.pageIndex], d)
    }

    /// A text box. With `callout` (two or three points, the first at what it points to) the annotation grows to hold the
    /// callout line and /RD marks where the box sits in it.
    @discardableResult
    public func addFreeText(_ page: PdfPage, _ box: PdfRect, _ text: String, font: FreeTextStyle? = nil, style: AnnotationStyle? = nil,
                            info: AnnotationInfo? = nil, callout: [PdfPoint]? = nil) throws -> PdfAnnotation {
        let font = font ?? FreeTextStyle()
        let style = style ?? AnnotationStyle(width: 0)
        if let callout, callout.count < 2 || callout.count > 3 { throw ArgumentException("A callout has two or three points.") }
        let plain = text.isEmpty && font.richText != nil ? PdfRichText.toPlain(font.richText ?? "") : text
        var contents = info ?? AnnotationInfo()
        contents.contents = plain

        var rect = box
        if let callout {
            let margin = AppearanceBuilder.endingSize(max(1, style.width)) + max(1, style.width)
            let bounds = Self.boundsOf(callout)
            rect = PdfRect(min(box.left, bounds.left - margin), min(box.bottom, bounds.bottom - margin),
                           max(box.right, bounds.right + margin), max(box.top, bounds.top + margin))
        }
        let d = newAnnotation("FreeText", rect, contents, style.color, style.opacity)
        if let fill = style.fill { d["IC"] = Self.numbers(fill) }
        Self.setBorder(d, style)
        if let callout {
            d["IT"] = PdfName("FreeTextCallout")
            d["CL"] = Self.numbers(callout.flatMap { [$0.x, $0.y] })
            d["LE"] = PdfName("OpenArrow")
        } else {
            d["IT"] = PdfName("FreeText")
        }
        if rect != box { d["RD"] = Self.numbers([box.left - rect.left, box.bottom - rect.bottom, rect.right - box.right, rect.top - box.top]) }
        Self.setTextKeys(d, font)
        return try place(page, d)
    }

    /// Changes the font, size, colour, alignment or rich text of a free text annotation and draws it again.
    @discardableResult
    public func setFreeTextStyle(_ annotation: PdfAnnotation, _ font: FreeTextStyle) throws -> PdfAnnotation {
        guard annotation.type == .freeText else { throw ArgumentException("Not a free text annotation.") }
        return try edit(annotation, redraw: true) { Self.setTextKeys(annotation.dictionary, font) }
    }

    private static func setTextKeys(_ d: PdfDictionary, _ font: FreeTextStyle) {
        let format = TextFormat(font.family, font.size, font.font.contains(.bold), font.font.contains(.italic), false, font.textColor ?? [0])
        d["DA"] = PdfText.toObject(DefaultAppearance.build(format))
        d["DS"] = PdfText.toObject(DefaultAppearance.buildStyle(format, font.alignment))
        d["Q"] = PdfNumber(min(max(font.alignment, 0), 2))
        if let rich = font.richText, !rich.isEmpty {
            d["RC"] = PdfText.toObject(rich)
        } else {
            d.remove("RC")
        }
    }

    /// A stamp drawn as bold text in a box. `name` is a standard name (`AnnotationText.standardStamps`) or the words to show.
    @discardableResult
    public func addStamp(_ page: PdfPage, _ rect: PdfRect, _ name: String, info: AnnotationInfo? = nil, color: [Double]? = nil) throws -> PdfAnnotation {
        let d = newAnnotation("Stamp", rect, info, color)
        d["Name"] = PdfName.fromText(name)
        return try place(page, d)
    }

    /// A stamp showing straight RGBA8 pixels, top row first.
    @discardableResult
    public func addImageStamp(_ page: PdfPage, _ rect: PdfRect, _ width: Int, _ height: Int, _ rgba: [UInt8], info: AnnotationInfo? = nil) throws -> PdfAnnotation {
        try placeImage(page, rect, try ContentImages.addRgba(document, width, height, rgba), info)
    }

    /// A stamp showing a JPEG file as it is.
    @discardableResult
    public func addJpegStamp(_ page: PdfPage, _ rect: PdfRect, _ jpeg: [UInt8], info: AnnotationInfo? = nil) throws -> PdfAnnotation {
        guard let image = try ContentImages.addJpeg(document, jpeg) else { throw PdfReadException.damaged("The JPEG cannot be read.") }
        return try placeImage(page, rect, image, info)
    }

    private func placeImage(_ page: PdfPage, _ rect: PdfRect, _ image: PdfReference, _ info: AnnotationInfo?) throws -> PdfAnnotation {
        guard !rect.isEmpty else { throw ArgumentException("The stamp has no area.") }
        let d = newAnnotation("Stamp", rect, info, nil)
        d["Name"] = PdfName("Image")
        let canvas = AppearanceCanvas(document, rect)
        let name = canvas.addXObject(image)
        canvas.w.paint(name, PdfMatrix(rect.width, 0, 0, rect.height, 0, 0))
        let ap = PdfDictionary()
        ap["N"] = try document.add(canvas.toStream())
        d["AP"] = ap
        return try attach(page, d)
    }

    /// The proofreader's caret for inserted text (/Sy /P).
    @discardableResult
    public func addCaret(_ page: PdfPage, _ rect: PdfRect, info: AnnotationInfo? = nil, style: AnnotationStyle? = nil) throws -> PdfAnnotation {
        let style = style ?? AnnotationStyle()
        let d = newAnnotation("Caret", rect, info, style.color ?? AppearanceBuilder.black, style.opacity)
        d["Sy"] = PdfName("P")
        return try place(page, d)
    }

    /// A file attached at a point. `icon` is PushPin, Paperclip, Graph or Tag.
    @discardableResult
    public func addFileAttachment(_ page: PdfPage, _ rect: PdfRect, _ fileName: String, _ data: [UInt8], info: AnnotationInfo? = nil,
                                  icon: String = "PushPin", mimeType: String? = nil) throws -> PdfAnnotation {
        let parameters = PdfDictionary()
        parameters["Size"] = PdfNumber(data.count)
        parameters["CheckSum"] = PdfString(bytes: Md5.hash(data), isHex: true)
        if let date = info?.date { parameters["ModDate"] = PdfText.toObject(PdfDate.format(date)) }
        let file = PdfDictionary()
        file["Type"] = PdfName("EmbeddedFile")
        file["Params"] = parameters
        if let mimeType { file["Subtype"] = PdfName(mimeType) }
        var stored = data
        if data.count > 64 {
            let packed = PdfFilterEncoders.flate(data)
            if packed.count < data.count {
                stored = packed
                file["Filter"] = PdfName("FlateDecode")
            }
        }
        let stream = try document.add(PdfStream(file, data: stored))
        let spec = PdfDictionary()
        spec["Type"] = PdfName("Filespec")
        spec["F"] = PdfText.toFileName(fileName)
        spec["UF"] = PdfText.toObject(fileName)
        let files = PdfDictionary()
        files["F"] = stream
        files["UF"] = stream
        spec["EF"] = files
        var withFlags = info ?? AnnotationInfo()
        withFlags.flags = (info?.flags ?? .print).union([.noZoom, .noRotate])
        let d = newAnnotation("FileAttachment", rect, withFlags, nil)
        d["Name"] = PdfName(icon)
        d["FS"] = try document.add(spec)
        return try place(page, d)
    }

    /// The mark for a redaction over the quads (ISO 32000-2 12.5.6.23); the content under it stays until a later step
    /// removes it. `fill` is the colour the area gets then and `overlayText` the text drawn on it.
    @discardableResult
    public func addRedact(_ page: PdfPage, _ quads: [MarkupQuad], info: AnnotationInfo? = nil, fill: [Double]? = nil, overlayText: String? = nil) throws -> PdfAnnotation {
        guard !quads.isEmpty else { throw ArgumentException("A redaction needs at least one quad.") }
        let d = newAnnotation("Redact", Self.inflate(Self.union(quads), 2), info, AppearanceBuilder.red)
        d["QuadPoints"] = Self.numbers(quads.flatMap { $0.toNumbers() })
        d["IC"] = Self.numbers(fill ?? AppearanceBuilder.black)
        if let overlayText, !overlayText.isEmpty { d["OverlayText"] = PdfText.toObject(overlayText) }
        return try place(page, d)
    }

    /// A link to a place in the document. With a border in `style` (width above 0 and a colour) the link gets an
    /// appearance that draws it.
    @discardableResult
    public func addLink(_ page: PdfPage, _ rect: PdfRect, _ destination: PdfDestination, style: AnnotationStyle? = nil) throws -> PdfAnnotation {
        guard let target = PdfDestinations.toObject(document, destination) else {
            throw ArgumentException("The destination has no page in the document.")
        }
        return try placeLink(page, rect, "Dest", target, style)
    }

    @discardableResult
    public func addLink(_ page: PdfPage, _ rect: PdfRect, _ action: PdfAction, style: AnnotationStyle? = nil) throws -> PdfAnnotation {
        try placeLink(page, rect, "A", PdfActions.toObject(document, action), style)
    }

    private func placeLink(_ page: PdfPage, _ rect: PdfRect, _ key: String, _ target: PdfObject, _ style: AnnotationStyle?) throws -> PdfAnnotation {
        let d = PdfDictionary()
        d["Type"] = PdfName("Annot")
        d["Subtype"] = PdfName("Link")
        d["Rect"] = rect.toArray()
        d["F"] = PdfNumber(AnnotationFlags.print.rawValue)
        d[key] = target
        if let style, style.width > 0, let color = style.color, !color.isEmpty {
            d["C"] = Self.numbers(color)
            Self.setBorder(d, style)
            return try place(page, d)
        }
        d["Border"] = PdfArray([PdfNumber(0), PdfNumber(0), PdfNumber(0)])
        return try attach(page, d)
    }

    static func union(_ quads: [MarkupQuad]) -> PdfRect {
        var bounds = quads[0].bounds
        for q in quads.dropFirst() {
            let b = q.bounds
            bounds = PdfRect(min(bounds.left, b.left), min(bounds.bottom, b.bottom), max(bounds.right, b.right), max(bounds.top, b.top))
        }
        return bounds
    }
}
