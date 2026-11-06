import Foundation

// Twin of windows/LazyPDF.Core/Editing/ObjectEditor.Images.cs: putting another picture where one is, taking a picture
// out of the file, and moving an image or path in front of or behind its neighbours.

/// A picture taken out of the file: its bytes and the extension of the file they make. The C# member is called Extension.
public struct ExtractedImage: Equatable {
    public let data: [UInt8]
    public let fileExtension: String

    public init(_ data: [UInt8], _ fileExtension: String) {
        self.data = data
        self.fileExtension = fileExtension
    }
}

extension ObjectEditor {
    /// Whether a decoded frame is one `PdfImageWriter.addRgba` takes; a codec promises no size limit.
    static func fits(_ frame: PdfRgbaImage) -> Bool {
        if frame.width <= 0 || frame.height <= 0 { return false }
        let (area, overflow) = frame.width.multipliedReportingOverflow(by: frame.height)
        return !overflow && area <= PdfImageSamples.maxPixels && frame.rgba.count == area * 4
    }

    /// The image `file` holds, added to the document: JPEG data as it is, anything else through `codec`.
    static func addPicture(_ document: PdfDocument, _ file: [UInt8], _ codec: ImageCodec?) throws -> PdfImage? {
        var added: PdfImage?
        if file.count > 2 && file[0] == 0xFF && file[1] == 0xD8 { added = try PdfImageWriter.addJpeg(document, file) }
        if added == nil, let frame = codec?.decodeFile(file)?.first, fits(frame) {
            added = try PdfImageWriter.addRgba(document, frame.width, frame.height, frame.rgba)
        }
        return added
    }

    /// Paints another picture where the object is, fitted inside its place with the proportions of the new one.
    func replaceImage(_ image: ImageObject, _ file: [UInt8], _ fit: Bool) throws {
        guard let added = try Self.addPicture(document, file, codec) else { throw EditConflictException(EditingText.noImage) }
        let place = Self.placeOf(image)
        guard let name = batch.addResource(place, "XObject", added.reference) else { throw EditConflictException(EditingText.sharedForm) }
        let w = ContentWriter()
        let p = image.placement
        let across = (p.a * p.a + p.b * p.b).squareRoot()
        let down = (p.c * p.c + p.d * p.d).squareRoot()
        if fit && across > 0 && down > 0 {
            let shape = Double(added.width) / Double(added.height), room = across / down
            let inside = shape > room ? PdfMatrix(1, 0, 0, room / shape, 0, (1 - room / shape) / 2) : PdfMatrix(shape / room, 0, 0, 1, (1 - shape / room) / 2, 0)
            w.save().concat(inside).paint(name).restore()
        } else {
            w.paint(name)
        }
        let op = image.unit.operations[image.op]
        var drawn = w.toArray()
        while drawn.last == 10 { drawn.removeLast() }
        try replace(place, op.start, op.end, Latin1.string(drawn))
    }

    /// The bytes of the picture: a JPEG or JPEG 2000 file as it is stored, anything else as a PNG.
    func extract(_ image: ImageObject) throws -> ExtractedImage {
        if let inline = image.info.inline {
            return try encode(image.info.dictionary, inline.data)
        }
        guard let stream = image.info.stream else { throw EditConflictException(EditingText.noImage) }
        return try encode(stream.dictionary, document.rawData(stream))
    }

    private func encode(_ dictionary: PdfDictionary, _ raw: [UInt8]) throws -> ExtractedImage {
        do {
            let filter = document.resolve(dictionary["Filter"] ?? dictionary["F"])
            let parms = document.resolve(dictionary["DecodeParms"] ?? dictionary["DP"])
            let decoded = try PdfFilters.decodeToCodec(raw, filter, parms)
            switch decoded.codec ?? "" {
            case "DCTDecode":
                return ExtractedImage(decoded.data, "jpg")
            case "JPXDecode":
                return ExtractedImage(decoded.data, "jp2")
            case "JBIG2Decode":
                if let bits = codec?.decode(decoded.data, "JBIG2Decode") { return ExtractedImage(try PngWriter.encode(bits), "png") }
            default:
                let rgba = try PdfImageSamples.toRgba(dictionary, decoded.data, { self.document.resolve($0) }, { try self.document.data($0) })
                return ExtractedImage(try PngWriter.encode(rgba), "png")
            }
        } catch is PdfReadException {
        }
        throw EditConflictException(EditingText.noImage)
    }

    /// Moves a picture or path in front of or behind the next object in the stream, when it sits in a q ... Q of its own.
    func order(_ o: PageObject, _ move: OrderMove) throws {
        let unit = o.unit
        let place = Self.placeOf(o)
        let ops = unit.operations
        let states = unit.states
        let paint: Int
        let first: Int
        if let image = o as? ImageObject {
            paint = image.op
            first = paint
        } else if let path = o as? PathObject {
            paint = path.paintOp
            first = path.firstOp
        } else {
            throw EditConflictException(EditingText.notAlone)
        }
        var d = states.at(first).depth
        if d == 0 { throw EditConflictException(EditingText.notAlone) }
        var open = -1
        var j = first - 1
        while j >= 0 {
            if states.at(j).depth < d {
                open = j
                break
            }
            j -= 1
        }
        var close = Self.closing(unit, paint + 1, d)
        if open < 0 || ops[open].operator != "q" || close < 0 { throw EditConflictException(EditingText.notAlone) }
        if (open + 1..<close).filter({ Self.isPainting(ops[$0]) }).count != 1 { throw EditConflictException(EditingText.notAlone) }

        var siblings: [(first: Int, last: Int)] = []
        var me = -1
        while true {
            var parentStart = 0, parentEnd = ops.count
            if d > 1 {
                var k = open - 1
                while k >= 0 {
                    if states.at(k).depth < d - 1 {
                        parentStart = k + 1
                        break
                    }
                    k -= 1
                }
                let end = Self.closing(unit, close + 1, d - 1)
                if end >= 0 { parentEnd = end }
            }
            siblings = Self.siblingsOf(unit, d - 1, parentStart, parentEnd)
            me = siblings.firstIndex { $0.first == open } ?? -1
            // A group that is all its parent holds moves with the parent.
            if siblings.count == 1 && d > 1 && parentStart > 0 && parentEnd < ops.count && ops[parentStart - 1].operator == "q" {
                (open, close) = (parentStart - 1, parentEnd)
                d -= 1
                continue
            }
            break
        }
        let target: Int
        switch move {
        case .forward: target = me + 1
        case .backward: target = me - 1
        case .front: target = siblings.count - 1
        case .back: target = 0
        }
        if me < 0 || target == me || target < 0 || target >= siblings.count { throw EditConflictException(EditingText.alreadyThere) }
        let after = target > me
        if !(after ? Self.crossable(place, close + 1, siblings[target].last) : Self.crossable(place, siblings[target].first, open - 1)) {
            throw EditConflictException(EditingText.stateBetween)
        }
        let at = after ? ops[siblings[target].last].end : ops[siblings[target].first].start
        let group = Latin1.string(Array(unit.data[ops[open].start..<ops[close].end]))
        try replace(place, ops[open].start, ops[close].end, "")
        try insert(place, at, after ? "\n" + group : group + "\n")
    }

    // Operators that only build or paint: a group can jump over them. A setting or clip it would meet, or
    // marked content it would leave, changes how it is drawn and which layer or structure element owns it (8.4, 14.6).
    private static let inert: Set<String> = [
        "m", "l", "c", "v", "y", "h", "re", "S", "s", "f", "F", "f*", "B", "B*", "b", "b*", "n", "Do", "sh", "BI",
        "BT", "ET", "Td", "TD", "Tm", "T*", "Tj", "TJ", "'", "\"", "Tf", "Tc", "Tw", "Tz", "TL", "Tr", "Ts", "MP", "DP",
    ]

    private static let pathBuilders: Set<String> = ["m", "l", "c", "v", "y", "h", "re", "W", "W*"]

    private static func crossable(_ place: Place, _ from: Int, _ to: Int) -> Bool {
        let unit = place.unit
        let states = place.states
        let ops = unit.operations
        var i = from
        while i <= to && i < ops.count {
            if ops[i].operator == "q" {
                i = closing(unit, i + 1, states.at(i).depth + 1)
                if i < 0 { return false }
            } else if !inert.contains(ops[i].operator) || addsToClip(unit, states, i) {
                return false
            }
            i += 1
        }
        return true
    }

    // Text shown in render mode 4 to 7 joins the clip at ET (9.3.6), so a group moved past it is clipped differently.
    // The mode is the one of this painting of the stream: a form painted twice inherits a different Tr at each Do.
    private static func addsToClip(_ unit: ContentUnit, _ states: OpStates, _ index: Int) -> Bool {
        let op = unit.operations[index].operator
        guard op == "Tj" || op == "TJ" || op == "'" || op == "\"" else { return false }
        guard let mode = states.at(index).mode, mode.operands.count == 1, let number = mode.operands[0] as? PdfNumber else { return false }
        return number.value >= 4 && number.value <= 7
    }

    private static func closing(_ unit: ContentUnit, _ from: Int, _ depth: Int) -> Int {
        var k = Swift.max(from, 0)
        while k < unit.operations.count {
            if unit.operations[k].operator == "Q" && unit.states.at(k).depth == depth { return k }
            k += 1
        }
        return -1
    }

    // The things painted at one level of q nesting, in order, as ranges of operations.
    private static func siblingsOf(_ unit: ContentUnit, _ level: Int, _ from: Int, _ to: Int) -> [(first: Int, last: Int)] {
        let ops = unit.operations
        let states = unit.states
        var found: [(first: Int, last: Int)] = []
        var i = from
        while i < to {
            if states.at(i).depth != level {
                i += 1
                continue
            }
            let op = ops[i].operator
            if op == "q" {
                let m = closing(unit, i + 1, level + 1)
                if m < 0 || m >= to { break }
                if (i + 1..<m).contains(where: { isPainting(ops[$0]) }) { found.append((i, m)) }
                i = m
            } else if op == "BT" {
                var e = i + 1
                while e < to && ops[e].operator != "ET" { e += 1 }
                if (i + 1..<e).contains(where: { isPainting(ops[$0]) }) { found.append((i, Swift.min(e, to - 1))) }
                i = e
            } else if isPainting(ops[i]) && op != "Tj" && op != "TJ" && op != "'" && op != "\"" {
                var start = i
                while start > from && pathBuilders.contains(ops[start - 1].operator) { start -= 1 }
                found.append((start, i))
            }
            i += 1
        }
        return found
    }
}
