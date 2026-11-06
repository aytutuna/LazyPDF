import Foundation

// Twin of windows/LazyPDF.Core/Standards/PdfAChecker.Annotations.cs: annotations, actions and interactive forms
// (ISO 19005-1 6.5, 6.6, 6.9; 19005-2 6.3, 6.4, 6.5).

extension PdfAChecker {
    static let maxAnnotations = 50_000

    // What walking an annotation, and resolving one of its appearance states, cost in the work budget; /Annots and /N are often shared by many pages.
    static let annotationWork = 256
    static let stateWork = 64

    static let part1Annotations = [
        "Text", "Link", "FreeText", "Line", "Square", "Circle", "Highlight", "Underline", "Squiggly", "StrikeOut", "Stamp", "Ink", "Popup", "Widget", "PrinterMark", "TrapNet",
    ]

    static let laterAnnotations = part1Annotations + ["Polygon", "PolyLine", "Caret", "FileAttachment", "Redact", "Watermark"]

    static let forbiddenActions = ["Launch", "Sound", "Movie", "ResetForm", "ImportData", "JavaScript", "Hide", "SetOCGState", "Rendition", "Trans", "GoTo3DView", "SetState", "NOP"]

    static let namedActions = ["NextPage", "PrevPage", "FirstPage", "LastPage"]

    /// The annotation subtypes a part allows, before the rule about attachments.
    static func allowedAnnotations(_ part: Int) -> [String] { part == 1 ? part1Annotations : laterAnnotations }

    func checkAnnotations(_ page: PdfPage, _ pageNumber: Int, _ interpreter: ContentInterpreter) {
        guard let annotations = document.array(page.dictionary, "Annots") else { return }
        let flags = c("6.5.3", "6.3.2"), appearance = c("6.5.3", "6.3.3")
        var i = 0
        while i < annotations.items.count && i < Self.maxAnnotations && !overBudget {
            defer { i += 1 }
            work += Self.annotationWork
            guard let annotation = document.resolve(annotations.items[i]) as? PdfDictionary else { continue }
            // Built only where an issue or a run needs it: the text goes through a number formatter, and a shared /Annots is walked once per page.
            var named: String?
            func place() -> String {
                if named == nil { named = PdfAText.annotationName(pageNumber, i + 1) }
                return named ?? ""
            }
            let declared = document.name(annotation, "Subtype")
            guard let subtype = declared, Self.allowedAnnotations(part).contains(subtype) else {
                add(c("6.5.2", "6.3.1"), place(), PdfAText.annotationType(declared))
                continue
            }
            if subtype == "FileAttachment" && part == 4 { add("6.3.1", place(), PdfAText.embeddedFile) }
            if isPart1, let opacity = document.number(annotation, "CA"), opacity < 1 { add(clauseTransparency, place(), PdfAText.opacity) }
            if subtype == "Widget" && annotation.containsKey("A") { add(c("6.6.1", "6.4.1"), place(), PdfAText.widgetAction) }
            checkAction(annotation["A"], place())
            checkTriggers(annotation, place(), subtype == "Widget")
            if isPart1 && intentComponents != 3 && (hasColor(annotation, "C") || hasColor(annotation, "IC")) { add("6.5.3", place(), PdfAText.annotationColor) }

            if subtype == "Popup" { continue }
            let f = document.integer(annotation, "F") ?? 0
            if (f & 4) == 0 { add(flags, place(), PdfAText.noPrintFlag) }
            if (f & (1 | 2 | 32)) != 0 { add(flags, place(), PdfAText.hiddenAnnotation) }
            checkAppearance(annotation, subtype, place, appearance, interpreter)
        }
    }

    private func checkAppearance(_ annotation: PdfDictionary, _ subtype: String, _ place: () -> String, _ clause: String, _ interpreter: ContentInterpreter) {
        let zeroArea = !isPart1 && document.rect(annotation, "Rect") == nil
        guard let ap = document.dict(annotation, "AP"), ap["N"] != nil else {
            if subtype != "Link" && !zeroArea { add(clause, place(), PdfAText.noAppearance) }
            return
        }
        if ap.entries.contains(where: { $0.key != "N" }) { add(clause, place(), PdfAText.appearanceKeys) }
        let button = subtype == "Widget" && fieldType(annotation) == "Btn"
        let normal = document.resolve(ap["N"])
        if button != (normal is PdfDictionary) { add(clause, place(), button ? PdfAText.buttonAppearance : PdfAText.appearanceNotStream) }
        var streams: [PdfStream] = []
        switch normal {
        case let stream as PdfStream: streams = [stream]
        case let states as PdfDictionary: streams = states.entries.prefix(256).compactMap { document.resolve($0.value) as? PdfStream }
        default: break
        }
        work += streams.count * Self.stateWork
        for stream in streams {
            checkFormStream(stream, place())
            if !appearancesRun.insert(ObjectIdentifier(stream)).inserted { continue }
            // Once the budget is spent the interpreter would still run every remaining state in full, where the C# stops at the first form.
            if overBudget { break }
            let visitor = Visitor(self, place(), nil)
            interpreter.run(stream, visitor)
            if visitor.failure != nil {
                unreadable(place())
            } else if interpreter.isTruncated {
                add("6.1.7", place(), PdfAText.tooMuchContent)
            }
        }
    }

    private func hasColor(_ annotation: PdfDictionary, _ key: String) -> Bool {
        if let colors = document.array(annotation, key) { return !colors.items.isEmpty }
        return false
    }

    /// /FT of the field a widget belongs to, found up the /Parent chain.
    func fieldType(_ field: PdfDictionary) -> String? {
        var current: PdfDictionary? = field
        var hops = 0
        while let field = current, hops < 32 {
            if let type = document.name(field, "FT") { return type }
            current = document.dict(field, "Parent")
            hops += 1
        }
        return nil
    }

    // Widgets and fields may not have an /AA through part 3 (6.6.2, 6.4.1); part 4 drops that ban and limits the keys of every other owner (6.6.3).
    func checkTriggers(_ owner: PdfDictionary, _ place: @autoclosure () -> String, _ field: Bool) {
        guard let triggers = document.dict(owner, "AA") else { return }
        if field && part != 4 { add(c("6.6.2", "6.4.1"), place(), PdfAText.fieldTriggers) }
        for (key, action) in triggers.entries.prefix(64) {
            if part == 4 && !field && !["E", "X", "D", "U", "Fo", "Bl"].contains(key) { add("6.6.3", place(), PdfAText.triggerKey(key)) }
            checkAction(action, place())
        }
    }

    // An action is judged once wherever it is reached from, and a /Next chain is followed to its end: a loop or a shared tail, array or action, costs nothing more.
    func checkAction(_ value: PdfObject?, _ place: @autoclosure () -> String) {
        var pending: [PdfObject?] = [value]
        let clause = c("6.6.1", "6.5.1")
        while let popped = pending.popLast() {
            guard let action = document.resolve(popped) as? PdfDictionary, actionsSeen.insert(ObjectIdentifier(action)).inserted else { continue }
            let type = document.name(action, "S")
            if let type, Self.forbiddenActions.contains(type) {
                add(clause, place(), type == "JavaScript" ? PdfAText.javaScript : PdfAText.forbiddenAction(type))
            } else if type == "Named" && !Self.namedActions.contains(document.name(action, "N") ?? "") {
                add(clause, place(), PdfAText.namedAction(document.name(action, "N")))
            }
            switch document.resolve(action["Next"]) {
            case let next as PdfDictionary:
                pending.append(next)
            case let list as PdfArray where nextLists.insert(ObjectIdentifier(list)).inserted:
                for item in list.items { pending.append(item) }
            default:
                break
            }
        }
    }

    func checkOutlines() {
        var seen = Set<ObjectIdentifier>()
        var stack: [PdfDictionary] = []
        if let first = document.dict(document.dict(document.catalog, "Outlines"), "First") { stack.append(first) }
        while !stack.isEmpty && seen.count < 200_000 {
            guard let item = stack.popLast(), seen.insert(ObjectIdentifier(item)).inserted else { continue }
            checkAction(item["A"], PdfAText.outlines)
            for key in ["First", "Next"] {
                if let child = document.dict(item, key) { stack.append(child) }
            }
        }
    }

    func checkForm() {
        guard let form = document.dict(document.catalog, "AcroForm") else { return }
        let clause = c("6.9", "6.4.1")
        if document.bool(form, "NeedAppearances") == true { add(clause, PdfAText.form, PdfAText.needAppearances) }
        if form.containsKey("XFA") { add(c("6.9", "6.4.2"), PdfAText.form, PdfAText.xfa) }
        scanResources(document.dict(form, "DR"), PdfAText.form)

        var visited = Set<ObjectIdentifier>()
        var stack: [PdfDictionary] = []
        for item in document.array(form, "Fields")?.items.prefix(Self.maxAnnotations) ?? [] {
            if let root = document.resolve(item) as? PdfDictionary { stack.append(root) }
        }
        while !stack.isEmpty && visited.count < 200_000 {
            guard let field = stack.popLast(), visited.insert(ObjectIdentifier(field)).inserted else { continue }
            if field.containsKey("AA") && part != 4 { add(c("6.6.2", "6.4.1"), PdfAText.form, PdfAText.fieldTriggers) }
            for kid in document.array(field, "Kids")?.items.prefix(Self.maxAnnotations) ?? [] {
                if let child = document.resolve(kid) as? PdfDictionary { stack.append(child) }
            }
        }
    }
}
