import Foundation

// Twin of windows/LazyPDF.Core/Structure/Destinations.cs: destinations: explicit arrays, named ones in /Dests and the
// /Names /Dests tree, and where they land.

/// How a destination (ISO 32000-1 12.3.2.2, table 151) places the page in the window.
public enum DestinationFit: Int {
    case xyz, fit, fitH, fitV, fitR, fitB, fitBH, fitBV
}

/// A place in a document. `pageIndex` counts from 0 (-1 when the page is not there); the numbers are in user space as
/// the file has them, and only those the fit uses are set. A destination given by name keeps it in `name` (a byte
/// string, one character per byte) next to what the name resolved to.
public struct PdfDestination: Equatable {
    public var pageIndex: Int
    public var fit: DestinationFit
    public var left: Double?
    public var bottom: Double?
    public var right: Double?
    public var top: Double?
    public var zoom: Double?
    public var name: String?

    public init(_ pageIndex: Int, _ fit: DestinationFit = .fit, left: Double? = nil, bottom: Double? = nil,
                right: Double? = nil, top: Double? = nil, zoom: Double? = nil, name: String? = nil) {
        self.pageIndex = pageIndex
        self.fit = fit
        self.left = left
        self.bottom = bottom
        self.right = right
        self.top = top
        self.zoom = zoom
        self.name = name
    }
}

/// Where a destination lands on its page, in display points from the top-left of the page as shown.
public struct DestinationPoint: Equatable {
    public let pageIndex: Int
    public let x: Double
    public let y: Double
    public let zoom: Double?

    public init(_ pageIndex: Int, _ x: Double, _ y: Double, _ zoom: Double?) {
        self.pageIndex = pageIndex
        self.x = x
        self.y = y
        self.zoom = zoom
    }
}

/// The page positions and named destinations of a document, taken once so that reading a long list of destinations
/// does not walk the tree and the name tree again for each.
final class DestContext {
    private let document: PdfDocument
    private var index: [Int: Int]?
    private var names: [String: PdfObject]?

    init(_ document: PdfDocument) {
        self.document = document
    }

    func indexOf(_ page: PdfObject?) -> Int {
        if index == nil {
            var built: [Int: Int] = [:]
            for p in document.pages where built[p.reference.number] == nil { built[p.reference.number] = p.index }
            index = built
        }
        guard let reference = page as? PdfReference else { return -1 }
        return index?[reference.number] ?? -1
    }

    func lookUp(_ name: String) -> PdfObject? {
        if names == nil {
            var built: [String: PdfObject] = [:]
            for entry in PdfNameTree.read(document, document.dict(document.dict(document.catalog, "Names"), "Dests")) { built[entry.key] = entry.value }
            if let dests = document.dict(document.catalog, "Dests") {
                for entry in dests.entries.prefix(100_000) where built[entry.key] == nil { built[entry.key] = entry.value }
            }
            names = built
        }
        return names?[name]
    }
}

public enum PdfDestinations {
    private static let fitNames = ["XYZ", "Fit", "FitH", "FitV", "FitR", "FitB", "FitBH", "FitBV"]

    /// A destination from an array, a dictionary with /D, or a name or string looked up in the document's named
    /// destinations. `remote` is for the target of another file (the page is a number there, and a name is not looked
    /// up here). Nil when it is none of these.
    public static func parse(_ document: PdfDocument, _ value: PdfObject?, remote: Bool = false) -> PdfDestination? {
        parse(document, value, DestContext(document), remote: remote)
    }

    static func parse(_ document: PdfDocument, _ value: PdfObject?, _ context: DestContext, remote: Bool = false) -> PdfDestination? {
        switch document.resolve(value) {
        case let array as PdfArray:
            return fromArray(document, array, context, remote)
        case let dictionary as PdfDictionary:
            guard let inner = document.resolve(dictionary["D"]) as? PdfArray else { return nil }
            return fromArray(document, inner, context, remote)
        case let name as PdfName:
            return remote ? PdfDestination(-1, name: name.value) : named(document, name.value, context)
        case let text as PdfString:
            let key = Latin1.string(text.bytes)
            return remote ? PdfDestination(-1, name: key) : named(document, key, context)
        default:
            return nil
        }
    }

    // An unknown name stays a destination without a page, so the item that used it keeps it.
    private static func named(_ document: PdfDocument, _ name: String, _ context: DestContext) -> PdfDestination {
        var found: PdfDestination?
        switch document.resolve(context.lookUp(name)) {
        case let array as PdfArray:
            found = fromArray(document, array, context, false)
        case let dictionary as PdfDictionary:
            if let inner = document.resolve(dictionary["D"]) as? PdfArray { found = fromArray(document, inner, context, false) }
        default:
            break
        }
        var result = found ?? PdfDestination(-1)
        result.name = name
        return result
    }

    private static func fromArray(_ document: PdfDocument, _ array: PdfArray, _ context: DestContext, _ remote: Bool) -> PdfDestination? {
        guard array.items.count >= 2, let kind = document.resolve(array.items[1]) as? PdfName,
              let fitIndex = fitNames.firstIndex(of: kind.value), let fit = DestinationFit(rawValue: fitIndex) else { return nil }
        let page: Int
        if remote {
            if let n = (document.resolve(array.items[0]) as? PdfNumber)?.integer, n >= 0, n <= Int(Int32.max) { page = n } else { page = -1 }
        } else {
            page = context.indexOf(array.items[0])
        }

        func n(_ i: Int) -> Double? {
            guard i < array.items.count, let number = document.resolve(array.items[i]) as? PdfNumber, number.value.isFinite else { return nil }
            return number.value
        }
        switch fit {
        case .xyz: return PdfDestination(page, .xyz, left: n(2), top: n(3), zoom: n(4))
        case .fitH, .fitBH: return PdfDestination(page, fit, top: n(2))
        case .fitV, .fitBV: return PdfDestination(page, fit, left: n(2))
        case .fitR: return PdfDestination(page, .fitR, left: n(2), bottom: n(3), right: n(4), top: n(5))
        default: return PdfDestination(page, fit)
        }
    }

    /// The value to store for a destination: its name when it has one (a string, or a name where the document keeps
    /// its destinations in a /Dests dictionary only), else the array. Nil for a page that is not in the document.
    public static func toObject(_ document: PdfDocument, _ destination: PdfDestination, remote: Bool = false) -> PdfObject? {
        if let name = destination.name {
            let oldStyle = treeRoot(document) == nil && document.dict(document.catalog, "Dests")?.containsKey(name) == true
            return oldStyle ? PdfName(name) : PdfString(bytes: Latin1.bytes(name), isHex: false)
        }
        let page: PdfObject
        if remote {
            page = PdfNumber(Swift.max(0, destination.pageIndex))
        } else if destination.pageIndex >= 0 && destination.pageIndex < document.pages.count {
            page = document.pages[destination.pageIndex].reference
        } else {
            return nil
        }

        var items: [PdfObject] = [page, PdfName(fitNames[destination.fit.rawValue])]
        func n(_ v: Double?) -> PdfObject {
            if let x = v, x.isFinite { return PdfNumber(x) }
            return PdfNull.instance
        }
        switch destination.fit {
        case .xyz:
            items.append(contentsOf: [n(destination.left), n(destination.top), (destination.zoom ?? 0) > 0 ? n(destination.zoom) : PdfNull.instance])
        case .fitH, .fitBH:
            items.append(n(destination.top))
        case .fitV, .fitBV:
            items.append(n(destination.left))
        case .fitR:
            items.append(contentsOf: [n(destination.left), n(destination.bottom), n(destination.right), n(destination.top)])
        default:
            break
        }
        return PdfArray(items)
    }

    /// Where the destination lands on its page as shown (crop box, rotation and user unit applied), kept inside the
    /// page. A missing coordinate is the page's own edge. Nil when the page is not there.
    public static func locate(_ document: PdfDocument, _ destination: PdfDestination) -> DestinationPoint? {
        if destination.pageIndex < 0 || destination.pageIndex >= document.pages.count { return nil }
        let page = document.pages[destination.pageIndex]
        let box = page.cropBox
        let geometry = PageGeometry(page)
        var x = box.left, y = box.top
        switch destination.fit {
        case .xyz, .fitR:
            x = destination.left ?? x
            y = destination.top ?? y
        case .fitH, .fitBH:
            y = destination.top ?? y
        case .fitV, .fitBV:
            x = destination.left ?? x
        default:
            break
        }
        let (dx, dy) = geometry.toDisplay(x, y)
        let zoom: Double? = destination.fit == .xyz && (destination.zoom ?? 0) > 0 ? destination.zoom : nil
        return DestinationPoint(destination.pageIndex, clamp(dx, 0, geometry.width), clamp(dy, 0, geometry.height), zoom)
    }

    // Math.Clamp: a NaN stays a NaN.
    private static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        value < low ? low : (value > high ? high : value)
    }

    /// Every named destination: the /Dests dictionary (ISO 32000-1 12.3.2.3, files before 1.2), then the /Names /Dests
    /// tree. A name in both counts once, as the tree has it.
    public static func named(_ document: PdfDocument) -> [(key: String, value: PdfDestination)] {
        let context = DestContext(document)
        var found: [String: PdfDestination] = [:]
        var order: [String] = []
        func add(_ name: String, _ value: PdfObject) {
            let resolved = document.resolve(value)
            guard resolved is PdfArray || resolved is PdfDictionary, var destination = parse(document, value, context) else { return }
            if found[name] == nil { order.append(name) }
            destination.name = name
            found[name] = destination
        }
        if let dests = document.dict(document.catalog, "Dests") {
            for entry in dests.entries.prefix(100_000) { add(entry.key, entry.value) }
        }
        for entry in PdfNameTree.read(document, treeRoot(document)) { add(entry.key, entry.value) }
        return order.compactMap { name in found[name].map { (key: name, value: $0) } }
    }

    /// The destination a name stands for, or nil when no such name is defined.
    public static func find(_ document: PdfDocument, _ name: String) -> PdfDestination? {
        let context = DestContext(document)
        return context.lookUp(name) == nil ? nil : named(document, name, context)
    }

    /// Gives `name` a destination: in the /Dests dictionary when it is already there, else in the name tree (made if
    /// the file has none).
    public static func setNamed(_ document: PdfDocument, _ name: String, _ destination: PdfDestination) throws {
        var plain = destination
        plain.name = nil
        guard let value = toObject(document, plain) else {
            throw ArgumentException("The destination has no page in the document.")
        }
        if let old = document.dict(document.catalog, "Dests"), old.containsKey(name) {
            old[name] = value
            return
        }
        var entries = PdfNameTree.read(document, treeRoot(document)).filter { $0.key != name }
        entries.append((key: name, value: value))
        try writeTree(document, entries)
    }

    public static func removeNamed(_ document: PdfDocument, _ name: String) throws -> Bool {
        var removed = document.dict(document.catalog, "Dests")?.remove(name) == true
        let entries = PdfNameTree.read(document, treeRoot(document))
        if entries.contains(where: { $0.key == name }) {
            try writeTree(document, entries.filter { $0.key != name })
            removed = true
        }
        return removed
    }

    private static func treeRoot(_ document: PdfDocument) -> PdfDictionary? {
        document.dict(document.dict(document.catalog, "Names"), "Dests")
    }

    private static func writeTree(_ document: PdfDocument, _ entries: [(key: String, value: PdfObject)]) throws {
        let names = PdfNames.ensure(document)
        let existing = document.dict(names, "Dests")
        let root = try PdfNameTree.write(document, existing, entries)
        if existing == nil { names["Dests"] = try document.add(root) }
    }
}

enum PdfNames {
    /// The catalog's /Names dictionary, made when the file has none.
    static func ensure(_ document: PdfDocument) -> PdfDictionary {
        if let names = document.dict(document.catalog, "Names") { return names }
        let created = PdfDictionary()
        document.catalog["Names"] = created
        return created
    }
}
