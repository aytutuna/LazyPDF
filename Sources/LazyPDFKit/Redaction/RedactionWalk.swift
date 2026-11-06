import Foundation

// Twin of windows/LazyPDF.Core/Redaction/RedactionWalk.cs: follows a page and everything it paints to the end, by the
// strictest reading, and records what it painted. A page with marks is redacted in place only when this finds nothing it
// cannot account for: content that does not parse whole, operators or operands outside `RedactionSyntax`, an inline image
// whose end is open to doubt, a name a viewer may resolve differently, a form that reaches itself, limits the interpreter
// stops at without saying so, and Type 3 glyphs that paint anything but shapes and bitmaps. What a viewer may draw from such
// content is never looked at by the scan, so the page is flattened instead.

/// A name in a resource list, the list taken by identity.
struct ListName: Hashable {
    let list: PdfDictionary
    let name: String

    init(_ list: PdfDictionary, _ name: String) {
        self.list = list
        self.name = name
    }

    static func == (a: ListName, b: ListName) -> Bool { a.list === b.list && a.name == b.name }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(list))
        hasher.combine(name)
    }
}

final class RedactionWalk {
    /// The nesting at which the interpreter stops entering forms.
    static let formDepth = 20

    private static let fontKinds = ["Type1", "MMType1", "TrueType", "Type3", "Type0"]
    private static let cidKinds = ["CIDFontType0", "CIDFontType2"]
    private static let notInText = Set("q Q cm m l c v y h re S s f F f* B B* b b* n W W* sh Do BI d0 d1 BT".split(separator: " ").map(String.init))
    private static let onlyInText = Set("Td TD Tm T* Tj TJ ' \"".split(separator: " ").map(String.init))
    private static let deviceSpaces = ["DeviceGray", "DeviceRGB", "DeviceCMYK"]

    private static let maxStack = 256
    private static let maxMarked = 1024
    private static let maxSegments = 1_000_000
    private static let maxOperations = 1_000_000
    private static let maxEntered = 5_000_000
    private static let maxSize = 64 << 20

    private final class Scope {
        let own: PdfDictionary?
        let outer: Scope?

        init(_ own: PdfDictionary?, _ outer: Scope?) {
            self.own = own
            self.outer = outer
        }

        var effective: PdfDictionary? { own ?? outer?.effective }
    }

    private struct UseKey: Hashable {
        let category: String
        let name: String
    }

    // The uses of a body in the order they were first met, as a Dictionary enumerates them in .NET.
    private struct Uses {
        private(set) var keys: [UseKey] = []
        private var counts: [UseKey: Int] = [:]

        init(_ defaults: [(category: String, name: String)]) {
            for d in defaults { add(UseKey(category: d.category, name: d.name), 1) }
        }

        mutating func add(_ key: UseKey, _ by: Int) {
            if let known = counts[key] {
                counts[key] = known + by
            } else {
                keys.append(key)
                counts[key] = by
            }
        }

        func count(_ key: UseKey) -> Int { counts[key] ?? 0 }
    }

    private struct Body {
        let operations: Int
        let stack: Int
        let marked: Int
        let uses: Uses
    }

    private struct Seen {
        let stream: PdfStream
        let body: Body?
        let inherited: PdfDictionary?
    }

    private let document: PdfDocument
    private var bodies: [ObjectIdentifier: Seen] = [:]
    private var active = Set<ObjectIdentifier>()
    private var fonts: [ObjectIdentifier: Bool] = [:]
    private var fontsHeld: [PdfDictionary] = []
    private var entered = 0

    init(_ document: PdfDocument) {
        self.document = document
    }

    /// Why the walk gave up; nil when it followed everything.
    private(set) var problem: String?

    var ok: Bool { problem == nil }

    /// The numbers of the objects that are painted: everything a used resource leads to.
    private(set) var used = Set<Int>()

    /// The names the content found, as the list that holds them and the name: what a rebuilt resource dictionary keeps.
    private(set) var reads = Set<ListName>()

    /// How many times each form, cell, mask group, picture or glyph procedure was entered, whichever way.
    private(set) var entries = StreamCounts()

    /// Follows the page; `content` is what the page is to show, when not what it holds now.
    @discardableResult
    func page(_ page: PdfPage, _ content: [UInt8]? = nil) -> Bool {
        let scope = Scope(page.resources, nil)
        lists(page.dictionary)
        var breaks: [Int] = []
        if let data = content ?? joined(page, &breaks), let body = read(data, scope, breaks) { follow(body, scope, 0, 0, 0, 1) }
        return ok
    }

    /// Follows `content` as the content of the form or cell `owner`, with the resources it has now.
    @discardableResult
    func content(_ owner: PdfDictionary, _ content: [UInt8]) -> Bool {
        let scope = Scope(document.dict(owner, "Resources"), nil)
        lists(owner)
        if let body = read(content, scope, []) { follow(body, scope, 0, 0, 0, 1) }
        return ok
    }

    // The streams are read one by one: a stream that does not read is content the page has and the walk has not seen.
    private func joined(_ page: PdfPage, _ breaks: inout [Int]) -> [UInt8]? {
        var joined: [UInt8] = []
        let contents = document.resolve(page.dictionary["Contents"])
        var count = 0
        let items: [PdfObject] = (contents as? PdfArray)?.items ?? [contents ?? PdfNull.instance]
        for item in items {
            let part = document.resolve(item)
            if part == nil || part is PdfNull { continue }
            do {
                guard let stream = part as? PdfStream else { throw PdfReadException.damaged("Not a content stream.") }
                let data = try document.data(stream, Self.maxSize - joined.count)
                if count > 0 {
                    breaks.append(joined.count)
                    joined.append(0x0A)
                }
                count += 1
                joined.append(contentsOf: data)
            } catch {
                fail("content stream does not read")
                return nil
            }
        }
        return joined
    }

    /// Follows what the page keeps of its annotations: the appearances they are drawn with, as forms. Annotations that were
    /// removed are no longer in the page. False when an appearance cannot be followed.
    @discardableResult
    func annotations(_ page: PdfPage) -> Bool {
        guard let annots = page.dictionary["Annots"] else { return ok }
        keep(annots, RedactionObjects.annotating)
        for item in (document.resolve(annots) as? PdfArray)?.items ?? [] {
            guard let appearance = document.dict(document.resolve(item) as? PdfDictionary, "AP") else { continue }
            for key in ["N", "R", "D"] {
                let state = appearance[key]
                let forms: [PdfObject?] = (document.resolve(state) as? PdfDictionary).map { $0.entries.map { $0.value as PdfObject? } } ?? [state]
                for form in forms {
                    if let form, let stream = document.resolve(form) as? PdfStream { enter(form, stream, Scope(nil, nil), 0, 0, 0, 1) }
                }
            }
        }
        return ok
    }

    // The resource dictionary and its lists are objects of their own when they are indirect, and stay with the names in them.
    // Only the lists of 7.8.3 are looked at, and each has to be a dictionary of its own: any other value there is not a list.
    private func lists(_ owner: PdfDictionary) {
        let resources = document.resolve(owner["Resources"])
        if !(resources == nil || resources is PdfNull || resources is PdfDictionary) || RedactionObjects.inTree(document, resources) {
            fail("resources")
            return
        }
        if let own = owner["Resources"] as? PdfReference { used.insert(own.number) }
        // A null /Resources has no lists (the C# casts it to a dictionary and throws).
        guard let held = resources as? PdfDictionary else { return }
        for category in RedactionResources.lists {
            guard let list = document.resolve(held[category]) else { continue }
            if !(list is PdfDictionary) || RedactionObjects.inTree(document, list) {
                fail("resource list")
                return
            }
            if let reference = held[category] as? PdfReference { used.insert(reference.number) }
        }
    }

    private func fail(_ problem: String) {
        if self.problem == nil { self.problem = problem }
    }

    private func read(_ data: [UInt8], _ scope: Scope, _ breaks: [Int]) -> Body? {
        let operations = ContentParser.parse(data)
        if operations.count > Self.maxOperations {
            fail("too many operations")
            return nil
        }
        if !RedactionSyntax.whole(data, operations, breaks) {
            fail("content is not well formed")
            return nil
        }
        // A pattern name only means something in a pattern space; the interpreter ignores it elsewhere and a viewer may not.
        var text = false, fill = false, stroke = false
        var saved: [(fill: Bool, stroke: Bool)] = []
        var stack = 0, deepest = 0, marked = 0, markedDeepest = 0
        var segments = 0
        var uses = Uses(RedactionSyntax.defaults)
        for op in operations {
            if !RedactionSyntax.valid(op) {
                fail("operator \(op.operator)")
                return nil
            }
            // Figure 9 of ISO 32000-1: a text object holds text, colour and state operators and nothing that draws elsewhere.
            if (text && Self.notInText.contains(op.operator)) || (!text && (Self.onlyInText.contains(op.operator) || op.operator == "ET")) {
                fail("operator outside its object")
                return nil
            }
            switch op.operator {
            case "BT": text = true
            case "ET": text = false
            case "cs": fill = isPattern(scope, op.operands[0])
            case "CS": stroke = isPattern(scope, op.operands[0])
            case "g", "rg", "k": fill = false
            case "G", "RG", "K": stroke = false
            case "scn" where op.operands[op.operands.count - 1] is PdfName && !fill,
                 "SCN" where op.operands[op.operands.count - 1] is PdfName && !stroke:
                fail("pattern name outside a pattern space")
                return nil
            case "q":
                saved.append((fill, stroke))
                stack += 1
                deepest = max(deepest, stack)
            case "Q" where stack == 0:
                fail("Q without q")
                return nil
            case "Q":
                stack -= 1
                (fill, stroke) = saved.removeLast()
            case "BMC", "BDC":
                marked += 1
                markedDeepest = max(markedDeepest, marked)
            case "EMC": marked = max(0, marked - 1)
            case "m", "l", "c", "v", "y", "h": segments += 1
            case "re": segments += 5
            case "S", "s", "f", "F", "f*", "B", "B*", "b", "b*", "n": segments = 0
            case "BI" where !RedactionSyntax.fits(document, op, data, { self.find(scope, "ColorSpace", $0) }):
                fail("inline image")
                return nil
            default: break
            }
            if segments > Self.maxSegments {
                fail("path too long")
                return nil
            }
            for use in RedactionSyntax.names(op) { uses.add(UseKey(category: use.category, name: use.name), 1) }
        }
        return Body(operations: operations.count, stack: deepest, marked: markedDeepest, uses: uses)
    }

    // An uncoloured tiling pattern needs a space of its own, [/Pattern /DeviceRGB] under a name (8.7.3.3).
    private func isPattern(_ scope: Scope, _ operand: PdfObject) -> Bool {
        guard let name = (operand as? PdfName)?.value else { return false }
        if name == "Pattern" { return true }
        if Self.deviceSpaces.contains(name) { return false }
        guard let array = document.resolve(find(scope, "ColorSpace", name)) as? PdfArray, let first = array.items.first else { return false }
        return (document.resolve(first) as? PdfName)?.value == "Pattern"
    }

    // An entry only an enclosing list has is one the interpreter finds and a viewer may not.
    private func find(_ scope: Scope, _ category: String, _ name: String) -> PdfObject? {
        if let list = document.dict(scope.effective, category), let found = list[name] {
            reads.insert(ListName(list, name))
            return found
        }
        var outer: Scope? = scope
        while let level = outer {
            if let borrowed = document.dict(level.own, category)?[name] {
                fail("name resolved in an enclosing list")
                return borrowed
            }
            outer = level.outer
        }
        return nil
    }

    private func follow(_ body: Body, _ scope: Scope, _ depth: Int, _ stack: Int, _ marked: Int, _ times: Int) {
        entered += body.operations * times
        if entered > Self.maxEntered {
            fail("too much content")
            return
        }
        if stack + body.stack > Self.maxStack || marked + body.marked > Self.maxMarked {
            fail("nesting")
            return
        }
        for key in body.uses.keys {
            if problem != nil { return }
            if let raw = find(scope, key.category, key.name) {
                use(raw, key.category, scope, depth, stack + body.stack, marked + body.marked, min(times * body.uses.count(key), Self.maxEntered))
            }
        }
    }

    private func use(_ raw: PdfObject, _ category: String, _ scope: Scope, _ depth: Int, _ stack: Int, _ marked: Int, _ times: Int) {
        let resolved = document.resolve(raw)
        switch category {
        case "XObject":
            guard let resolved else { break }
            if let x = resolved as? PdfStream, document.name(x.dictionary, "Subtype") == "Image" {
                RedactionObjects.paintedStream(document, raw, &used, RedactionObjects.painting)
                count(x, times)
                for mask in ImageRedactor.masks(document, x) { count(mask, times) }
            } else if let x = resolved as? PdfStream, document.name(x.dictionary, "Subtype") == "Form" {
                enter(raw, x, scope, depth, stack, marked, times)
            } else {
                fail("xobject kind")
            }
        case "Font":
            if let font = resolved as? PdfDictionary { self.font(raw, font) }
        case "ExtGState":
            if let state = resolved as? PdfDictionary { self.state(raw, state, scope, depth, stack, marked, times) }
        case "Pattern":
            guard let resolved else { break }
            if let cell = resolved as? PdfStream, document.integer(cell.dictionary, "PatternType") == 1 {
                enter(raw, cell, scope, depth, stack, marked, times)
            } else if let shading = resolved as? PdfDictionary, document.integer(shading, "PatternType") == 2, RedactionSyntax.isMatrix(document, shading, "Matrix") {
                keep(raw, "ExtGState")
                if let state = shading["ExtGState"], let through = document.resolve(state) as? PdfDictionary {
                    self.state(state, through, scope, depth, stack, marked, times)
                }
            } else {
                fail("pattern kind")
            }
        case "Shading":
            if let mesh = resolved as? PdfStream {
                if !RedactionObjects.barred(document, mesh) {
                    RedactionObjects.paintedStream(document, raw, &used, RedactionObjects.painting)
                } else {
                    fail("resource kind")
                }
            } else if resolved is PdfDictionary {
                keep(raw)
            }
        case "ColorSpace", "Properties":
            if resolved is PdfStream {
                fail("resource kind")
            } else if resolved is PdfDictionary || resolved is PdfArray || resolved is PdfName {
                keep(raw)
            }
        default:
            break
        }
    }

    private func state(_ raw: PdfObject, _ state: PdfDictionary, _ scope: Scope, _ depth: Int, _ stack: Int, _ marked: Int, _ times: Int) {
        // A font chosen by a graphics state is a way back into Type 3 procedures that no operator names.
        if state.containsKey("Font") {
            fail("graphics state font")
            return
        }
        keep(raw, "SMask")
        if let mask = document.resolve(state["SMask"]) as? PdfDictionary, let held = state["SMask"] {
            keep(held, "G")
            if let group = mask["G"], let groupStream = document.resolve(group) as? PdfStream {
                enter(group, groupStream, scope, depth, stack, marked, times)
            } else {
                fail("soft mask group")
            }
        }
    }

    private func enter(_ raw: PdfObject, _ stream: PdfStream, _ scope: Scope, _ depth: Int, _ stack: Int, _ marked: Int, _ times: Int) {
        RedactionObjects.paintedStream(document, raw, &used, RedactionObjects.painting, ["Resources"])
        if !RedactionSyntax.isMatrix(document, stream.dictionary, "Matrix") {
            fail("matrix")
            return
        }
        if depth >= Self.formDepth {
            fail("form depth")
            return
        }
        let id = ObjectIdentifier(stream)
        if !active.insert(id).inserted {
            fail("form reaches itself")
            return
        }
        count(stream, times)
        lists(stream.dictionary)
        let inner = Scope(document.dict(stream.dictionary, "Resources"), scope)
        var body: Body?
        if let seen = bodies[id] {
            body = seen.body
            // Without resources of its own the form takes the enclosing ones, so a second place that has others is another reading.
            if inner.own == nil && seen.inherited !== inner.effective { fail("form inherits different resources") }
        } else {
            var data: [UInt8]?
            do {
                data = try document.data(stream, Self.maxSize)
            } catch {
                fail("form does not read")
            }
            let found = data.flatMap { read($0, inner, []) }
            bodies[id] = Seen(stream: stream, body: found, inherited: inner.effective)
            body = found
        }
        if let body, problem == nil { follow(body, inner, depth + 1, stack, marked, times) }
        active.remove(id)
    }

    private func font(_ raw: PdfObject, _ font: PdfDictionary) {
        keep(raw, "Resources")
        // A font PdfFont reads one way and a viewer another (a composite one by its descendants, a simple one by its codes) is not followed.
        let kind = document.name(font, "Subtype") ?? ""
        let composite = kind == "Type0"
        var known = Self.fontKinds.contains(kind) && composite == font.containsKey("DescendantFonts")
        if known && composite {
            if let descendants = document.array(font, "DescendantFonts"), descendants.items.count == 1 {
                known = Self.cidKinds.contains(document.name(document.resolve(descendants.items[0]) as? PdfDictionary, "Subtype") ?? "")
            } else {
                known = false
            }
        }
        if !known {
            fail("font kind")
            return
        }
        if !RedactionGlyphs.measured(document, font) { fail("font metrics") }
        if kind != "Type3" { return }
        let id = ObjectIdentifier(font)
        let plain: Bool
        if let known = fonts[id] {
            plain = known
        } else {
            plain = RedactionGlyphs.plain(document, font)
            fonts[id] = plain
            fontsHeld.append(font)
        }
        if !plain { fail("Type 3 glyphs") }
    }

    private func count(_ stream: PdfStream, _ times: Int) {
        entries[stream] = min(entries[stream] + times, Self.maxEntered)
    }

    // What the object leads to by the keys of RedactionObjects.painting is painted with it, except the keys given, which the walk follows by what the content names.
    private func keep(_ raw: PdfObject, _ apart: String...) {
        RedactionObjects.painted(document, raw, &used, RedactionObjects.painting, apart)
    }

    private func keep(_ raw: PdfObject, _ reading: RedactionObjects.Reading) {
        RedactionObjects.painted(document, raw, &used, reading)
    }
}
