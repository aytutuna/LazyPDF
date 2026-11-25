import Foundation

// Twin of windows/LazyPDF.Core/Editing/ObjectEditor.cs: changes to images and paths and the movement of any object,
// gathered into an `EditBatch`. The text moves are in ObjectEditor.Text.swift, the picture and order changes in
// ObjectEditor.Images.swift.

public enum OrderMove {
    case forward
    case backward
    case front
    case back
}

final class ObjectEditor {
    let model: PageModel
    let batch: EditBatch
    let text: TextEditor

    init(_ model: PageModel, _ batch: EditBatch, _ text: TextEditor) {
        self.model = model
        self.batch = batch
        self.text = text
    }

    var codec: ImageCodec?

    var document: PdfDocument { model.document }

    var changed = 0
    var skipped: [SkippedObject] = []

    // An object that cannot be changed is reported and leaves nothing behind in the batch. The C# method is called Try.
    func attempt(_ o: PageObject, _ change: () throws -> Void) throws {
        let mark = batch.save()
        do {
            try change()
            changed += 1
        } catch let e as EditConflictException {
            batch.restore(mark)
            skipped.append(SkippedObject(id: o.id, reason: e.message))
        }
    }

    static func placeOf(_ o: PageObject) -> Place { Place(o.unit, o.visit) }

    static func bytes(_ text: String) -> [UInt8] { Latin1.bytes(text) }

    static func matrix(_ m: PdfMatrix) -> String { Latin1.string(ContentWriter().concat(m).toArray()) }

    func insert(_ place: Place, _ at: Int, _ text: String) throws {
        if !batch.insert(place, at, Self.bytes(text)) { throw EditConflictException(EditingText.sharedForm) }
    }

    func replace(_ place: Place, _ start: Int, _ end: Int, _ text: String) throws {
        if !batch.replace(place, start, end, Self.bytes(text)) { throw EditConflictException(EditingText.sharedForm) }
    }

    /// Puts `before` in front of operation `first` and `after` behind operation `last`.
    func wrap(_ place: Place, _ first: Int, _ last: Int, _ before: String, _ after: String) throws {
        let ops = place.unit.operations
        try insert(place, ops[first].start, before)
        try insert(place, ops[last].end, after)
    }

    /// The matrix that applies `t` (in user space) at a point of a stream where `ctm` is in force: ctm t ctm^-1.
    static func around(_ ctm: PdfMatrix, _ t: PdfMatrix) throws -> PdfMatrix {
        guard let inverse = ctm.invert() else { throw EditConflictException(EditingText.tooBig) }
        return ctm.multiply(t).multiply(inverse)
    }

    func transform(_ o: PageObject, _ t: PdfMatrix) throws {
        switch o {
        case let image as ImageObject:
            let (first, last) = Self.withCrops(image)
            try wrap(Self.placeOf(o), first, last, "q\n" + Self.matrix(try Self.around(image.placement, t)), "\nQ")
        case let path as PathObject:
            if path.clips { throw EditConflictException(EditingText.clipPath) }
            try wrap(Self.placeOf(o), path.firstOp, path.paintOp, "q\n" + Self.matrix(try Self.around(path.style.ctm, t)), "\nQ")
        case let block as TextObject:
            try transformText(block, t)
        default:
            break
        }
    }

    private static let cropOps = ["q", "m", "l", "l", "l", "h", "W", "n"]

    // A cropped picture sits in the clip Crop wrote round its paint, which has to move with it.
    private static func withCrops(_ image: ImageObject) -> (first: Int, last: Int) {
        let ops = image.unit.operations
        var first = image.op, last = image.op
        while first >= cropOps.count && last + 1 < ops.count && ops[last + 1].operator == "Q"
            && cropOps.enumerated().allSatisfy({ i, name in ops[first - cropOps.count + i].operator == name }) {
            first -= cropOps.count
            last += 1
        }
        return (first, last)
    }

    func delete(_ o: PageObject) throws {
        let place = Self.placeOf(o)
        let ops = o.unit.operations
        switch o {
        case let image as ImageObject:
            try replace(place, ops[image.op].start, ops[image.op].end, "")
        case let path as PathObject:
            // A path that also clips stays as a clip.
            if path.clips {
                try replace(place, ops[path.paintOp].start, ops[path.paintOp].end, "n")
            } else {
                try replace(place, ops[path.firstOp].start, ops[path.paintOp].end, "")
            }
        case let block as TextObject:
            try text.delete(block.range)
        default:
            break
        }
    }

    /// Operators that set the look of a path for the length of the path alone.
    func stylePath(_ path: PathObject, _ fill: RgbColor?, _ stroke: RgbColor?, _ width: Double?) throws {
        if path.clips { throw EditConflictException(EditingText.clipPath) }
        let w = ContentWriter()
        if let f = fill { w.fillRgb(Double(f.r) / 255.0, Double(f.g) / 255.0, Double(f.b) / 255.0) }
        if let s = stroke { w.strokeRgb(Double(s.r) / 255.0, Double(s.g) / 255.0, Double(s.b) / 255.0) }
        if let lw = width { w.lineWidth(lw) }
        try wrap(Self.placeOf(path), path.firstOp, path.paintOp, "q\n" + Latin1.string(w.toArray()), "\nQ")
    }

    func opacity(_ o: PageObject, _ opacity: Double) throws {
        let state = PdfDictionary()
        state["Type"] = PdfName("ExtGState")
        state["ca"] = PdfNumber(opacity)
        state["CA"] = PdfNumber(opacity)
        let place = Self.placeOf(o)
        guard let name = batch.addResource(place, "ExtGState", state) else { throw EditConflictException(EditingText.sharedForm) }
        let before = "q\n" + Latin1.string(ContentWriter().graphicsState(name).toArray())
        switch o {
        case let image as ImageObject:
            try wrap(place, image.op, image.op, before, "\nQ")
        case let path as PathObject:
            if path.clips { throw EditConflictException(EditingText.clipPath) }
            try wrap(place, path.firstOp, path.paintOp, before, "\nQ")
        default:
            throw EditConflictException(EditingText.notAlone)
        }
    }

    /// Shows only the part of the picture inside `area` (user space) by clipping its paint.
    func crop(_ image: ImageObject, _ area: PdfRect) throws {
        let clip = area.intersect(image.bounds)
        if clip.isEmpty { throw EditConflictException(EditingText.tooBig) }
        guard let inverse = image.placement.invert() else { throw EditConflictException(EditingText.tooBig) }
        let w = ContentWriter().save()
        let corners = [(clip.left, clip.bottom), (clip.right, clip.bottom), (clip.right, clip.top), (clip.left, clip.top)]
        for i in 0..<4 {
            // At the paint the picture is the unit square, so the corners go there through the inverse of its placement.
            let (x, y) = inverse.transform(corners[i].0, corners[i].1)
            if i == 0 { w.moveTo(x, y) } else { w.lineTo(x, y) }
        }
        w.close().clip()
        try wrap(Self.placeOf(image), image.op, image.op, Latin1.string(w.toArray()), "\nQ")
    }
}
