import Foundation

// Twin of windows/LazyPDF.Core/Optimize/OptimizeGray.cs: turns colour into gray: the colour operators of every
// content stream and the pixels of the image XObjects. Shadings, spot colours, Lab and patterns have no gray twin
// that keeps their look, so they stay and are counted.
//
// A form takes its colour space from whoever paints it, so the content is simulated twice. The first pass rewrites
// nothing and learns which spaces reach each form; where a form has to keep its operands (a caller's space is a Lab
// or DeviceN one), the callers that would turn their cs gray hold it back.

// Alien is a space of three or more components that gray cannot stand in for, or one that was not found.
private enum Space { case gray, rgb, cmyk, alien, other, inherited }

private struct Origin: Hashable {
    let stream: PdfStream
    let at: Int

    static func == (a: Origin, b: Origin) -> Bool { a.stream === b.stream && a.at == b.at }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(stream))
        hasher.combine(at)
    }
}

private struct Slot: Hashable {
    let space: Space
    let at: Origin?
}

private struct Entry: Equatable {
    let resources: PdfDictionary?
    let fill: Slot
    let stroke: Slot

    static func == (a: Entry, b: Entry) -> Bool { a.resources === b.resources && a.fill == b.fill && a.stroke == b.stroke }
}

private struct FormKey: Hashable {
    let form: PdfStream
    let stroke: Bool

    static func == (a: FormKey, b: FormKey) -> Bool { a.form === b.form && a.stroke == b.stroke }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(form))
        hasher.combine(stroke)
    }
}

private struct Paint: Hashable {
    let key: FormKey
    let slot: Slot
}

private struct Edge {
    let from: PdfStream
    let to: PdfStream
    let stroke: Bool
}

private struct PageRun {
    let resources: PdfDictionary?
    let streams: [PdfStream]
    let straddles: Bool
}

private final class State {
    var fill: Slot
    var stroke: Slot
    var saved: [(Slot, Slot)] = []

    init(_ fill: Slot, _ stroke: Slot) {
        self.fill = fill
        self.stroke = stroke
    }
}

final class OptimizeGray {
    private static let maxPixels = 32_000_000

    private let document: PdfDocument
    private let codec: ImageCodec?
    private let jpegQuality: Int

    // Component counts of the Lab and DeviceN spaces in the file that an operand count could be mistaken for RGB or CMYK.
    private var alien = Set<Int>()

    // Colour operators that stay as written, because a form or a shared stream needs the space they set.
    private var held = Set<Origin>()
    private var frozen = Set<ObjectIdentifier>()
    private var simulated = Set<ObjectIdentifier>()
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var output: [ObjectIdentifier: (stream: PdfStream, data: [UInt8])] = [:]
    private var outputOrder: [ObjectIdentifier] = []
    private var maskUsers: [ObjectIdentifier: Int] = [:]

    // Learned by the first pass. An edge is a form painted while its own colour was still its caller's; a paint is
    // a form painted in a space some operator set. Callers hold the spaces that reach a form, for fill or stroke.
    private var edges: [Edge] = []
    private var paints = Set<Paint>()
    private var consumers = Set<FormKey>()
    private var callers: [FormKey: Set<Space>] = [:]
    private var analysing = false

    private(set) var streams = 0
    private(set) var images = 0
    private(set) var left = 0
    private(set) var needsCodec = false

    init(_ document: PdfDocument, _ codec: ImageCodec?, _ jpegQuality: Int) {
        self.document = document
        self.codec = codec
        self.jpegQuality = jpegQuality
    }

    func run() {
        for dictionary in PdfGraph.allDictionaries(document) {
            for (_, space) in document.dict(dictionary, "ColorSpace")?.entries ?? [] {
                let (family, components) = ImageKit.describe(document, space)
                if (family == .lab || family == .spot) && components >= 3 { alien.insert(components) }
            }
        }
        var pages: [PageRun] = []
        var used = Set<ObjectIdentifier>()
        for page in document.pages {
            let contents = document.resolve(page.dictionary["Contents"])
            let items: [PdfObject] = (contents as? PdfArray)?.items ?? [contents ?? PdfNull.instance]
            let list = items.compactMap { document.resolve($0) as? PdfStream }
            let straddles = self.straddles(list)
            if straddles { for s in list { frozen.insert(ObjectIdentifier(s)) } }
            for s in list { used.insert(ObjectIdentifier(s)) }
            pages.append(PageRun(resources: page.resources, streams: list, straddles: straddles))
        }
        let all = PdfGraph.objects(document).compactMap { $0.value as? PdfStream }
        let forms = all.filter {
            !used.contains(ObjectIdentifier($0)) && OptimizeWalk.isForm(document, $0) && document.integer($0.dictionary, "PaintType") != 2
        }
        for stream in all {
            if let soft = document.resolve(stream.dictionary["SMask"]) as? PdfStream { maskUsers[ObjectIdentifier(soft), default: 0] += 1 }
        }

        analysing = true
        pass(pages, forms)
        settle()
        analysing = false
        left = 0
        pass(pages, forms)
        for id in outputOrder {
            guard let written = output[id] else { continue }
            PdfGraph.setData(written.stream, written.data)
            streams += 1
        }
        for stream in all {
            let dictionary = stream.dictionary
            if document.integer(dictionary, "PatternType") == 2 {
                left += 1
            } else if document.name(dictionary, "Subtype") == "Image" && document.bool(dictionary, "ImageMask") != true {
                grayImage(stream)
            }
        }
    }

    private func pass(_ pages: [PageRun], _ forms: [PdfStream]) {
        for page in pages {
            if page.straddles {
                left += 1
                continue
            }
            let state = State(Slot(space: .gray, at: nil), Slot(space: .gray, at: nil))
            for stream in page.streams {
                if analysing { noteContext(stream, Entry(resources: page.resources, fill: state.fill, stroke: state.stroke)) }
                let again = !analysing && !simulated.insert(ObjectIdentifier(stream)).inserted
                let before = left
                convert(stream, page.resources, state)
                // A stream on several pages is run for each page's state but counted once.
                if again { left = before }
            }
        }
        for form in forms {
            let inherited = Slot(space: .inherited, at: nil)
            convert(form, document.dict(form.dictionary, "Resources"), State(inherited, inherited))
        }
    }

    // A stream shared by pages is rewritten once, so it must read the same on each: the same resources and the
    // same colour spaces coming in. Otherwise it stays as it is, and so do the operators that set what it takes in.
    private func noteContext(_ stream: PdfStream, _ entry: Entry) {
        let id = ObjectIdentifier(stream)
        if let known = entries[id] {
            if known != entry && frozen.insert(id).inserted { hold(known) }
        } else {
            entries[id] = entry
        }
        if frozen.contains(id) { hold(entry) }
    }

    private func hold(_ entry: Entry) {
        if let fill = entry.fill.at { held.insert(fill) }
        if let stroke = entry.stroke.at { held.insert(stroke) }
    }

    private func settle() {
        var calls: [FormKey: [PdfStream]] = [:]
        var called: [FormKey: [PdfStream]] = [:]
        for e in edges {
            calls[FormKey(form: e.from, stroke: e.stroke), default: []].append(e.to)
            called[FormKey(form: e.to, stroke: e.stroke), default: []].append(e.from)
        }
        var work = paints.map { (key: $0.key, space: $0.slot.space) }
        var next = 0
        while next < work.count {
            let (key, space) = work[next]
            next += 1
            if !callers[key, default: []].insert(space).inserted { continue }
            for to in calls[key] ?? [] { work.append((FormKey(form: to, stroke: key.stroke), space)) }
        }
        // A form that keeps its operands holds back every caller on the way to it that would rewrite its cs.
        var keeping = consumers.filter { callers[$0]?.contains(.alien) == true }
        var reaching = Set<FormKey>()
        while let key = keeping.popFirst() {
            if !reaching.insert(key).inserted { continue }
            for from in called[key] ?? [] { keeping.insert(FormKey(form: from, stroke: key.stroke)) }
        }
        for paint in paints {
            if let at = paint.slot.at, paint.slot.space == .rgb || paint.slot.space == .cmyk, reaching.contains(paint.key) { held.insert(at) }
        }
    }

    // Whether an operand-counted colour in a form stays: its callers include a Lab or DeviceN space, or none is known and the file holds one that size.
    private func keeps(_ form: PdfStream, _ stroke: Bool, _ operands: Int) -> Bool {
        let spaces = callers[FormKey(form: form, stroke: stroke)] ?? []
        return spaces.contains(.alien) || (!spaces.contains(.rgb) && !spaces.contains(.cmyk) && alien.contains(operands))
    }

    // An operator may sit in a later stream than its operands (7.8.2), and each stream is rewritten on its own.
    private func straddles(_ streams: [PdfStream]) -> Bool {
        if streams.count < 2 { return false }
        var joined: [UInt8] = []
        var ends: [Int] = []
        do {
            for stream in streams {
                joined += try document.data(stream)
                ends.append(joined.count)
                joined.append(UInt8(ascii: "\n"))
            }
        } catch {
            return false
        }
        for op in ContentParser.parse(joined) {
            var at = Self.binarySearch(ends, op.start)
            at = at < 0 ? ~at : at + 1
            if at < ends.count && op.end > ends[at] { return true }
        }
        return false
    }

    // List<int>.BinarySearch: with equal values (an empty stream) the index it lands on is the one that decides.
    private static func binarySearch(_ sorted: [Int], _ value: Int) -> Int {
        var lo = 0
        var hi = sorted.count - 1
        while lo <= hi {
            let i = lo + ((hi - lo) >> 1)
            if sorted[i] == value { return i }
            if sorted[i] < value { lo = i + 1 } else { hi = i - 1 }
        }
        return ~lo
    }

    private func convert(_ stream: PdfStream, _ resources: PdfDictionary?, _ state: State) {
        let data: [UInt8]
        let operations: [ContentOperation]
        do {
            data = try document.data(stream)
            operations = ContentParser.parse(data)
        } catch {
            return
        }
        var result: [UInt8] = []
        var copied = 0
        var changed = false
        let isFrozen = frozen.contains(ObjectIdentifier(stream))
        func replace(_ op: ContentOperation, _ text: String) {
            if analysing || isFrozen || op.start < copied || op.end > data.count { return }
            result += data[copied..<op.start]
            result += Latin1.bytes(text)
            copied = op.end
            changed = true
        }

        // The state keeps the space the operands are written for, which the colours that follow still need. An
        // operator that cannot be rewritten leaves its space as it was, and so everything written for it.
        func setSlot(_ op: ContentOperation, _ space: Space, _ replacement: String?) -> Slot {
            let at = Origin(stream: stream, at: op.start)
            if (space == .rgb || space == .cmyk) && !analysing && (replacement == nil || isFrozen || held.contains(at)) {
                left += 1
                return Slot(space: .alien, at: at)
            }
            if let replacement { replace(op, replacement) }
            return Slot(space: space, at: at)
        }

        for op in operations {
            switch op.operator {
            case "q":
                state.saved.append((state.fill, state.stroke))
            case "Q":
                if let (fill, stroke) = state.saved.popLast() {
                    state.fill = fill
                    state.stroke = stroke
                }
            case "g", "rg", "k", "G", "RG", "K":
                let letter = op.operator.unicodeScalars.first?.value ?? 0
                let stroke = letter >= 65 && letter <= 90
                let kind = letter | 0x20
                let model: Space = kind == 0x67 ? .gray : kind == 0x72 ? .rgb : .cmyk
                let level = model == .gray ? nil : Self.gray(op, model == .rgb ? 3 : 4)
                let slot = setSlot(op, model, level.map { "\(Self.format($0)) \(stroke ? "G" : "g")" })
                if stroke { state.stroke = slot } else { state.fill = slot }
            case "cs", "CS":
                let space = spaceOf(op, resources)
                let slot = setSlot(op, space, space == .rgb || space == .cmyk ? "/DeviceGray \(op.operator)" : nil)
                if op.operator == "cs" { state.fill = slot } else { state.stroke = slot }
            case "sc", "scn", "SC", "SCN":
                let upper = (op.operator.unicodeScalars.first?.value ?? 0) <= 90
                let current = (upper ? state.stroke : state.fill).space
                let inherited = current == .inherited
                let count = op.operands.count
                let needed = current == .rgb || (inherited && count == 3) ? 3 : current == .cmyk || (inherited && count == 4) ? 4 : 0
                guard needed != 0, op.operands.allSatisfy({ $0 is PdfNumber }), let shade = Self.gray(op, needed) else { break }
                if !inherited {
                    replace(op, "\(Self.format(shade)) \(op.operator)")
                } else if analysing {
                    consumers.insert(FormKey(form: stream, stroke: upper))
                } else if keeps(stream, upper, needed) {
                    left += 1
                } else {
                    // g and G set their own space; the state stays inherited so the next colour is judged the same way.
                    replace(op, "\(Self.format(shade)) \(upper ? "G" : "g")")
                }
            case "Do":
                guard analysing, let xobject = op.operands.first as? PdfName,
                      let form = document.resolve(document.dict(resources, "XObject")?[xobject.value]) as? PdfStream else { break }
                for stroke in [false, true] {
                    let heldSlot = stroke ? state.stroke : state.fill
                    if heldSlot.space == .inherited {
                        edges.append(Edge(from: stream, to: form, stroke: stroke))
                    } else {
                        paints.insert(Paint(key: FormKey(form: form, stroke: stroke), slot: heldSlot))
                    }
                }
            case "sh":
                left += 1
            case "BI":
                if let image = op.image, !Self.isGrayInline(image) { left += 1 }
            default:
                break
            }
        }
        if !changed { return }
        result += data[copied...]
        let id = ObjectIdentifier(stream)
        if output[id] == nil {
            output[id] = (stream, result)
            outputOrder.append(id)
        }
    }

    private static func isGrayInline(_ image: InlineImage) -> Bool {
        if let name = (image.dictionary["CS"] ?? image.dictionary["ColorSpace"]) as? PdfName, name.value == "G" || name.value == "DeviceGray" { return true }
        return (image.dictionary["IM"] as? PdfBoolean)?.value == true || (image.dictionary["ImageMask"] as? PdfBoolean)?.value == true
    }

    private static func format(_ value: Double) -> String { PdfNumber(Swift.min(Swift.max(value, 0), 1)).text }

    // Luminance of the last n operands as RGB, or of CMYK taken the way the filters do (1 - c)(1 - k).
    private static func gray(_ op: ContentOperation, _ n: Int) -> Double? {
        if op.operands.count < n { return nil }
        var v: [Double] = []
        for i in 0..<n {
            guard let number = op.operands[op.operands.count - n + i] as? PdfNumber else { return nil }
            v.append(Swift.min(Swift.max(number.value, 0), 1))
        }
        return luminance(v)
    }

    private static func luminance(_ v: [Double]) -> Double {
        switch v.count {
        case 1: return v[0]
        case 3: return 0.299 * v[0] + 0.587 * v[1] + 0.114 * v[2]
        case 4: return (1 - v[3]) * (1 - (0.299 * v[0] + 0.587 * v[1] + 0.114 * v[2]))
        default: return v.first ?? 0
        }
    }

    // The matte is a colour in the image's space, so it follows the image to gray. Looked up before the
    // image changes: an indexed image's matte is a palette index (11.6.5.3).
    private func matteGray(_ image: PdfDictionary, _ family: ImageFamily, _ components: Int) -> Double? {
        guard let soft = document.resolve(image["SMask"]) as? PdfStream, let matte = document.array(soft.dictionary, "Matte"),
              matte.items.count == components else { return nil }
        let values = matte.items.map { (document.resolve($0) as? PdfNumber)?.value ?? 0 }
        if family != .indexed { return Self.luminance(values.map { Swift.min(Swift.max($0, 0), 1) }) }
        let entry = image.copy()
        for key in ["SMask", "Mask", "Decode"] { entry.remove(key) }
        let one = PdfNumber(1)
        entry["Width"] = one
        entry["Height"] = one
        entry["BitsPerComponent"] = PdfNumber(8)
        let index = values.first ?? 0
        let sample = UInt8(index > 0 ? Swift.min(index, 255) : 0)
        do {
            let pixel = try PdfImageSamples.toRgba(entry, [sample], { self.document.resolve($0) }, { try self.document.data($0) }).rgba
            if pixel.count < 3 { return nil }
            return Double(ImageKit.luminance(Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))) / 255.0
        } catch {
            return nil
        }
    }

    // The matte has one value per component of the image it belongs to, so a mask that two images use cannot follow just one of them.
    private func sharesMatte(_ image: PdfDictionary) -> Bool {
        guard let soft = document.resolve(image["SMask"]) as? PdfStream else { return false }
        return soft.dictionary.containsKey("Matte") && (maskUsers[ObjectIdentifier(soft)] ?? 0) > 1
    }

    private func setMatte(_ image: PdfDictionary, _ gray: Double, _ components: Int) {
        guard let soft = document.resolve(image["SMask"]) as? PdfStream else { return }
        soft.dictionary["Matte"] = PdfArray((0..<components).map { _ in PdfNumber(gray) })
    }

    private func spaceOf(_ op: ContentOperation, _ resources: PdfDictionary?) -> Space {
        guard let name = op.operands.first as? PdfName else { return .other }
        var definition: PdfObject? = name
        if !["DeviceGray", "DeviceRGB", "DeviceCMYK", "Pattern"].contains(name.value) {
            definition = document.resolve(document.dict(resources, "ColorSpace")?[name.value])
            if definition == nil {
                // The colour stays whatever space the caller meant by the name.
                left += 1
                return .alien
            }
        }
        if name.value == "Pattern" { return .other }
        if let array = definition as? PdfArray, let first = document.resolve(array.items.first) as? PdfName, first.value == "Pattern" { return .other }
        let (family, components) = ImageKit.describe(document, definition)
        if family == .spot || family == .lab { left += 1 }
        switch family {
        case .gray: return .gray
        case .rgb: return .rgb
        case .cmyk: return .cmyk
        case .unknown: return .alien
        default: return components >= 3 ? .alien : .other
        }
    }

    // (int) of a long in an unchecked context keeps the low 32 bits.
    private func size(_ dictionary: PdfDictionary?, _ key: String) -> Int {
        Int(Int32(truncatingIfNeeded: document.integer(dictionary, key) ?? 0))
    }

    private func grayImage(_ stream: PdfStream) {
        let dictionary = stream.dictionary
        let (family, components) = ImageKit.describe(document, dictionary["ColorSpace"])
        if family == .gray || family == .unknown { return }
        let width = size(dictionary, "Width")
        let height = size(dictionary, "Height")
        if family == .spot || family == .lab || width < 1 || height < 1 || width * height > Self.maxPixels
            || document.resolve(dictionary["Mask"]) is PdfArray || sharesMatte(dictionary) {
            left += 1
            return
        }
        let (filter, parameters, _) = document.decodeSpec(stream)
        let pixels: PdfRgbaImage
        let coded: String?
        do {
            let decoded = try PdfFilters.decodeToCodec(document.rawData(stream), filter, parameters)
            coded = decoded.codec
            if coded == nil {
                let plain = dictionary.copy()
                plain.remove("SMask")
                plain.remove("Mask")
                pixels = try PdfImageSamples.toRgba(plain, decoded.data, { self.document.resolve($0) }, { try self.document.data($0) })
            } else if let name = coded, name == "DCTDecode" || name == "JPXDecode", !dictionary.containsKey("Decode"),
                      let codec, let image = codec.decode(decoded.data, name) {
                pixels = image
            } else {
                if let name = coded, name == "DCTDecode" || name == "JPXDecode", codec == nil { needsCodec = true }
                left += 1
                return
            }
        } catch {
            left += 1
            return
        }
        if pixels.width < 1 || pixels.height < 1 || pixels.width > pixels.rgba.count / 4 / pixels.height {
            left += 1
            return
        }
        let count = pixels.width * pixels.height
        if pixels.rgba.count < count * 4 {
            left += 1
            return
        }
        let matte = matteGray(dictionary, family, components)
        var gray = Array(repeating: UInt8(0), count: count)
        for i in 0..<count { gray[i] = ImageKit.luminance(Int(pixels.rgba[4 * i]), Int(pixels.rgba[4 * i + 1]), Int(pixels.rgba[4 * i + 2])) }
        var jpeg: [UInt8] = []
        if coded != nil, let codec {
            var rgba = Array(repeating: UInt8(255), count: count * 4)
            for i in 0..<count {
                rgba[4 * i] = gray[i]
                rgba[4 * i + 1] = gray[i]
                rgba[4 * i + 2] = gray[i]
            }
            jpeg = codec.encodeJpeg(PdfRgbaImage(pixels.width, pixels.height, rgba), Swift.min(Swift.max(jpegQuality, 1), 100))
        }
        // A picture the codec cannot write goes in as Flate gray instead of an empty stream.
        let asJpeg = !jpeg.isEmpty
        if asJpeg {
            stream.data = jpeg
            dictionary["Filter"] = PdfName("DCTDecode")
            dictionary["ColorSpace"] = PdfName("DeviceRGB")
        } else {
            stream.data = PdfFilterEncoders.flate(gray, .smallestSize)
            dictionary["Filter"] = PdfName("FlateDecode")
            dictionary["ColorSpace"] = PdfName("DeviceGray")
        }
        if coded != nil {
            dictionary["Width"] = PdfNumber(pixels.width)
            dictionary["Height"] = PdfNumber(pixels.height)
        }
        dictionary["BitsPerComponent"] = PdfNumber(8)
        dictionary.remove("DecodeParms")
        dictionary.remove("Decode")
        if let matte { setMatte(dictionary, matte, asJpeg ? 3 : 1) }
        images += 1
    }
}
