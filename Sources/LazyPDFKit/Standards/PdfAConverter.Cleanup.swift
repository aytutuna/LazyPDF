import Foundation

// Twin of windows/LazyPDF.Core/Standards/PdfAConverter.Cleanup.cs: what the conversion removes or corrects without needing a
// font: actions, annotations, form flags, stream keys and filters, optional content and embedded files.

extension PdfAConversionRun {
    static let maxSteps = 20_000_000

    static let intents = ["AbsoluteColorimetric", "RelativeColorimetric", "Saturation", "Perceptual"]

    struct Parts {
        var dictionaries: [PdfDictionary] = []
        var streams: [PdfStream] = []
        var arrays: [PdfArray] = []
    }

    /// Every dictionary and stream reachable from the trailer, each once.
    func collect() -> Parts {
        var parts = Parts()
        var visited = Set<Int>()
        var stack: [PdfObject] = [document.trailer]
        var steps = 0
        while steps < Self.maxSteps, let next = stack.popLast() {
            steps += 1
            switch next {
            case let reference as PdfReference:
                if visited.insert(reference.number).inserted, let target = document.get(reference.number) { stack.append(target) }
            case let array as PdfArray:
                parts.arrays.append(array)
                for item in array.items { stack.append(item) }
            case let stream as PdfStream:
                parts.streams.append(stream)
                stack.append(stream.dictionary)
            case let dictionary as PdfDictionary:
                parts.dictionaries.append(dictionary)
                for entry in dictionary.entries { stack.append(entry.value) }
            default:
                break
            }
        }
        return parts
    }

    // Integers past 32 bits are a limit of the standard (6.1.12, 6.1.13); writers sometimes put float limits there as digits.
    func clampIntegers(_ parts: Parts) {
        var clamped = 0
        func tooBig(_ value: PdfObject?) -> Bool {
            guard let number = value as? PdfNumber, number.isInteger else { return false }
            return abs(number.value) > Double(Int32.max)
        }
        func limit(_ value: PdfObject) -> PdfObject {
            clamped += 1
            return PdfNumber(((value as? PdfNumber)?.value ?? 0) < 0 ? Int(Int32.min) : Int(Int32.max))
        }
        for d in parts.dictionaries {
            if !d.entries.contains(where: { tooBig($0.value) }) { continue }
            for (key, value) in d.entries where tooBig(value) { d[key] = limit(value) }
        }
        for array in parts.arrays {
            for i in 0..<array.items.count where tooBig(array.items[i]) { array.items[i] = limit(array.items[i]) }
        }
        if clamped > 0 { changed(PdfAText.integersClamped(clamped)) }
    }

    // With no blend mode, opacity or mask left to ask for it, a transparency group changes nothing on the page.
    func removeGroups(_ parts: Parts) {
        var removed = 0
        for d in parts.dictionaries {
            if let group = document.dict(d, "Group"), document.name(group, "S") == "Transparency",
               document.name(d, "Type") == "Page" || document.name(d, "Subtype") == "Form", d.remove("Group") {
                removed += 1
            }
        }
        if removed > 0 { changed(PdfAText.groupsRemoved(removed)) }
    }

    private func isForbidden(_ value: PdfObject?) -> Bool {
        guard let action = document.resolve(value) as? PdfDictionary, let type = document.name(action, "S") else { return false }
        return PdfAChecker.forbiddenActions.contains(type) || (type == "Named" && !PdfAChecker.namedActions.contains(document.name(action, "N") ?? ""))
    }

    private static func isFieldOrWidget(_ document: PdfDocument, _ d: PdfDictionary) -> Bool {
        d.containsKey("FT") || document.name(d, "Subtype") == "Widget" || (d.containsKey("T") && d.containsKey("Kids"))
    }

    func removeActions(_ parts: Parts) {
        var removed = 0
        for d in parts.dictionaries {
            for key in ["A", "OpenAction", "Next"] where isForbidden(d[key]) && d.remove(key) { removed += 1 }
            if let chain = document.resolve(d["Next"]) as? PdfArray {
                let before = chain.items.count
                chain.items.removeAll { isForbidden($0) }
                removed += before - chain.items.count
            }
            guard let triggers = document.dict(d, "AA") else { continue }
            if d === document.catalog || Self.isFieldOrWidget(document, d) {
                d.remove("AA")
                removed += 1
                continue
            }
            for (key, action) in triggers.entries where isForbidden(action) && triggers.remove(key) { removed += 1 }
            if triggers.count == 0 { d.remove("AA") }
        }
        if let names = document.dict(document.catalog, "Names"), names.remove("JavaScript") { removed += 1 }
        if removed > 0 { changed(PdfAText.actionsRemoved(removed)) }
    }

    private func fieldType(_ field: PdfDictionary) -> String? {
        var current: PdfDictionary? = field
        var hops = 0
        while let field = current, hops < 32 {
            if let type = document.name(field, "FT") { return type }
            current = document.dict(field, "Parent")
            hops += 1
        }
        return nil
    }

    /// The normal appearance is there: a state dictionary for a button, a stream for the rest.
    func hasAppearance(_ annotation: PdfDictionary) -> Bool {
        let normal = document.resolve(document.dict(annotation, "AP")?["N"])
        let button = document.name(annotation, "Subtype") == "Widget" && fieldType(annotation) == "Btn"
        return button ? normal is PdfDictionary : normal is PdfStream
    }

    func fixAnnotations() throws {
        let writer = PdfAnnotationWriter(document, fonts)
        var dropped = 0, flagged = 0, drawn = 0
        let pages = document.pages
        for p in 0..<pages.count {
            guard let annotations = document.array(pages[p].dictionary, "Annots") else { continue }
            var kept: [PdfObject] = []
            for item in annotations.items {
                guard let annotation = document.resolve(item) as? PdfDictionary else { continue }
                let subtype = document.name(annotation, "Subtype")
                let allowed = subtype.map { PdfAChecker.allowedAnnotations(part).contains($0) && !($0 == "FileAttachment" && part == 4) } ?? false
                if !allowed {
                    dropped += 1
                    continue
                }
                kept.append(item)
                if subtype == "Popup" { continue }
                let flags = document.integer(annotation, "F") ?? 0
                let fixedFlags = (flags | 4) & ~(1 | 2 | 32)
                if fixedFlags != flags {
                    annotation["F"] = PdfNumber(fixedFlags)
                    flagged += 1
                }
                if let ap = document.dict(annotation, "AP") {
                    for (key, _) in ap.entries where key != "N" { ap.remove(key) }
                }
                if part == 1 { annotation.remove("CA") }
                if subtype == "Link" || subtype == "Widget" || hasAppearance(annotation) || document.rect(annotation, "Rect") == nil { continue }
                do {
                    if let parsed = PdfAnnotations.parse(document, annotation, item as? PdfReference, p), try writer.regenerate(parsed) { drawn += 1 }
                } catch is InvalidOperationException {
                    // No font for its text; the validator reports the missing appearance.
                } catch is PdfReadException {
                }
            }
            if kept.count != annotations.items.count { annotations.items = kept }
        }
        if dropped > 0 { changed(PdfAText.annotationsRemoved(dropped)) }
        if flagged > 0 { changed(PdfAText.flagsSet(flagged)) }
        if drawn > 0 { changed(PdfAText.appearancesDrawn(drawn)) }
    }

    func fixForm() throws {
        let form = PdfForm.read(document, fonts)
        guard let acro = form.acroForm else { return }
        if acro.remove("XFA") { changed(PdfAText.xfaRemoved) }
        let stale = form.needAppearances
        let fields = form.fields.filter { $0.kind != .signature && (stale || $0.widgets.contains { !hasAppearance($0.dictionary) }) }
        if !fields.isEmpty {
            do {
                try form.regenerate(fields)
                changed(PdfAText.fieldsDrawn(fields.count))
            } catch is InvalidOperationException {
                // A font for the field text is missing; the widgets without an appearance stay in the report.
            } catch is PdfReadException {
            }
        }
        acro.remove("NeedAppearances")
    }

    func fixStreams(_ parts: Parts) {
        var recoded = 0
        for stream in parts.streams {
            let d = stream.dictionary
            for key in ["F", "FFilter", "FDecodeParms"] { d.remove(key) }
            var filters: [String] = []
            switch document.resolve(d["Filter"]) {
            case let name as PdfName: filters = [name.value]
            case let array as PdfArray: filters = array.items.map { (document.resolve($0) as? PdfName)?.value ?? "" }
            default: break
            }
            if filters.contains(where: { $0 == "LZWDecode" || $0 == "LZW" || $0 == "Crypt" }) && recode(stream) { recoded += 1 }
            switch document.name(d, "Subtype") {
            case "Image":
                d.remove("Interpolate")
                d.remove("OPI")
                d.remove("Alternates")
                if let intent = document.name(d, "Intent"), !Self.intents.contains(intent) { d.remove("Intent") }
            case "Form":
                d.remove("Ref")
                d.remove("PS")
                d.remove("OPI")
                if document.name(d, "Subtype2") == "PS" { d.remove("Subtype2") }
            default:
                break
            }
        }
        for d in parts.dictionaries {
            guard let states = document.dict(d, "ExtGState") else { continue }
            cleanState(states)
            for (_, value) in states.entries { cleanState(document.resolve(value) as? PdfDictionary) }
        }
        if recoded > 0 { changed(PdfAText.streamsRecoded(recoded)) }
    }

    private func cleanState(_ state: PdfDictionary?) {
        guard let state else { return }
        state.remove("TR")
        state.remove("HTP")
        if document.name(state, "TR2") != "Default" { state.remove("TR2") }
        if let intent = document.name(state, "RI"), !Self.intents.contains(intent) { state.remove("RI") }
    }

    /// Takes the LZW (or Crypt) stage off a stream, keeping an image codec's own filter.
    private func recode(_ stream: PdfStream) -> Bool {
        let d = stream.dictionary
        do {
            let (filter, parameters, _) = document.decodeSpec(stream)
            let decoded = try PdfFilters.decodeToCodec(document.rawData(stream), filter, parameters, 256 << 20)
            if let codec = decoded.codec {
                stream.data = decoded.data
                d["Filter"] = PdfName(codec)
                if let codecParameters = decoded.parameters { d["DecodeParms"] = codecParameters } else { d.remove("DecodeParms") }
            } else {
                stream.data = PdfFilterEncoders.flate(decoded.data)
                d["Filter"] = PdfName("FlateDecode")
                d.remove("DecodeParms")
            }
            return true
        } catch {
            return false
        }
    }

    func fixOptionalContent() {
        guard let properties = document.dict(document.catalog, "OCProperties") else { return }
        if part == 1 {
            document.catalog.remove("OCProperties")
            changed(PdfAText.layersRemoved)
            return
        }
        var configs: [PdfDictionary] = []
        var main = document.dict(properties, "D")
        if main == nil {
            main = PdfDictionary()
            properties["D"] = main
        }
        if let main { configs.append(main) }
        for item in document.array(properties, "Configs")?.items.prefix(256) ?? [] {
            if let config = document.resolve(item) as? PdfDictionary { configs.append(config) }
        }
        var names = Set<String>()
        let groups = Set((document.array(properties, "OCGs")?.items ?? []).compactMap { ($0 as? PdfReference)?.number })
        for (i, config) in configs.enumerated() {
            let name = (document.resolve(config["Name"]) as? PdfString).map { Latin1.string($0.bytes) } ?? ""
            if name.isEmpty || !names.insert(name).inserted {
                let made = i == 0 ? "Default" : "Configuration \(i)"
                names.insert(made)
                config["Name"] = PdfString(bytes: Array(made.utf8), isHex: false)
            }
            config.remove("AS")
            if let order = document.array(config, "Order"), !groups.isSubset(of: Self.listed(order)) { config.remove("Order") }
        }
    }

    private static func listed(_ order: PdfArray) -> Set<Int> {
        var numbers = Set<Int>()
        var stack = [order]
        var steps = 0
        while steps < 10_000, let next = stack.popLast() {
            for item in next.items {
                if let r = item as? PdfReference {
                    numbers.insert(r.number)
                } else if let inner = item as? PdfArray {
                    stack.append(inner)
                }
            }
            steps += 1
        }
        return numbers
    }

    func fixEmbeddedFiles(_ parts: Parts) {
        var removed = 0, described = 0
        for spec in parts.dictionaries.filter({ $0.containsKey("EF") }) {
            var stream: PdfStream?
            if let ef = document.dict(spec, "EF") { stream = document.stream(ef, "F") ?? document.stream(ef, "UF") }
            if part == 3 {
                if !spec.containsKey("AFRelationship") { spec["AFRelationship"] = PdfName("Unspecified") }
                if !spec.containsKey("UF"), let file = spec["F"] { spec["UF"] = file }
                if let stream, document.name(stream.dictionary, "Subtype") == nil { stream.dictionary["Subtype"] = PdfName("application/octet-stream") }
                described += 1
            } else {
                var keep = false
                if part == 2, let stream { keep = PdfAChecker.isPdfA(document, stream) }
                if !keep {
                    spec.remove("EF")
                    removed += 1
                }
            }
        }
        if (part == 1 || part == 4), let names = document.dict(document.catalog, "Names"), names.remove("EmbeddedFiles") { removed += 1 }
        if removed > 0 { changed(PdfAText.attachmentsRemoved(removed)) }
        if described > 0 { changed(PdfAText.attachmentsDescribed(described)) }
    }
}
