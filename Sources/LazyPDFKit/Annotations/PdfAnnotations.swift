import Foundation

// Twin of windows/LazyPDF.Core/Annotations/PdfAnnotations.cs: reading a page's annotations (ISO 32000-1 12.5).

public enum PdfAnnotations {
    static let maxAnnotations = 50_000
    private static let maxNumbers = 4_000_000

    // What one read has turned into numbers, by the array it came from: an array that many annotations point to is read
    // once and shared, so the cost of a file is its size and not its size times the annotations that name the same array.
    // The array is kept with its numbers so that its identity stays taken for as long as the entry lives.
    private final class Shared {
        var numbers: [ObjectIdentifier: (array: PdfArray, values: [Double])] = [:]
        var inks: [ObjectIdentifier: (array: PdfArray, values: [[Double]])] = [:]
    }

    /// Whether the file's permissions let a user annotate: always for an unencrypted file or one opened with the owner
    /// password, else when the Annotate bit is set. Enforcing it is the app's call.
    public static func canAnnotate(_ document: PdfDocument) -> Bool {
        guard let security = document.security else { return true }
        return security.openedAsOwner || security.permissions.contains(.annotate)
    }

    public static func subtypeName(_ type: AnnotationType) -> String { type == .other ? "" : type.rawValue }

    /// The page's annotations in /Annots order, at most 50000. Entries that are not dictionaries or have no /Subtype are
    /// left out; every other key is read tolerantly, a bad one falling back to its default.
    public static func read(_ document: PdfDocument, _ page: PdfPage) -> [PdfAnnotation] {
        read(document, page, Shared())
    }

    private static func read(_ document: PdfDocument, _ page: PdfPage, _ shared: Shared) -> [PdfAnnotation] {
        var result: [PdfAnnotation] = []
        guard let annots = document.array(page.dictionary, "Annots") else { return result }
        for item in annots.items {
            if result.count >= maxAnnotations { break }
            if let dictionary = document.resolve(item) as? PdfDictionary,
               let annotation = parse(document, dictionary, item as? PdfReference, page.index, shared) {
                result.append(annotation)
            }
        }
        return result
    }

    /// Every annotation of the document, page by page.
    public static func readAll(_ document: PdfDocument) -> [PdfAnnotation] {
        var result: [PdfAnnotation] = []
        let shared = Shared()
        for page in document.pages {
            if result.count >= maxAnnotations { break }
            result.append(contentsOf: read(document, page, shared))
        }
        return result
    }

    /// The annotation a dictionary describes; nil without a /Subtype name.
    public static func parse(_ document: PdfDocument, _ d: PdfDictionary, _ reference: PdfReference?, _ pageIndex: Int = -1) -> PdfAnnotation? {
        parse(document, d, reference, pageIndex, Shared())
    }

    private static func parse(_ document: PdfDocument, _ d: PdfDictionary, _ reference: PdfReference?, _ pageIndex: Int, _ shared: Shared) -> PdfAnnotation? {
        guard let subtype = document.name(d, "Subtype") else { return nil }
        let corners = numbers(document, d["Rect"], shared)
        let (start, end) = endings(document, d)
        let be = document.dict(d, "BE")
        var a = PdfAnnotation(dictionary: d)
        a.reference = reference
        a.pageIndex = pageIndex
        a.subtype = subtype
        a.type = AnnotationType(rawValue: subtype) ?? .other
        a.rect = corners.count >= 4 ? PdfRect(corners[0], corners[1], corners[2], corners[3]) : PdfRect(0, 0, 0, 0)
        a.contents = PdfText.read(document, d, "Contents")
        a.title = PdfText.read(document, d, "T")
        a.subject = PdfText.read(document, d, "Subj")
        a.name = PdfText.read(document, d, "NM")
        a.created = PdfDate.parse(PdfText.read(document, d, "CreationDate"))
        a.modified = PdfDate.parse(PdfText.read(document, d, "M"))
        a.flags = AnnotationFlags(rawValue: document.integer(d, "F") ?? 0)
        a.color = colorOf(document, d["C"], shared)
        a.interiorColor = colorOf(document, d["IC"], shared)
        a.opacity = min(max(document.number(d, "CA") ?? 1, 0), 1)
        a.border = border(document, d, shared)
        a.inReplyTo = d["IRT"] as? PdfReference
        a.replyType = document.name(d, "RT")
        a.state = state(document, d)
        a.quadPoints = numbers(document, d["QuadPoints"], shared)
        a.inkList = inkList(document, d, shared)
        a.vertices = numbers(document, d["Vertices"], shared)
        a.line = numbers(document, d["L"], shared)
        a.startEnding = start
        a.endEnding = end
        a.callout = numbers(document, d["CL"], shared)
        a.intent = document.name(d, "IT")
        a.rectDifference = numbers(document, d["RD"], shared)
        if let be, document.name(be, "S") == "C" {
            a.cloud = Int(min(max(document.number(be, "I") ?? 1, 0), 2))
        }
        a.defaultAppearance = PdfText.read(document, d, "DA")
        a.defaultStyle = PdfText.read(document, d, "DS")
        a.richText = PdfText.read(document, d, "RC")
        // The C# casts the long to int without a check.
        a.alignment = Int(Int32(truncatingIfNeeded: document.integer(d, "Q") ?? 0))
        a.iconName = (document.resolve(d["Name"]) as? PdfName)?.text
        a.popup = d["Popup"] as? PdfReference
        a.hasAppearance = document.dict(d, "AP")?["N"] != nil
        return a
    }

    static func numbers(_ document: PdfDocument, _ value: PdfObject?) -> [Double] {
        numbers(document, value, Shared())
    }

    private static func numbers(_ document: PdfDocument, _ value: PdfObject?, _ shared: Shared) -> [Double] {
        guard let array = document.resolve(value) as? PdfArray else { return [] }
        if let known = shared.numbers[ObjectIdentifier(array)] { return known.values }
        var numbers: [Double] = []
        numbers.reserveCapacity(min(array.items.count, 64))
        for item in array.items.prefix(maxNumbers) {
            if let number = document.resolve(item) as? PdfNumber, number.value.isFinite {
                numbers.append(number.value)
            } else {
                numbers.append(0)
            }
        }
        shared.numbers[ObjectIdentifier(array)] = (array, numbers)
        return numbers
    }

    private static func colorOf(_ document: PdfDocument, _ value: PdfObject?, _ shared: Shared) -> [Double]? {
        guard document.resolve(value) is PdfArray else { return nil }
        let color = numbers(document, value, shared)
        return [0, 1, 3, 4].contains(color.count) ? color : nil
    }

    private static func border(_ document: PdfDocument, _ d: PdfDictionary, _ shared: Shared) -> AnnotationBorder {
        if let bs = document.dict(d, "BS") {
            let style: BorderStyle
            switch document.name(bs, "S") {
            case "D": style = .dashed
            case "B": style = .beveled
            case "I": style = .inset
            case "U": style = .underline
            default: style = .solid
            }
            let dash = style == .dashed ? dashOf(numbers(document, bs["D"], shared)) : []
            return AnnotationBorder(max(0, document.number(bs, "W") ?? 1), style, dash)
        }
        if let border = document.array(d, "Border"), border.items.count >= 3 {
            var width = 1.0
            if let w = document.resolve(border.items[2]) as? PdfNumber { width = max(0, w.value) }
            let dash = border.items.count > 3 ? dashOf(numbers(document, border.items[3], shared)) : []
            return AnnotationBorder(width, dash.isEmpty ? .solid : .dashed, dash)
        }
        return AnnotationBorder(1, .solid, [])
    }

    private static func dashOf(_ dash: [Double]) -> [Double] { dash.isEmpty ? [3] : dash }

    private static func state(_ document: PdfDocument, _ d: PdfDictionary) -> ReviewStatus? {
        guard let state = PdfText.read(document, d, "State") else { return nil }
        return ReviewStatus(rawValue: state)
    }

    private static func inkList(_ document: PdfDocument, _ d: PdfDictionary, _ shared: Shared) -> [[Double]] {
        guard let list = document.resolve(d["InkList"]) as? PdfArray else { return [] }
        if let known = shared.inks[ObjectIdentifier(list)] { return known.values }
        let strokes = list.items.prefix(maxAnnotations).map { numbers(document, $0, shared) }
        shared.inks[ObjectIdentifier(list)] = (list, strokes)
        return strokes
    }

    private static func endings(_ document: PdfDocument, _ d: PdfDictionary) -> (start: LineEnding, end: LineEnding) {
        let value = document.resolve(d["LE"])
        if let single = value as? PdfName { return (lineEndingOf(single.value), .none) }
        guard let array = value as? PdfArray, !array.items.isEmpty else { return (.none, .none) }
        let first = lineEndingOf((document.resolve(array.items[0]) as? PdfName)?.value)
        let second = array.items.count > 1 ? lineEndingOf((document.resolve(array.items[1]) as? PdfName)?.value) : LineEnding.none
        return (first, second)
    }

    static func lineEndingOf(_ name: String?) -> LineEnding {
        guard let name else { return .none }
        return LineEnding(rawValue: name) ?? .none
    }
}
