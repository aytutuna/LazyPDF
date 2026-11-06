import Foundation

// Twin of windows/LazyPDF.Core/Editing/PageEditor.Objects.cs: moving, transforming, deleting and restyling the objects
// of a page, and taking a picture out.

extension PageEditor {
    /// Moves objects by (dx, dy) in user space with a matrix round each, leaving their coordinates as they are.
    public func move(_ objects: [PageObject], _ dx: Double, _ dy: Double) throws -> ObjectEditResult {
        try transform(objects, PdfMatrix.translate(dx, dy), "Move")
    }

    /// Applies a user space transformation to each object.
    public func transform(_ objects: [PageObject], _ matrix: PdfMatrix, _ label: String = "Transform") throws -> ObjectEditResult {
        try editObjects(label, objects) { editor, o in try editor.transform(o, matrix) }
    }

    /// Scales the objects together so that the box around them becomes `bounds`.
    public func resize(_ objects: [PageObject], _ bounds: PdfRect) throws -> ObjectEditResult {
        guard let first = objects.first else { return ObjectEditResult(0, []) }
        let box = Self.union(objects)
        if box.isEmpty || bounds.isEmpty { return ObjectEditResult(0, [SkippedObject(id: first.id, reason: EditingText.tooBig)]) }
        let t = PdfMatrix.translate(-box.left, -box.bottom)
            .multiply(PdfMatrix.scale(bounds.width / box.width, bounds.height / box.height))
            .multiply(PdfMatrix.translate(bounds.left, bounds.bottom))
        return try transform(objects, t, "Resize")
    }

    /// Turns the objects together about the centre of the box around them, counter-clockwise.
    public func rotate(_ objects: [PageObject], _ degrees: Double) throws -> ObjectEditResult {
        if objects.isEmpty { return ObjectEditResult(0, []) }
        let box = Self.union(objects)
        let cx = (box.left + box.right) / 2, cy = (box.bottom + box.top) / 2
        let r = degrees * Double.pi / 180, cos = Foundation.cos(r), sin = Foundation.sin(r)
        let t = PdfMatrix.translate(-cx, -cy).multiply(PdfMatrix(cos, sin, -sin, cos, 0, 0)).multiply(PdfMatrix.translate(cx, cy))
        return try transform(objects, t, "Rotate")
    }

    /// Mirrors the objects together across the vertical (`horizontal`) or horizontal middle line of the box around them.
    public func flip(_ objects: [PageObject], _ horizontal: Bool) throws -> ObjectEditResult {
        if objects.isEmpty { return ObjectEditResult(0, []) }
        let box = Self.union(objects)
        let cx = (box.left + box.right) / 2, cy = (box.bottom + box.top) / 2
        let t = PdfMatrix.translate(-cx, -cy).multiply(horizontal ? PdfMatrix.scale(-1, 1) : PdfMatrix.scale(1, -1)).multiply(PdfMatrix.translate(cx, cy))
        return try transform(objects, t, "Flip")
    }

    private static func union(_ list: [PageObject]) -> PdfRect {
        PdfRect(list.map { $0.bounds.left }.min() ?? 0, list.map { $0.bounds.bottom }.min() ?? 0,
                list.map { $0.bounds.right }.max() ?? 0, list.map { $0.bounds.top }.max() ?? 0)
    }

    /// Takes the objects off the page. Text goes the way `deleteText` takes it.
    public func delete(_ objects: [PageObject]) throws -> ObjectEditResult {
        try editObjects("Delete", objects) { editor, o in try editor.delete(o) }
    }

    /// Shows only the part of the picture inside `area`; the file keeps the whole picture.
    public func crop(_ image: ImageObject, _ area: PdfRect) throws -> ObjectEditResult {
        try editObjects("Crop", [image]) { editor, o in
            if let each = o as? ImageObject { try editor.crop(each, area) }
        }
    }

    /// Puts another picture where this one is. JPEG data is embedded as it is; other files go
    /// through the editor's `ImageCodec`. With `fit` the new picture keeps its proportions inside the old place, else it fills it.
    public func replaceImage(_ image: ImageObject, _ file: [UInt8], _ fit: Bool = true) throws -> ObjectEditResult {
        try editObjects("Replace picture", [image]) { editor, o in
            if let each = o as? ImageObject { try editor.replaceImage(each, file, fit) }
        }
    }

    /// Paints images and paths at the given opacity, 0 to 1.
    public func setOpacity(_ objects: [PageObject], _ opacity: Double) throws -> ObjectEditResult {
        try editObjects("Opacity", objects) { editor, o in try editor.opacity(o, Swift.min(Swift.max(opacity, 0), 1)) }
    }

    /// Moves an image or path one step or all the way in front of or behind the other things painted next to it. It has to sit in a q ... Q of its own.
    public func order(_ o: PageObject, _ move: OrderMove) throws -> ObjectEditResult {
        try editObjects("Arrange", [o]) { editor, x in try editor.order(x, move) }
    }

    /// Recolours the fill or the stroke and sets the line width of paths; nil leaves a value as it is.
    public func setPathStyle(_ paths: [PathObject], fill: RgbColor? = nil, stroke: RgbColor? = nil, lineWidth: Double? = nil) throws -> ObjectEditResult {
        try editObjects("Path style", paths) { editor, o in
            if let each = o as? PathObject { try editor.stylePath(each, fill, stroke, lineWidth) }
        }
    }

    /// The bytes of a picture: JPEG and JPEG 2000 data as stored, everything else as a PNG. Nil when it cannot be read.
    public func extractImage(_ image: ImageObject) throws -> ExtractedImage? {
        let model = try self.model
        let batch = EditBatch(model.document, model.page, model.scan)
        let editor = ObjectEditor(model, batch, TextEditor(model, batch, TextBuilder(model.document, batch, fonts), fonts))
        editor.codec = codec
        do {
            return try editor.extract(image)
        } catch is EditConflictException {
            return nil
        }
    }

    private func editObjects(_ label: String, _ objects: [PageObject], _ change: (ObjectEditor, PageObject) throws -> Void) throws -> ObjectEditResult {
        let model = try self.model
        let batch = EditBatch(model.document, model.page, model.scan)
        let builder = TextBuilder(model.document, batch, fonts)
        let editor = ObjectEditor(model, batch, TextEditor(model, batch, builder, fonts))
        editor.codec = codec
        for o in objects {
            if o.id < 0 || o.id >= model.objects.count || model.objects[o.id] !== o { throw ArgumentException(EditingText.staleObject) }
            try editor.attempt(o) { try change(editor, o) }
        }
        if editor.changed == 0 {
            batch.discard()
            return ObjectEditResult(0, editor.skipped)
        }
        do {
            try batch.apply()
            builder.writeAdditions()
        } catch let e as EditConflictException {
            batch.discard()
            return ObjectEditResult(0, editor.skipped + [SkippedObject(id: -1, reason: e.message)])
        }
        try commit(label)
        return ObjectEditResult(editor.changed, editor.skipped)
    }
}
