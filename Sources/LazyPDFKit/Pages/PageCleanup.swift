import Foundation

// Twin of windows/LazyPDF.Core/Pages/PageCleanup.cs: what has to change before pages are removed, so that nothing is left
// pointing at them. A reference left behind would also keep the removed page, and what it shows, in a rewritten file.

enum PageCleanup {
    private static let maxItems = 1_000_000

    private struct Walked {
        let result: PdfObject?
        let depth: Int
    }

    // What became of each action and each /Next array, whoever holds it, and the depth it was walked from.
    // A holder nearer the top walks again what an earlier one cut short at the depth limit.
    private final class Seen {
        var actions: [ObjectIdentifier: Walked] = [:]
        var lists: [ObjectIdentifier: Walked] = [:]
        var leads: [ObjectIdentifier: PdfObject?] = [:]
        // The maps are keyed by address, so what they name stays alive as long as they do: a freed dictionary's address can be
        // taken by a new object, which would then read the old entry.
        private var held: [AnyObject] = []

        func hold(_ object: AnyObject) {
            held.append(object)
        }
    }

    static func beforeDelete(_ document: PdfDocument, _ doomed: [PdfPage]) throws {
        let gone = Set(doomed.map { $0.reference.number })
        let names = DestContext(document)
        let dead: (PdfObject?) -> Bool = { destination in
            PageDestinations.pageOfAny(document, names, destination).map { gone.contains($0.number) } ?? false
        }

        let done = Seen()
        try outlines(document, dead, done)
        for page in document.pages {
            if gone.contains(page.reference.number) { continue }
            try dropLinks(document, page, dead, done)
            try triggers(document, page.dictionary, dead, done)
        }
        try openAction(document, dead, done)
        try PageDestinations.removeWhere(document, dead)
        for page in doomed { removeFields(document, page) }
        try structure(document, doomed)
        try threads(document, gone)
        try PageLabels.removed(document, doomed.map { $0.index }, document.pages.count)
    }

    // The item stays, without a destination; a bookmark that goes nowhere is still a heading.
    private static func outlines(_ document: PdfDocument, _ dead: (PdfObject?) -> Bool, _ done: Seen) throws {
        guard let root = document.dict(document.catalog, "Outlines") else { return }
        var seen = Set<ObjectIdentifier>()
        var stack = [root]
        while seen.count < maxItems, let item = stack.popLast() {
            if !seen.insert(ObjectIdentifier(item)).inserted { continue }
            try strip(document, item, dead, done)
            if let next = document.dict(item, "Next") { stack.append(next) }
            if let first = document.dict(item, "First") { stack.append(first) }
        }
    }

    private static func strip(_ document: PdfDocument, _ holder: PdfDictionary, _ dead: (PdfObject?) -> Bool, _ done: Seen) throws {
        if holder.containsKey("Dest") && dead(holder["Dest"]) { holder.remove("Dest") }
        try triggers(document, holder, dead, done)
    }

    private static func triggers(_ document: PdfDocument, _ holder: PdfDictionary, _ dead: (PdfObject?) -> Bool, _ done: Seen) throws {
        if holder.containsKey("A") {
            if let kept = try action(document, holder["A"], dead, done, 0) { holder["A"] = kept } else { holder.remove("A") }
        }
        guard let additional = document.dict(holder, "AA") else { return }
        var seen = Set<String>()
        for key in additional.entries.map({ $0.key }) where seen.insert(key).inserted {
            if let kept = try action(document, additional[key], dead, done, 0) { additional[key] = kept } else { additional.remove(key) }
        }
    }

    // A GoTo to a gone page is dropped and the action that followed it takes its place; where several followed,
    // the first takes its place and the rest follow it, since /A and /OpenAction hold one action (12.6.2).
    // A /Next array is edited where it stands, so every holder keeps pointing at it and the file stays linear.
    private static func action(_ document: PdfDocument, _ value: PdfObject?, _ dead: (PdfObject?) -> Bool, _ done: Seen,
                               _ depth: Int) throws -> PdfObject? {
        guard let current = document.resolve(value) as? PdfDictionary else { return value }
        let id = ObjectIdentifier(current)
        done.hold(current)
        if let known = done.actions[id], depth >= known.depth { return known.result }
        let gone = document.name(current, "S") == "GoTo" && dead(current["D"])
        // A /Next that leads back to a GoTo being dropped has nothing to point at.
        done.actions[id] = Walked(result: gone ? nil : value, depth: depth)
        var next = current["Next"]
        if depth < 32, let following = next {
            if let list = document.resolve(following) as? PdfArray {
                let listId = ObjectIdentifier(list)
                done.hold(list)
                if let walked = done.lists[listId], depth >= walked.depth {
                    next = walked.result
                } else {
                    var kept: [PdfObject] = []
                    for item in list.items {
                        if let result = try action(document, item, dead, done, depth + 1) { kept.append(result) }
                    }
                    kept = dictionaries(document, kept)
                    list.items = kept
                    done.leads[listId] = nil
                    next = kept.isEmpty ? nil : following
                    done.lists[listId] = Walked(result: next, depth: depth)
                }
            } else {
                if document.resolve(following) is PdfDictionary {
                    next = try action(document, following, dead, done, depth + 1)
                } else {
                    next = nil
                }
            }
            if let next { current["Next"] = next } else { current.remove("Next") }
        }
        let result: PdfObject? = try gone ? lead(document, next, done) : value
        done.actions[id] = Walked(result: result, depth: depth)
        return result
    }

    private static func dictionaries(_ document: PdfDocument, _ items: [PdfObject]) -> [PdfObject] {
        items.filter { document.resolve($0) is PdfDictionary }
    }

    // The first follower becomes a copy that carries the others after its own, so an action other holders share is left as it is.
    // The copy and its chain are objects of their own, made once per array, so holders of one array share them.
    private static func lead(_ document: PdfDocument, _ next: PdfObject?, _ done: Seen) throws -> PdfObject? {
        if document.resolve(next) is PdfDictionary { return next }
        guard let list = document.resolve(next) as? PdfArray else { return nil }
        let listId = ObjectIdentifier(list)
        done.hold(list)
        if let led = done.leads[listId] { return led }
        let actions = dictionaries(document, list.items)
        var lead = actions.first
        if actions.count > 1, let first = document.resolve(actions[0]) as? PdfDictionary {
            let head = first.copy()
            var chain: [PdfObject] = []
            if let own = head["Next"] {
                if let owned = document.resolve(own) as? PdfArray { chain.append(contentsOf: owned.items) } else { chain.append(own) }
            }
            chain.append(contentsOf: actions.dropFirst())
            head["Next"] = try document.add(PdfArray(dictionaries(document, chain)))
            lead = try document.add(head)
        }
        done.leads[listId] = lead
        return lead
    }

    private static func dropLinks(_ document: PdfDocument, _ page: PdfPage, _ dead: (PdfObject?) -> Bool, _ done: Seen) throws {
        guard let annots = document.array(page.dictionary, "Annots") else { return }
        for item in annots.items {
            if let annotation = document.resolve(item) as? PdfDictionary { try strip(document, annotation, dead, done) }
        }
    }

    private static func openAction(_ document: PdfDocument, _ dead: (PdfObject?) -> Bool, _ done: Seen) throws {
        let found = document.resolve(document.catalog["OpenAction"])
        if found is PdfArray {
            if dead(found) { document.catalog.remove("OpenAction") }
        } else if found is PdfDictionary {
            if let kept = try action(document, document.catalog["OpenAction"], dead, done, 0) {
                document.catalog["OpenAction"] = kept
            } else {
                document.catalog.remove("OpenAction")
            }
        }
        if document.dict(document.catalog, "AA") != nil { try triggers(document, document.catalog, dead, done) }
    }

    // A widget goes from its field; a field with no widget or sub-field left goes from its parent, up to /Fields.
    private static func removeFields(_ document: PdfDocument, _ page: PdfPage) {
        guard let form = document.dict(document.catalog, "AcroForm"), let annots = document.array(page.dictionary, "Annots") else { return }
        var dropped = Set<PdfReference>()
        for item in annots.items {
            guard let widget = item as? PdfReference, let annotation = document.resolve(widget) as? PdfDictionary,
                  document.name(annotation, "Subtype") == "Widget" else { continue }
            var node = widget
            for depth in 0..<32 {
                dropped.insert(node)
                guard let field = document.resolve(node) as? PdfDictionary, let up = field["Parent"] as? PdfReference,
                      let parent = document.resolve(up) as? PdfDictionary, let kids = document.array(parent, "Kids") else { break }
                let leaving = node
                let at = kids.items.firstIndex { ($0 as? PdfReference)?.number == leaving.number }
                kids.items.removeAll { ($0 as? PdfReference)?.number == leaving.number }
                if let at, depth == 0 { forgetButton(document, parent, at, annotation) }
                if !kids.items.isEmpty { break }
                node = up
            }
        }
        if let fields = document.array(form, "Fields") { fields.items.removeAll { ($0 as? PdfReference).map { dropped.contains($0) } ?? false } }
        if let order = document.array(form, "CO") { order.items.removeAll { ($0 as? PdfReference).map { dropped.contains($0) } ?? false } }
    }

    /// A button of a radio group or check box set goes: its entry in /Opt, which is by position, goes with it, and the
    /// group's /V is Off when it named the state of this button.
    static func forgetButton(_ document: PdfDocument, _ parent: PdfDictionary, _ index: Int, _ widget: PdfDictionary) {
        if let type = document.name(parent, "FT"), type != "Btn" { return }
        if let options = document.array(parent, "Opt"), index >= 0, index < options.items.count { options.items.remove(at: index) }
        let states = document.dict(document.dict(widget, "AP"), "N")
        if let value = document.name(parent, "V"), let states, value != "Off", states.containsKey(value) { parent["V"] = PdfName("Off") }
    }

    private static func structure(_ document: PdfDocument, _ doomed: [PdfPage]) throws {
        if !document.catalog.containsKey("StructTreeRoot") { return }
        func tagged(_ page: PdfPage) -> Bool {
            if page.dictionary.containsKey("StructParents") { return true }
            return document.array(page.dictionary, "Annots")?.items.contains { (document.resolve($0) as? PdfDictionary)?.containsKey("StructParent") == true } == true
        }
        if !doomed.contains(where: tagged) { return }
        if PageCarry.hasTags(document), try RedactionStructure.prune(document, [:], RedactionObjects.Identities(), Set(doomed.map { $0.reference.number })) {
            try keepKeys(document, doomed)
            return
        }
        document.catalog.remove("StructTreeRoot")
        document.catalog.remove("MarkInfo")
        for page in document.pages {
            page.dictionary.remove("StructParents")
            if document.name(page.dictionary, "Tabs") == "S" { page.dictionary.remove("Tabs") }
            guard let annots = document.array(page.dictionary, "Annots") else { continue }
            for item in annots.items {
                if let annotation = document.resolve(item) as? PdfDictionary { annotation.remove("StructParent") }
            }
        }
    }

    // Only the keys of the pages and annotations that go are removed; a form or image that owns a key stays mapped.
    private static func keepKeys(_ document: PdfDocument, _ doomed: [PdfPage]) throws {
        guard let parents = document.dict(document.dict(document.catalog, "StructTreeRoot"), "ParentTree") else { return }
        let gone = Set(doomed.map { $0.reference.number })
        let used = pageKeys(document, document.pages.filter { !gone.contains($0.reference.number) })
        let dropped = pageKeys(document, doomed).subtracting(used)
        if dropped.isEmpty { return }
        _ = try PdfNumberTree.write(document, parents, PdfNumberTree.read(document, parents).filter { !dropped.contains($0.key) })
    }

    private static func pageKeys(_ document: PdfDocument, _ pages: [PdfPage]) -> Set<Int> {
        var keys = Set<Int>()
        for page in pages {
            if let key = document.integer(page.dictionary, "StructParents") { keys.insert(key) }
            guard let annots = document.array(page.dictionary, "Annots") else { continue }
            for item in annots.items {
                if let annotation = document.resolve(item) as? PdfDictionary, let own = document.integer(annotation, "StructParent") { keys.insert(own) }
            }
        }
        return keys
    }

    // A bead on a page that goes leaves its article; an article with no bead left goes too.
    private static func threads(_ document: PdfDocument, _ gone: Set<Int>) throws {
        guard let threads = document.array(document.catalog, "Threads") else { return }
        var members = Set<Int>()
        let pages = Set(document.pages.map { $0.reference.number })
        for item in threads.items {
            guard let thread = document.resolve(item) as? PdfDictionary, let first = thread["F"] as? PdfReference else { continue }
            // A ring met under an earlier thread is done; the thread stays only while its first bead does.
            if members.contains(first.number) {
                if document.resolve(first) == nil { forget(document, threads, item) }
                continue
            }
            var ring: [PdfReference] = []
            var bead = first
            while ring.count < maxItems && members.insert(bead.number).inserted {
                ring.append(bead)
                guard let d = document.resolve(bead) as? PdfDictionary, let next = d["N"] as? PdfReference else { break }
                bead = next
            }
            let kept = ring.filter { reference in
                guard let d = document.resolve(reference) as? PdfDictionary else { return false }
                if let page = d["P"] as? PdfReference, gone.contains(page.number) { return false }
                return true
            }
            if kept.count == ring.count { continue }
            let stays = Set(kept)
            // A bead that is really a page is not the thread's to delete.
            for removed in ring where !stays.contains(removed) && !pages.contains(removed.number) { document.delete(removed.number) }
            if kept.isEmpty {
                forget(document, threads, item)
                continue
            }
            for (i, reference) in kept.enumerated() {
                guard let d = document.resolve(reference) as? PdfDictionary else { continue }
                d["N"] = kept[(i + 1) % kept.count]
                d["V"] = kept[(i + kept.count - 1) % kept.count]
            }
            thread["F"] = kept[0]
        }
    }

    private static func forget(_ document: PdfDocument, _ threads: PdfArray, _ item: PdfObject) {
        let reference = item as? PdfReference
        // List.Remove compares references by their numbers and everything else by identity.
        if let at = threads.items.firstIndex(where: { other in
            if let reference, let held = other as? PdfReference { return held == reference }
            return other === item
        }) {
            threads.items.remove(at: at)
        }
        if let reference { document.delete(reference.number) }
    }
}
