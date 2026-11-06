import Foundation

// Twin of windows/LazyPDF.Core/Standards/PdfAChecker.cs: the rule checks behind PdfAValidator. Clause numbers are given for
// part 1 and for parts 2 and 3; part 4 follows the numbering of part 2.
//
// The C# class is partial; the parts are extensions in this folder. Swift keeps stored properties in the type's own
// declaration, so the state of every part is listed here. The hash sets of the C# that compare by reference hold
// ObjectIdentifiers; FontUses keeps the order the fonts were met in, as a .NET Dictionary does, because the issues of the
// fonts are listed in it.

final class PdfAChecker {
    static let maxIssues = 1000

    let document: PdfDocument
    let level: PdfALevel
    var issues: [PdfAIssue] = []
    var seen = Set<[UInt8]>()
    var truncated = false

    /// The fonts met, each with the codes (CIDs for a composite font) shown with it, in the order they were met.
    private(set) var fonts: [PdfDictionary] = []
    private var fontUses: [ObjectIdentifier: SortedInts] = [:]

    // Budget
    var formCosts: [ObjectIdentifier: FormCost] = [:]
    var cachedForms = Set<ObjectIdentifier>()
    var skippingForms = Set<ObjectIdentifier>()
    var cachedOperations = 0

    /// Bytes of content read and operations run, all pages, forms and appearances together; the interpreter limits one run only.
    var work = 0

    /// Overrides the work allowed; by default 1 GiB plus 16 units for each byte of the file, so a long file is not cut short for its length.
    var maxWork: Int?

    // Content
    var resourcesSeen = Set<ObjectIdentifier>()
    var streamsSeen = Set<ObjectIdentifier>()
    var deviceUses = Set<DeviceUse>()
    var renderedFonts = Set<ObjectIdentifier>()
    var separations: [String: String] = [:]
    var scanDepth = 0

    /// Colour components of the output intent's profile; 0 when the file has none.
    var intentComponents = 0

    // Annotations
    var nextLists = Set<ObjectIdentifier>()
    var appearancesRun = Set<ObjectIdentifier>()
    var actionsSeen = Set<ObjectIdentifier>()

    // Glyphs
    var textScanned = Set<ObjectIdentifier>()
    var textPainted = Set<ObjectIdentifier>()
    var proceduresScanned: [ObjectIdentifier: Bool] = [:]
    var masksApplied = Set<ObjectIdentifier>()

    init(_ document: PdfDocument, _ level: PdfALevel) {
        self.document = document
        self.level = level
    }

    var part: Int { level.part() }
    var isPart1: Bool { part == 1 }

    func uses(_ font: PdfDictionary) -> SortedInts? { fontUses[ObjectIdentifier(font)] }

    func usesOf(_ font: PdfDictionary) -> SortedInts {
        if let known = fontUses[ObjectIdentifier(font)] { return known }
        let created = SortedInts()
        fontUses[ObjectIdentifier(font)] = created
        fonts.append(font)
        return created
    }

    func report() -> PdfAReport { PdfAReport(level, issues, truncated) }

    func run() {
        checkFile()
        checkCatalog()
        checkPages()
        checkObjects()
        checkFonts()
    }

    /// The clause for part 1, or for the later parts.
    func c(_ part1: String, _ later: String) -> String { isPart1 ? part1 : later }

    func add(_ clause: String, _ place: String, _ message: String) {
        if issues.count >= Self.maxIssues {
            truncated = true
            return
        }
        if seen.insert(Array("\(clause)|\(place)|\(message)".utf8)).inserted { issues.append(PdfAIssue(clause, place, message)) }
    }

    func filterNames(_ dictionary: PdfDictionary, _ key: String = "Filter") -> [String] {
        switch document.resolve(dictionary[key]) {
        case let name as PdfName: return [name.value]
        case let array as PdfArray: return array.items.prefix(32).map { (document.resolve($0) as? PdfName)?.value ?? "" }
        default: return []
        }
    }

    static func isFilter(_ name: String, _ full: String, _ abbreviation: String) -> Bool { name == full || name == abbreviation }
}
