import Foundation

// Twin of windows/LazyPDF.Core/Accessibility/PdfUaChecker.cs: the rule checks behind PdfUaValidator. Each `add` names the
// Matterhorn failure condition and the clause of ISO 14289-1 behind it; checkpoints come out in order because the report
// sorts by condition, keeping the order the checks ran in within one. The C# partial class is split into extensions in
// PdfUaChecker.Structure.swift, .Content.swift and .Annotations.swift.

final class PdfUaChecker {
    static let maxIssues = 1000
    static let maxEntries = 10_000

    let document: PdfDocument
    private var issues: [PdfUaIssue] = []
    private var seen = Set<[UInt8]>()
    private var truncated = false
    var tree: StructureTree?

    init(_ document: PdfDocument) {
        self.document = document
    }

    func report() -> PdfUaReport {
        let sorted = issues.enumerated().sorted { a, b in
            let order = Array(a.element.condition.utf8).lexicographicallyPrecedes(Array(b.element.condition.utf8))
            return order || (a.element.condition == b.element.condition && a.offset < b.offset)
        }
        return PdfUaReport(sorted.map { $0.element }, truncated)
    }

    func run() throws {
        checkMarkInfo()
        tree = StructureTree.read(document)
        checkTree()
        try checkContent()
        checkMetadata()
        checkDisplayTitle()
        checkLanguage()
        checkStructure()
        checkOptionalContent()
        checkEmbeddedFiles()
        checkForm()
        checkSecurity()
        checkAnnotations()
        checkXObjects()
    }

    func add(_ condition: String, _ clause: String, _ place: String, _ message: String) {
        if issues.count >= Self.maxIssues {
            truncated = true
            return
        }
        if seen.insert(Array("\(condition)|\(place)|\(message)".utf8)).inserted { issues.append(PdfUaIssue(condition, clause, place, message)) }
    }

    static func place(_ element: StructElement) -> String {
        if let reference = element.reference { return PdfAText.structureElement(reference.number) }
        let page = pageOf(element)
        return page >= 0 ? PdfAText.pageName(page + 1) : PdfAText.catalog
    }

    private static func pageOf(_ element: StructElement) -> Int {
        if element.pageIndex >= 0 { return element.pageIndex }
        for kid in element.kids {
            if let content = kid as? StructContent, content.pageIndex >= 0 { return content.pageIndex }
            if let target = kid as? StructObject, target.pageIndex >= 0 { return target.pageIndex }
        }
        return -1
    }

    private func checkMarkInfo() {
        let info = document.dict(document.catalog, "MarkInfo")
        if document.bool(info, "Marked") != true { add("01-001", "7.1", PdfAText.catalog, PdfUaText.noMarkInfo) }
        if document.bool(info, "Suspects") == true { add("01-006", "7.1", PdfAText.catalog, PdfUaText.suspects) }
    }

    private func checkTree() {
        if let tree {
            if tree.isTruncated { add("01-002", "7.1", PdfAText.catalog, PdfUaText.structTreeTooBig) }
        } else {
            add("01-002", "7.1", PdfAText.catalog, PdfUaText.noStructTree)
        }
    }

    // 7.1: the catalog's XMP names PDF/UA and carries the title.
    private func checkMetadata() {
        guard let stream = document.stream(document.catalog, "Metadata") else {
            add("06-001", "7.1", PdfAText.catalog, PdfUaText.noMetadata)
            return
        }
        var xmp: PdfAXmp?
        var problem: String?
        if let bytes = try? document.data(stream, 16 << 20) {
            (xmp, problem) = PdfAXmp.parse(bytes)
        } else {
            problem = PdfAText.xmpNotWellFormed
        }
        guard let xmp else {
            add("06-001", "7.1", PdfAText.metadata, problem ?? "")
            return
        }
        if xmp.get(XmpPacket.pdfuaId, "part").map({ DotNetText.trim($0) }) != "1" { add("06-002", "7.1", PdfAText.metadata, PdfUaText.noIdentifier) }
        if DotNetText.isNullOrWhiteSpace(xmp.get(PdfAXmp.dc, "title")) { add("06-003", "7.1", PdfAText.metadata, PdfUaText.noTitle) }
    }

    private func checkDisplayTitle() {
        if !ViewerSettings.read(document).displayDocTitle { add("07-001", "7.1", PdfAText.catalog, PdfUaText.titleNotShown) }
    }

    // 7.2: the language of the text can be told, from the catalog or from every top structure element.
    private func checkLanguage() {
        let language = PdfText.read(document, document.catalog, "Lang")
        let valid = language.map { AccessibilityChecker.isLanguageTag($0) } ?? false
        if let language, !valid { add("11-006", "7.2", PdfAText.catalog, PdfUaText.badLanguage(language)) }
        if valid { return }
        if language == nil { add("11-006", "7.2", PdfAText.catalog, PdfUaText.noLanguage) }
        let roots = tree.map { !$0.roots.isEmpty && $0.roots.allSatisfy { $0.lang.map { AccessibilityChecker.isLanguageTag($0) } ?? false } } ?? false
        if !roots { add("11-001", "7.2", PdfAText.catalog, PdfUaText.textLanguage) }
    }

    // 7.10: configurations have a name and no automatic state.
    private func checkOptionalContent() {
        guard let properties = document.dict(document.catalog, "OCProperties") else { return }
        var configs: [PdfDictionary] = []
        if let main = document.dict(properties, "D") { configs.append(main) }
        configs += (document.array(properties, "Configs")?.items.prefix(256) ?? []).compactMap { document.resolve($0) as? PdfDictionary }
        for config in configs {
            let named = (document.resolve(config["Name"]) as? PdfString).map { !$0.bytes.isEmpty } ?? false
            if !named { add("20-001", "7.10", PdfAText.catalog, PdfUaText.configName) }
            if config.containsKey("AS") { add("20-002", "7.10", PdfAText.catalog, PdfUaText.configAutoState) }
        }
    }

    // 7.11: a file specification names the file twice, as F and as UF.
    private func checkEmbeddedFiles() {
        let names = document.dict(document.catalog, "Names")
        let files: [(key: String, value: PdfObject)] = PdfNameTree.read(document, names?["EmbeddedFiles"])
        for entry in files.prefix(Self.maxEntries) { checkFileSpec(entry.value) }
    }

    func checkFileSpec(_ value: PdfObject?) {
        if let spec = document.resolve(value) as? PdfDictionary, !spec.containsKey("F") || !spec.containsKey("UF") { add("21-001", "7.11", PdfAText.catalog, PdfUaText.fileSpec) }
    }

    // 7.15: a dynamic XFA form, one the viewer builds as it opens, has no structure to tag.
    private func checkForm() {
        if let form = document.dict(document.catalog, "AcroForm"), form.containsKey("XFA"), document.bool(document.catalog, "NeedsRendering") == true {
            add("25-001", "7.15", PdfAText.form, PdfUaText.xfa)
        }
    }

    // 7.16: the extraction-for-accessibility permission is not withheld.
    private func checkSecurity() {
        if let security = document.security, !security.permissions.contains(.extractForAccessibility) {
            add("26-001", "7.16", PdfAText.catalog, PdfUaText.encrypted)
        }
    }
}
