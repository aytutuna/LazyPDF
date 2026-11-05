import Foundation

// Twin of windows/LazyPDF.Core/Structure/Actions.cs: actions (ISO 32000-1 12.6). The C# records are final classes here,
// derived from `PdfAction` as they are there; `next` is set after the action is made, where the C# says `with { Next = ... }`.

/// An action. `next` are the actions that follow it, in order.
public class PdfAction {
    public var next: [PdfAction] = []

    init() {}
}

public final class GoToAction: PdfAction {
    public let destination: PdfDestination

    public init(_ destination: PdfDestination) {
        self.destination = destination
        super.init()
    }
}

/// Go to a place in another file. `destination` holds a page number there, or a name that is not resolved here.
public final class GoToRemoteAction: PdfAction {
    public let file: String
    public let destination: PdfDestination?
    public let newWindow: Bool?

    public init(_ file: String, _ destination: PdfDestination?, _ newWindow: Bool?) {
        self.file = file
        self.destination = destination
        self.newWindow = newWindow
        super.init()
    }
}

public final class LaunchAction: PdfAction {
    public let file: String?
    public let newWindow: Bool?

    public init(_ file: String?, _ newWindow: Bool?) {
        self.file = file
        self.newWindow = newWindow
        super.init()
    }
}

public final class UriAction: PdfAction {
    public let uri: String

    public init(_ uri: String) {
        self.uri = uri
        super.init()
    }
}

/// NextPage, PrevPage, FirstPage, LastPage or a menu command the viewer may know.
public final class NamedAction: PdfAction {
    public let name: String

    public init(_ name: String) {
        self.name = name
        super.init()
    }
}

public final class JavaScriptAction: PdfAction {
    public let script: String

    public init(_ script: String) {
        self.script = script
        super.init()
    }
}

/// `flags` are the /Flags bits of table 237; `fields` the names it lists (none: every field).
public final class SubmitFormAction: PdfAction {
    public let url: String
    public let flags: Int
    public let fields: [String]

    public init(_ url: String, _ flags: Int, _ fields: [String]) {
        self.url = url
        self.flags = flags
        self.fields = fields
        super.init()
    }
}

public final class ResetFormAction: PdfAction {
    public let flags: Int
    public let fields: [String]

    public init(_ flags: Int, _ fields: [String]) {
        self.flags = flags
        self.fields = fields
        super.init()
    }
}

/// An action this layer does not unpack: Hide, ImportData, SetOCGState, Sound, Movie, Rendition, Thread, Trans, GoToE,
/// GoTo3DView and the like.
public final class OtherAction: PdfAction {
    public let type: String

    public init(_ type: String) {
        self.type = type
        super.init()
    }
}

/// An additional action of an object (/AA): the event key ("WC", "O", "E", "Fo"...) and what it runs.
public struct PdfTrigger {
    public let event: String
    public let action: PdfAction

    public init(_ event: String, _ action: PdfAction) {
        self.event = event
        self.action = action
    }
}

public struct NamedScript {
    public let name: String
    public let script: String

    public init(_ name: String, _ script: String) {
        self.name = name
        self.script = script
    }
}

/// What a document runs by itself: its open action, its events and the scripts of its name tree.
public struct DocumentActions {
    public let openAction: PdfAction?
    public let triggers: [PdfTrigger]
    public let scripts: [NamedScript]

    public init(_ openAction: PdfAction?, _ triggers: [PdfTrigger], _ scripts: [NamedScript]) {
        self.openAction = openAction
        self.triggers = triggers
        self.scripts = scripts
    }
}

public enum PdfActions {
    private static let maxActions = 64
    private static let maxDepth = maxActions
    private static let maxAnnotations = 50_000

    /// The action in `value` (a dictionary), with the actions that follow it. At most 64 are read and a chain that
    /// loops stops at the repeat. Nil when it has no known /S.
    public static func read(_ document: PdfDocument, _ value: PdfObject?) -> PdfAction? {
        read(document, value, DestContext(document))
    }

    static func read(_ document: PdfDocument, _ value: PdfObject?, _ context: DestContext) -> PdfAction? {
        var budget = maxActions
        var seen = Set<Int>()
        return read(document, value, context, &seen, 0, &budget)
    }

    private static func read(_ document: PdfDocument, _ value: PdfObject?, _ context: DestContext,
                             _ seen: inout Set<Int>, _ depth: Int, _ budget: inout Int) -> PdfAction? {
        if depth > maxDepth || budget <= 0 { return nil }
        if let reference = value as? PdfReference, !seen.insert(reference.number).inserted { return nil }
        guard let dictionary = document.resolve(value) as? PdfDictionary, let type = document.name(dictionary, "S") else { return nil }
        budget -= 1

        var next: [PdfAction] = []
        let follow = document.resolve(dictionary["Next"])
        var items: [PdfObject?] = []
        if let array = follow as? PdfArray {
            items = array.items
        } else if follow != nil {
            items = [dictionary["Next"]]
        }
        for item in items {
            if let action = read(document, item, context, &seen, depth + 1, &budget) { next.append(action) }
        }

        // An action that cannot be built still hands its chain on: a script that follows it is still in the file.
        guard let result = make(document, dictionary, type, context) else {
            if next.isEmpty { return nil }
            let other = OtherAction(type)
            other.next = next
            return other
        }
        result.next = next
        return result
    }

    private static func make(_ document: PdfDocument, _ dictionary: PdfDictionary, _ type: String, _ context: DestContext) -> PdfAction? {
        switch type {
        case "GoTo":
            return PdfDestinations.parse(document, dictionary["D"], context).map { GoToAction($0) }
        case "GoToR":
            return GoToRemoteAction(fileName(document, dictionary["F"]) ?? "", PdfDestinations.parse(document, dictionary["D"], context, remote: true),
                                    document.bool(dictionary, "NewWindow"))
        case "Launch":
            return LaunchAction(fileName(document, dictionary["F"]), document.bool(dictionary, "NewWindow"))
        case "URI":
            guard let uri = document.resolve(dictionary["URI"]) as? PdfString else { return nil }
            return UriAction(uriText(uri.bytes))
        case "Named":
            return NamedAction(document.name(dictionary, "N") ?? "")
        case "JavaScript":
            return JavaScriptAction(PdfText.read(document, dictionary["JS"]) ?? "")
        case "SubmitForm":
            return SubmitFormAction(fileName(document, dictionary["F"]) ?? "", flags(document, dictionary), fields(document, dictionary))
        case "ResetForm":
            return ResetFormAction(flags(document, dictionary), fields(document, dictionary))
        default:
            return OtherAction(type)
        }
    }

    // The C# casts the long to int, which wraps.
    private static func flags(_ document: PdfDocument, _ dictionary: PdfDictionary) -> Int {
        Int(Int32(truncatingIfNeeded: document.integer(dictionary, "Flags") ?? 0))
    }

    /// The action to store for `action`, with its chain. An `OtherAction` cannot be written.
    public static func toObject(_ document: PdfDocument, _ action: PdfAction) throws -> PdfDictionary {
        let d = PdfDictionary()
        d["Type"] = PdfName("Action")
        switch action {
        case let a as GoToAction:
            d["S"] = PdfName("GoTo")
            guard let destination = PdfDestinations.toObject(document, a.destination) else {
                throw ArgumentException("The destination has no page in the document.")
            }
            d["D"] = destination
        case let a as GoToRemoteAction:
            d["S"] = PdfName("GoToR")
            d["F"] = PdfText.toObject(a.file)
            if let destination = a.destination, let value = PdfDestinations.toObject(document, destination, remote: true) { d["D"] = value }
            if let w = a.newWindow { d["NewWindow"] = PdfBoolean(w) }
        case let a as LaunchAction:
            d["S"] = PdfName("Launch")
            if let file = a.file { d["F"] = PdfText.toObject(file) }
            if let w = a.newWindow { d["NewWindow"] = PdfBoolean(w) }
        case let a as UriAction:
            d["S"] = PdfName("URI")
            d["URI"] = PdfString(bytes: Array(a.uri.utf8), isHex: false)
        case let a as NamedAction:
            d["S"] = PdfName("Named")
            d["N"] = PdfName(a.name)
        case let a as JavaScriptAction:
            d["S"] = PdfName("JavaScript")
            d["JS"] = PdfText.toObject(a.script)
        case let a as SubmitFormAction:
            d["S"] = PdfName("SubmitForm")
            let spec = PdfDictionary()
            spec["FS"] = PdfName("URL")
            spec["F"] = PdfText.toFileName(a.url)
            d["F"] = spec
            setFields(d, a.flags, a.fields)
        case let a as ResetFormAction:
            d["S"] = PdfName("ResetForm")
            setFields(d, a.flags, a.fields)
        default:
            throw ArgumentException("This kind of action cannot be written.")
        }
        if action.next.count == 1 {
            d["Next"] = try toObject(document, action.next[0])
        } else if action.next.count > 1 {
            d["Next"] = PdfArray(try action.next.map { try toObject(document, $0) as PdfObject })
        }
        return d
    }

    /// The additional actions (/AA) of a catalog, page, annotation or field.
    public static func triggers(_ document: PdfDocument, _ owner: PdfDictionary?) -> [PdfTrigger] {
        var triggers: [PdfTrigger] = []
        guard let events = document.dict(owner, "AA") else { return triggers }
        let context = DestContext(document)
        for entry in events.entries.prefix(maxActions) {
            if let action = read(document, entry.value, context) { triggers.append(PdfTrigger(entry.key, action)) }
        }
        return triggers
    }

    /// The open action, the document events (/AA of the catalog) and the /Names /JavaScript scripts.
    public static func readDocument(_ document: PdfDocument) -> DocumentActions {
        let context = DestContext(document)
        var open: PdfAction?
        if let array = document.resolve(document.catalog["OpenAction"]) as? PdfArray {
            if let destination = PdfDestinations.parse(document, array, context) { open = GoToAction(destination) }
        } else {
            open = read(document, document.catalog["OpenAction"], context)
        }

        var scripts: [NamedScript] = []
        let tree = document.dict(document.dict(document.catalog, "Names"), "JavaScript")
        for entry in PdfNameTree.read(document, tree) {
            if let script = read(document, entry.value, context) as? JavaScriptAction {
                scripts.append(NamedScript(PdfNameTree.textOf(entry.key), script.script))
            }
        }
        return DocumentActions(open, triggers(document, document.catalog), scripts)
    }

    /// Whether anything in the file can run a script: the open action, the document events, the script tree, and the
    /// actions and events of pages, links and form widgets (up to 50000 annotations).
    public static func hasJavaScript(_ document: PdfDocument) -> Bool {
        let context = DestContext(document)
        func runs(_ owner: PdfDictionary?) -> Bool {
            guard let owner else { return false }
            if let a = read(document, owner["A"], context), containsScript(a) { return true }
            return triggers(document, owner).contains { containsScript($0.action) }
        }

        let all = readDocument(document)
        if !all.scripts.isEmpty || (all.openAction.map { containsScript($0) } ?? false) || all.triggers.contains(where: { containsScript($0.action) }) {
            return true
        }
        var annotations = 0
        for page in document.pages {
            if runs(page.dictionary) { return true }
            guard let annots = document.array(page.dictionary, "Annots") else { continue }
            for item in annots.items {
                annotations += 1
                if annotations > maxAnnotations { return false }
                if runs(document.resolve(item) as? PdfDictionary) { return true }
            }
        }
        return false
    }

    private static func containsScript(_ action: PdfAction) -> Bool {
        action is JavaScriptAction || action.next.contains { containsScript($0) }
    }

    /// The file name of a file specification: a string, or the /UF or /F of a dictionary.
    static func fileName(_ document: PdfDocument, _ value: PdfObject?) -> String? {
        switch document.resolve(value) {
        case let s as PdfString: return PdfText.decode(s.bytes)
        case let d as PdfDictionary: return PdfText.read(document, d, "UF") ?? PdfText.read(document, d, "F")
        default: return nil
        }
    }

    private static func uriText(_ bytes: [UInt8]) -> String {
        var decoder = UTF8()
        var iterator = bytes.makeIterator()
        var text = String.UnicodeScalarView()
        while true {
            switch decoder.decode(&iterator) {
            case .scalarValue(let scalar): text.append(scalar)
            case .emptyInput: return String(text)
            case .error: return Latin1.string(bytes)
            }
        }
    }

    private static func fields(_ document: PdfDocument, _ action: PdfDictionary) -> [String] {
        var names: [String] = []
        guard let fields = document.array(action, "Fields") else { return names }
        for item in fields.items.prefix(10_000) {
            switch document.resolve(item) {
            case let s as PdfString:
                names.append(PdfText.decode(s.bytes))
            case let field as PdfDictionary:
                if let name = PdfText.read(document, field, "T") { names.append(name) }
            default:
                break
            }
        }
        return names
    }

    private static func setFields(_ action: PdfDictionary, _ flags: Int, _ fields: [String]) {
        if flags != 0 { action["Flags"] = PdfNumber(flags) }
        if !fields.isEmpty { action["Fields"] = PdfArray(fields.map { PdfText.toObject($0) }) }
    }
}
