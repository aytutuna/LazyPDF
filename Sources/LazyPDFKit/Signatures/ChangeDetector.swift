import Foundation

// Twin of windows/LazyPDF.Core/Signatures/ChangeDetector.cs: judges what the updates after a signature changed.
// UpdateGate has already shown that the bytes are exact; here each object an update lists is compared with its signed
// copy and judged by what the signed revision used it for (Jobs). An object with more than one job, a new object
// nothing allowed reaches, a freed object something still names, a changed generation: none of these is allowed.
// What the rules do not name is not allowed.
//
// Field names are compared as UTF-16 units wherever they decide a lock: Swift's String equality treats canonically
// equivalent text as equal, and the C# does not.

final class ChangeDetector {
    private static let unreadable = SignatureChangeReport([SignatureChange(.unreadable, 0, -1, nil, false)], 0)

    let docA: PdfDocument
    let docB: PdfDocument
    let level: Int
    let signatures: Set<Int>
    let jobsA: Jobs
    let jobsB: Jobs
    var changes: [SignatureChange] = []
    var locks: [(action: FieldLockAction, names: Set<[UInt16]>)] = []
    var lockNames: [Int: Set<[UInt16]>]?
    var daNamesCache: Set<[UInt16]>?
    var readOnlyCache: Bool?
    private var referencesCache: [Int: Int]?
    private var signedReferencesCache: [Int: Int]?

    private init(_ before: PdfDocument, _ after: PdfDocument, _ level: Int, _ signatures: Set<Int>) {
        docA = before
        docB = after
        self.level = level
        self.signatures = signatures
        jobsA = Jobs(before)
        jobsB = Jobs(after)
        readLocks()
    }

    /// The changes from `before`, the file cut at the end of the signed bytes, to `after` judged at `level`: 0 for a
    /// file that is not certified, else the /DocMDP permission 1 to 3. `signatures` are the offsets of the signature
    /// objects in the file whose byte range is sound: only those make a new signature field real. Bytes that cannot
    /// all be placed exactly are one change that is not allowed.
    static func compare(_ before: PdfDocument, _ after: PdfDocument, _ level: Int, _ signatures: Set<Int>) -> SignatureChangeReport {
        do {
            guard let listing = UpdateGate.check(before, after) else { return unreadable }
            let detector = ChangeDetector(before, after, level, signatures)
            // Jobs the walk did not reach are jobs nothing will judge.
            if !detector.jobsA.complete || !detector.jobsB.complete { return unreadable }
            try detector.run(listing)
            // The documents repair as objects are read; a repair the signed revision did not need means a table was not trusted.
            if !Set(after.repairs).subtracting(before.repairs).isEmpty { detector.report(.unreadable, 0, allowed: false) }
            return SignatureChangeReport(detector.changes, 0)
        } catch {
            return unreadable
        }
    }

    func permits(_ kind: SignatureChangeKind) -> Bool {
        switch kind {
        case .validationData: return true
        case .signature: return level != 1
        case .formFill: return level >= 2
        case .comment: return level == 3
        case .metadata: return level >= 2
        default: return false
        }
    }

    func report(_ kind: SignatureChangeKind, _ number: Int, _ page: Int = -1, field: String? = nil, allowed: Bool? = nil) {
        changes.append(SignatureChange(kind, number, page, field, allowed ?? permits(kind)))
    }

    static func isListed(_ entry: PdfDocument.Entry?) -> Bool {
        guard let entry else { return false }
        return entry.kind == .inUse || entry.kind == .compressed
    }

    private func run(_ listing: UpdateGate.Listing) throws {
        for n in listing.touched.sorted() {
            let before = docA.entries[n], after = docB.entries[n]
            // A cross-reference or object stream an update writes is only plumbing while nothing refers to it: its bytes
            // are not an object then, and its members are judged one by one. A number the signed revision named is judged as any.
            if listing.plumbing.contains(n) && !Self.isListed(before) && references()[n] == nil { continue }
            if Self.isListed(before) && Self.isListed(after) {
                if before?.generation != after?.generation {
                    denied(n, jobsA.of(n))
                } else if let x = docA.get(n), let y = docB.get(n), !same(x, y) {
                    try modified(n, x, y)
                }
            } else if Self.isListed(after) {
                added(n)
            } else if Self.isListed(before) {
                removed(n)
            } else if listing.defined.contains(n) && references()[n] != nil {
                // Given an object and freed again, the reference that was dangling in the signed revision is still there for a scanning viewer to fill.
                denied(n, jobsB.of(n))
            }
        }
    }

    private func same(_ a: PdfObject, _ b: PdfObject) -> Bool {
        if let sa = a as? PdfStream, let sb = b as? PdfStream {
            return Self.text(sa.dictionary) == Self.text(sb.dictionary) && docA.rawData(sa) == docB.rawData(sb)
        }
        return type(of: a) == type(of: b) && Self.text(a) == Self.text(b)
    }

    // The one kind of use an object has, or nil when it has none or several.
    private static func onlyKind(_ jobs: [Job]) -> JobKind? {
        var kinds: [JobKind] = []
        for job in jobs where !kinds.contains(job.kind) {
            kinds.append(job.kind)
            if kinds.count == 2 { break }
        }
        return kinds.count == 1 ? kinds[0] : nil
    }

    private static func pageOf(_ jobs: [Job]) -> Int {
        jobs.first { $0.page >= 0 }?.page ?? -1
    }

    // The first job of each owner, in the order found.
    private static func distinctByOwner(_ jobs: [Job]) -> [Job] {
        var owners = Set<Int>()
        return jobs.filter { owners.insert($0.owner).inserted }
    }

    private func denied(_ n: Int, _ jobs: [Job]) {
        let kinds = Set(jobs.map { $0.kind })
        let kind: SignatureChangeKind
        if kinds.contains(.content) {
            kind = .pageContent
        } else if !kinds.isDisjoint(with: [.page, .pageTree, .catalog]) {
            kind = .pageStructure
        } else if !kinds.isDisjoint(with: [.form, .fieldList, .field, .defaults]) {
            kind = .form
        } else {
            kind = .other
        }
        report(kind, n, Self.pageOf(jobs), allowed: false)
    }

    private func modified(_ n: Int, _ before: PdfObject, _ after: PdfObject) throws {
        var jobs = jobsA.of(n)
        for job in jobsB.of(n) where !jobs.contains(job) { jobs.append(job) }
        guard let kind = Self.onlyKind(jobs) else {
            denied(n, jobs)
            return
        }
        if (kind == .field || kind == .dss || kind == .defaults) && Set(jobs.map { $0.owner }).count > 1 {
            denied(n, jobs)
            return
        }
        let page = Self.pageOf(jobs)
        let a = before as? PdfDictionary, b = after as? PdfDictionary
        switch kind {
        case .catalog:
            if let a, let b { catalog(n, a, b) } else { denied(n, jobs) }
        case .form:
            if let a, let b { acroForm(n, a, b) } else { denied(n, jobs) }
        case .page:
            if let a, let b { self.page(n, page, a, b) } else { denied(n, jobs) }
        case .field:
            if let a, let b { field(n, jobsA.fields[jobs[0].owner], a, b) } else { denied(n, jobs) }
        case .comment:
            if let a, let b { comment(n, page, a, b) } else { denied(n, jobs) }
        case .fieldList:
            if let fa = before as? PdfArray, let fb = after as? PdfArray { fieldsDiff(fa.items, fb.items) } else { denied(n, jobs) }
        case .annotList:
            if let aa = before as? PdfArray, let ab = after as? PdfArray { annotsDiff(aa.items, ab.items, page) } else { denied(n, jobs) }
        case .appearance, .value:
            for job in Self.distinctByOwner(jobs) { part(n, job, added: false) }
        case .info:
            if let sa = before as? PdfStream, let sb = after as? PdfStream { try packet(n, sa, sb) } else { information(n, a, b) }
        case .defaults:
            var grown = false
            if let a, let b { grown = grew(a, b, jobs[0].owner) }
            report(.formFill, n, allowed: defaultsAllowed(grown))
        case .dss:
            validation(n, jobs[0].owner, before, after)
        default:
            denied(n, jobs)
        }
    }

    // A new object is allowed only for the use the update gives it, and only where that use may be added.
    private func added(_ n: Int) {
        let jobs = jobsB.of(n)
        // A font the form's defaults gain is the one its new appearance draws with. A new object changes how a signed one
        // draws only through a changed object that names it, which is judged on its own, unless the signed revision named
        // a number nothing was at.
        if jobs.contains(where: { $0.kind == .defaults }) && jobs.allSatisfy({ $0.kind == .defaults || $0.kind == .appearance }) {
            report(.formFill, n, allowed: defaultsAllowed(signedReferences()[n] == nil))
            for job in Self.distinctByOwner(jobs.filter { $0.kind == .appearance }) { part(n, job, added: true) }
            return
        }
        guard let kind = Self.onlyKind(jobs) else {
            denied(n, jobs)
            return
        }
        let page = Self.pageOf(jobs)
        switch kind {
        case .comment:
            addedComment(n, page)
        case .field:
            addedField(n, page)
        case .appearance, .value:
            for job in Self.distinctByOwner(jobs) { part(n, job, added: true) }
        case .info:
            information(n, PdfDictionary(), docB.get(n) as? PdfDictionary)
        case .dss:
            report(.validationData, n)
        case .annotList:
            if let items = docB.get(n) as? PdfArray { annotsDiff([], items.items, page) } else { denied(n, jobs) }
        case .fieldList:
            if let items = docB.get(n) as? PdfArray { fieldsDiff([], items.items) } else { denied(n, jobs) }
        case .form:
            if let form = docB.get(n) as? PdfDictionary { acroForm(n, PdfDictionary(), form) } else { denied(n, jobs) }
        default:
            denied(n, jobs)
        }
    }

    private func removed(_ n: Int) {
        let jobs = jobsA.of(n)
        // A name that is still written down somewhere would read as nothing there.
        guard references()[n] == nil, let kind = Self.onlyKind(jobs) else {
            denied(n, jobs)
            return
        }
        switch kind {
        case .comment, .annotList:
            report(.comment, n, Self.pageOf(jobs))
        case .appearance where jobs.allSatisfy({ $0.owner == 0 }):
            report(.comment, n, Self.pageOf(jobs))
        case .info:
            report(.metadata, n)
        case .dss:
            report(.validationData, n)
        default:
            denied(n, jobs)
        }
    }

    // How often each number is written as a reference anywhere in the file as it is, in objects nothing reaches too.
    func references() -> [Int: Int] {
        if let known = referencesCache { return known }
        let counted = Self.countReferences(docB)
        referencesCache = counted
        return counted
    }

    private func signedReferences() -> [Int: Int] {
        if let known = signedReferencesCache { return known }
        let counted = Self.countReferences(docA)
        signedReferencesCache = counted
        return counted
    }

    private static func countReferences(_ document: PdfDocument) -> [Int: Int] {
        var counts: [Int: Int] = [:]
        for r in referencesIn(document.trailer) { counts[r.number, default: 0] += 1 }
        for number in document.objectNumbers {
            guard let value = document.get(number) else { continue }
            for r in referencesIn(value) { counts[r.number, default: 0] += 1 }
        }
        return counts
    }

    private static func referencesIn(_ value: PdfObject) -> [PdfReference] {
        var found: [PdfReference] = []
        var pending: [PdfObject] = [value]
        while let next = pending.popLast() {
            switch next {
            case let r as PdfReference:
                found.append(r)
            case let array as PdfArray:
                pending.append(contentsOf: array.items)
            case let dictionary as PdfDictionary:
                for (_, item) in dictionary.entries { pending.append(item) }
            case let stream as PdfStream:
                pending.append(stream.dictionary)
            default:
                break
            }
        }
        return found
    }
}
