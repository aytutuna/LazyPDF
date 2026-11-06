import Foundation

// Twin of windows/LazyPDF.Core/Standards/PdfAChecker.Budget.cs: what checking may cost. A form is parsed once but run at
// every paint, so each paint is charged by the interpreter's own rules: its operations, the glyphs it shows, and the bytes
// inflated again when the interpreter has no room to keep it.

extension PdfAChecker {
    static let maxStreamBytes = 64 << 20

    // The interpreter's limits on a form: the most operations it runs, how deep forms nest, and how many it keeps parsed. It skips a longer or
    // deeper form without a trace, and inflates a form that did not fit in its cache again at every paint.
    static let maxFormOperations = 1_000_000
    static let maxFormDepth = 20
    static let maxCachedForms = 1024
    static let maxCachedOperations = 4_000_000

    // Inflating a byte is far cheaper than running an operation; the interpreter itself charges a form it did not keep at 1/64 of its size.
    static let uncachedShift = 2
    static let defaultWork = 1 << 30
    static let workPerFileByte = 16

    struct FormCost {
        let operations: Int
        let size: Int
        let glyphs: Int
    }

    var overBudget: Bool { work > (maxWork ?? Self.defaultWork + Self.workPerFileByte * document.length) }

    func unreadable(_ place: String) {
        add("6.1.7", place, overBudget ? PdfAText.tooMuchContent : PdfAText.contentUnreadable)
    }

    func charge(_ form: PdfStream, _ place: String) throws {
        let key = ObjectIdentifier(form)
        let known: FormCost
        if let cost = formCosts[key] {
            known = cost
        } else {
            if overBudget { throw PdfReadException.damaged(PdfAText.tooMuchContent) }
            known = measure(form, place)
        }
        if known.operations > Self.maxFormOperations { add("6.1.7", place, PdfAText.tooMuchContent) }
        work += known.operations + known.glyphs + (isKept(form, known.operations) ? 0 : known.size >> Self.uncachedShift) + 1
        if overBudget { throw PdfReadException.damaged(PdfAText.tooMuchContent) }
    }

    // A form that cannot be read costs what inflating it takes at most, and the interpreter keeps it as an empty list.
    @discardableResult
    func measure(_ form: PdfStream, _ place: String) -> FormCost {
        let cost: FormCost
        do {
            let data = try document.data(form, Self.maxStreamBytes)
            let operations = try checkContent(data, place)
            cost = FormCost(operations: operations.count, size: data.count, glyphs: Self.shownBytes(operations))
        } catch {
            unreadable(place)
            cost = FormCost(operations: 0, size: Self.maxStreamBytes, glyphs: 0)
        }
        formCosts[ObjectIdentifier(form)] = cost
        return cost
    }

    // Each byte of a shown string is at most one glyph the interpreter visits.
    private static func shownBytes(_ operations: [ContentOperation]) -> Int {
        var total = 0
        for op in operations {
            guard op.operator == "Tj" || op.operator == "TJ" || op.operator == "'" || op.operator == "\"", let last = op.operands.last else { continue }
            switch last {
            case let text as PdfString: total += text.bytes.count
            case let array as PdfArray: for case let text as PdfString in array.items { total += text.bytes.count }
            default: break
            }
        }
        return total
    }

    // Follows the interpreter's cache, which takes forms in the order they are first painted and keeps a form it skipped or could not read as empty.
    private func isKept(_ form: PdfStream, _ operations: Int) -> Bool {
        let key = ObjectIdentifier(form)
        if cachedForms.contains(key) { return true }
        let held = operations > Self.maxFormOperations ? 0 : operations
        if cachedForms.count >= Self.maxCachedForms || cachedOperations + held > Self.maxCachedOperations { return false }
        cachedForms.insert(key)
        cachedOperations += held
        return true
    }

    // At the depth limit the interpreter runs a form but not the forms and tiling patterns inside it, and says nothing. A pattern is entered when a path is
    // painted with it, whether the form set it or inherited it, unless it has been run already.
    func skipsContent(_ form: PdfStream, _ context: ContentContext, _ find: (String, String) -> PdfObject?, _ walked: Set<ObjectIdentifier>) -> Bool {
        if skippingForms.contains(ObjectIdentifier(form)) { return true }
        func isNewPattern(_ pattern: PdfObject?) -> Bool {
            guard let cell = pattern as? PdfStream else { return false }
            return document.integer(cell.dictionary, "PatternType") == 1 && !walked.contains(ObjectIdentifier(cell))
        }
        var paints = false
        var patterned = isNewPattern(context.state.fillColor.pattern) || isNewPattern(context.state.strokeColor.pattern)
        let operations: [ContentOperation]
        do {
            let data = try document.data(form, Self.maxStreamBytes)
            work += data.count
            operations = try ContentParser.parse(data, Self.maxFormOperations)
        } catch {
            return false
        }
        for op in operations {
            switch op.operator {
            case "Do":
                if let xobject = op.operands.last as? PdfName, let entered = find("XObject", xobject.value) as? PdfStream,
                   document.name(entered.dictionary, "Subtype") == "Form"
                    || (!entered.dictionary.containsKey("Subtype") && entered.dictionary.containsKey("BBox")) {
                    skippingForms.insert(ObjectIdentifier(form))
                    return true
                }
            case "f", "F", "f*", "B", "B*", "b", "b*", "S", "s":
                paints = true
            case "scn", "SCN":
                if let pattern = op.operands.last as? PdfName, isNewPattern(find("Pattern", pattern.value)) { patterned = true }
            default:
                break
            }
        }
        return paints && patterned
    }
}
