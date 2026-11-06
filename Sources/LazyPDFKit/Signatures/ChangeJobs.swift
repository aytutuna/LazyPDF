import Foundation

// Twin of windows/LazyPDF.Core/Signatures/ChangeJobs.cs: the jobs of every object of a document, from one walk over
// all of it starting at the trailer. A key leads to a job through the tables in `child` and `element`; every other key
// leads to a plain use, which no level lets change. Plumbing that only names an object (/CO, the fields of SubmitForm
// and ResetForm, /T of Hide, /Data of a signature reference, the page of a destination) is not a use of it. A /Parent
// names its object only where that object lists the child back; /Parent also carries inheritance (7.7.3.4, 12.7.3.1),
// so any other is a use.

enum JobKind {
    case trailer
    case plain
    case content
    case structure
    case link
    case catalog
    case pageTree
    case page
    case annotList
    case comment
    case form
    case fieldList
    case field
    case appearance
    case value
    case info
    case dss
    case action
    case defaults
}

/// One thing an object is used for. `owner` is the field a drawing or value belongs to (0 for a comment), the depth in /DSS for validation data.
struct Job: Hashable {
    var kind: JobKind
    var owner: Int
    var page: Int

    init(_ kind: JobKind, _ owner: Int = 0, _ page: Int = -1) {
        self.kind = kind
        self.owner = owner
        self.page = page
    }
}

struct FieldNode {
    var number: Int
    var name: String
    var isSignature: Bool
    var hasValue: Bool
    var parent: Int = 0
}

final class Jobs {
    private static let maxVisits = 5_000_000
    private static let maxDepth = 32
    private static let maxFields = 200_000

    private struct Seen: Hashable {
        var number: Int
        var job: Job
    }

    private struct Listed: Hashable {
        var child: Int
        var parent: Int
    }

    // The jobs of one object in the order they were found, which the judgments that take the first one depend on.
    private struct JobList {
        var items: [Job] = []
        var members = Set<Job>()

        mutating func add(_ job: Job) {
            if members.insert(job).inserted { items.append(job) }
        }
    }

    private let document: PdfDocument
    private var jobs: [Int: JobList] = [:]
    private var seen = Set<Seen>()
    private var roles = Set<Int>()
    private var pageIndex: [Int: Int] = [:]
    private var widgetField: [Int: Int] = [:]
    private var listed = Set<Listed>()

    private(set) var fields: [Int: FieldNode] = [:]

    /// False when a cap ended the walk early: the jobs found are then not all there are.
    private(set) var complete = true

    init(_ document: PdfDocument) {
        self.document = document
        let pages = document.pages
        for i in 0..<pages.count {
            let page = pages[i]
            pageIndex[page.reference.number] = i
            roles.insert(page.reference.number)
            for case let annot as PdfReference in document.array(page.dictionary, "Annots")?.items ?? [] {
                roles.insert(annot.number)
                if let dictionary = document.get(annot.number) as? PdfDictionary, let popup = dictionary["Popup"] as? PdfReference {
                    listed.insert(Listed(child: popup.number, parent: annot.number))
                }
            }
        }
        if let form = document.dict(document.catalog, "AcroForm"), let list = document.array(form, "Fields") {
            for case let item as PdfReference in list.items { indexField(item, "", false, 0, 0) }
        }
        roles.formUnion(fields.keys)
        roles.formUnion(widgetField.keys)
        indexTree()
        walk()
    }

    func of(_ number: Int) -> [Job] { jobs[number]?.items ?? [] }

    private func indexField(_ reference: PdfReference, _ prefix: String, _ inheritedSignature: Bool, _ depth: Int, _ parent: Int) {
        if depth > Self.maxDepth || fields.count > Self.maxFields {
            complete = false
            return
        }
        if fields[reference.number] != nil { return }
        guard let dictionary = document.get(reference.number) as? PdfDictionary else { return }
        let name: String
        if let partial = PdfText.read(document, dictionary["T"]) {
            name = prefix.utf16.isEmpty ? partial : prefix + "." + partial
        } else {
            name = prefix
        }
        let signature: Bool
        if let type = document.name(dictionary, "FT") {
            signature = type == "Sig"
        } else {
            signature = inheritedSignature || sigUpwards(dictionary)
        }
        let value = dictionary["V"]
        fields[reference.number] = FieldNode(number: reference.number, name: name, isSignature: signature,
                                             hasValue: value != nil && !(value is PdfNull), parent: parent)
        guard let kids = document.array(dictionary, "Kids") else { return }
        for case let kid as PdfReference in kids.items {
            listed.insert(Listed(child: kid.number, parent: reference.number))
            if let child = document.get(kid.number) as? PdfDictionary, !child.containsKey("T") {
                widgetField[kid.number] = reference.number
            } else {
                indexField(kid, name, signature, depth + 1, reference.number)
            }
        }
    }

    // A reader takes the type from the /Parent chain whether or not a /Kids array lists the field there (12.7.3.1).
    private func sigUpwards(_ start: PdfDictionary) -> Bool {
        var field = start
        var i = 0
        while i < Self.maxDepth, let parent = document.dict(field, "Parent") {
            if let type = document.name(parent, "FT") { return type == "Sig" }
            i += 1
            field = parent
        }
        return false
    }

    // The nodes of the page tree are named by their pages' /Parent, which is not a use of them.
    private func indexTree() {
        var pending: [PdfObject?] = [document.catalog["Pages"]]
        for _ in 0..<Self.maxFields {
            if pending.isEmpty { break }
            guard let r = pending.removeLast() as? PdfReference, roles.insert(r.number).inserted,
                  let node = document.get(r.number) as? PdfDictionary else { continue }
            for kid in document.array(node, "Kids")?.items ?? [] {
                pending.append(kid)
                if let k = kid as? PdfReference { listed.insert(Listed(child: k.number, parent: r.number)) }
            }
        }
        if !pending.isEmpty { complete = false }
    }

    private func walk() {
        let catalog = (document.trailer["Root"] as? PdfReference)?.number ?? 0
        var pending: [(value: PdfObject, context: Job, from: Int)] = [(document.trailer, Job(.trailer), 0)]
        while !pending.isEmpty && seen.count < Self.maxVisits {
            let (value, context, from) = pending.removeLast()
            switch value {
            case let r as PdfReference:
                visit(r, context, &pending)
            case let array as PdfArray:
                for item in array.items.dropFirst(namesPage(array, context) ? 1 : 0) {
                    pending.append((item, element(context, item), from))
                }
            case let dictionary as PdfDictionary:
                for (key, item) in dictionary.entries {
                    if Self.namesFields(dictionary, context, key, item, catalog) { continue }
                    guard var next = Self.child(context, key) else { continue }
                    if next.kind == .link && key == "Parent" {
                        var back = false
                        if let p = item as? PdfReference { back = listed.contains(Listed(child: from, parent: p.number)) }
                        if !back { next = Job(.plain) }
                    }
                    pending.append((item, next, from))
                }
            case let stream as PdfStream:
                pending.append((stream.dictionary, context, from))
            default:
                break
            }
        }
        if !pending.isEmpty { complete = false }
    }

    private func visit(_ r: PdfReference, _ context: Job, _ pending: inout [(value: PdfObject, context: Job, from: Int)]) {
        // The back links name pages, annotations and fields; what they name keeps its own job.
        let naming = context.kind == .link
        if naming && roles.contains(r.number) { return }
        if !seen.insert(Seen(number: r.number, job: context)).inserted { return }
        let job = naming || context.kind == .action ? Job(.plain) : context
        jobs[r.number, default: JobList()].add(job)
        if let target = document.get(r.number) {
            pending.append((target, context.kind == .link ? job : context, r.number))
        }
    }

    // Plumbing that only names: the fields of a real SubmitForm or ResetForm action and the target of Hide, which are
    // found under /A, /AA and /OpenAction (12.6.4), and the catalog a signature reference signs (12.8.1).
    private static func namesFields(_ dictionary: PdfDictionary, _ context: Job, _ key: String, _ item: PdfObject, _ catalog: Int) -> Bool {
        if context.kind == .action, let s = (dictionary["S"] as? PdfName)?.value {
            if key == "Fields" && (s == "SubmitForm" || s == "ResetForm") { return true }
            if key == "T" && s == "Hide" { return true }
        }
        if key == "Data" && dictionary.containsKey("TransformMethod"), let r = item as? PdfReference, r.number == catalog { return true }
        return false
    }

    private static let destinations: Set<String> = ["XYZ", "Fit", "FitH", "FitV", "FitR", "FitB", "FitBH", "FitBV"]

    // A destination names its page (12.3.2.2) without using it.
    private func namesPage(_ array: PdfArray, _ context: Job) -> Bool {
        guard context.kind == .plain || context.kind == .action, array.items.count >= 2,
              let page = array.items[0] as? PdfReference, let type = array.items[1] as? PdfName, Self.destinations.contains(type.value) else { return false }
        return pageIndex[page.number] != nil
    }

    // What an entry of an array is, given what the array is.
    private func element(_ context: Job, _ item: PdfObject) -> Job {
        let target = document.resolve(item) as? PdfDictionary
        let number = (item as? PdfReference)?.number ?? 0
        switch context.kind {
        case .pageTree:
            let leaf = target != nil && (document.name(target, "Type") == "Page" || !(target?.containsKey("Kids") ?? false))
            return leaf ? Job(.page, 0, pageIndex[number] ?? -1) : context
        case .annotList:
            if let target, document.name(target, "Subtype") == "Widget" {
                return Job(.field, ownerOf(number, target, namedParent(target)), context.page)
            }
            return Job(.comment, 0, context.page)
        case .fieldList:
            return Job(.field, ownerOf(number, target, context.owner), context.page)
        default:
            return context
        }
    }

    // A widget that is not a field of its own answers for the field above it only when it adds nothing a reader reads as
    // its own: a name, a type, flags or kids, or a /Parent that is not that field (12.7.3.1). Any other has no owner.
    private func ownerOf(_ number: Int, _ widget: PdfDictionary?, _ fallback: Int) -> Int {
        if fields[number] != nil { return number }
        let owner = widgetField[number] ?? fallback
        var own = widget == nil
        if let widget {
            own = widget.containsKey("T") || widget.containsKey("FT") || widget.containsKey("Ff") || widget.containsKey("Kids")
            if !own, let parent = widget["Parent"] {
                own = !((parent as? PdfReference)?.number == owner)
            }
        }
        return own ? -1 : owner
    }

    // A widget that no field lists belongs to the field it names as its parent, so that it is judged with it.
    private func namedParent(_ widget: PdfDictionary) -> Int {
        if let p = widget["Parent"] as? PdfReference, fields[p.number] != nil { return p.number }
        return -1
    }

    // What the value under a key of a dictionary is, given what the dictionary is; nil for a key that leads nowhere.
    private static func child(_ context: Job, _ key: String) -> Job? {
        let owner = context.owner, page = context.page
        switch context.kind {
        case .trailer:
            switch key {
            case "Root": return Job(.catalog)
            case "Info": return Job(.info)
            default: return Job(.plain)
            }
        case .catalog:
            switch key {
            case "Pages": return Job(.pageTree)
            case "Metadata": return Job(.info)
            case "DSS": return Job(.dss)
            case "AcroForm": return Job(.form)
            case "StructTreeRoot": return Job(.structure)
            case "OpenAction", "AA": return Job(.action)
            default: return Job(.plain)
            }
        case .pageTree:
            switch key {
            case "Kids": return context
            case "Parent": return Job(.link)
            default: return Job(.content)
            }
        // Where the structure tree names a page, an annotation or a field (14.7.4.3), it does not use it.
        case .structure:
            return key == "Pg" || key == "Obj" ? Job(.link) : context
        // A bead names its page (12.4.3).
        case .plain where key == "P", .content where key == "P":
            return Job(.link)
        case .defaults:
            return Job(.defaults, owner == 0 && key == "Font" ? 1 : 2)
        case .page:
            switch key {
            case "Annots": return Job(.annotList, 0, page)
            case "Parent": return Job(.link)
            case "AA": return Job(.action)
            default: return Job(.content, 0, page)
            }
        case .form:
            switch key {
            case "Fields": return Job(.fieldList)
            case "DR": return Job(.defaults)
            case "CO": return nil
            default: return Job(.plain)
            }
        case .field:
            switch key {
            case "Kids": return Job(.fieldList, owner, page)
            case "AP": return Job(.appearance, owner, page)
            case "V": return Job(.value, owner, page)
            case "Parent", "P", "Popup", "IRT": return Job(.link)
            case "A", "AA": return Job(.action)
            default: return Job(.plain)
            }
        case .comment:
            switch key {
            case "AP": return Job(.appearance, 0, page)
            case "Parent", "P", "Popup", "IRT": return Job(.link)
            case "A", "AA": return Job(.action)
            default: return Job(.plain)
            }
        case .plain where key == "A" || key == "AA" || key == "OpenAction":
            return Job(.action)
        case .dss:
            return dssChild(owner, key)
        case .annotList, .fieldList:
            return Job(.plain)
        default:
            return context
        }
    }

    // /DSS (depth 0) holds the lists and /VRI (1); /VRI holds an entry for each signature (2); an entry holds lists (3), as do the lists.
    private static func dssChild(_ depth: Int, _ key: String) -> Job {
        switch depth {
        case 0 where key == "Certs" || key == "OCSPs" || key == "CRLs": return Job(.dss, 3)
        case 0 where key == "VRI": return Job(.dss, 1)
        case 1 where isHex40(key): return Job(.dss, 2)
        case 2 where key == "Cert" || key == "OCSP" || key == "CRL" || key == "TS": return Job(.dss, 3)
        case 3: return Job(.dss, 3)
        default: return Job(.plain)
        }
    }

    static func isHex40(_ key: String) -> Bool {
        var count = 0
        for scalar in key.unicodeScalars {
            count += 1
            switch scalar.value {
            case 0x30...0x39, 0x41...0x46, 0x61...0x66: break
            default: return false
            }
        }
        return count == 40
    }
}
