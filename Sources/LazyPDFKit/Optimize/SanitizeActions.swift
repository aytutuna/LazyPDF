import Foundation

// Twin of windows/LazyPDF.Core/Optimize/SanitizeActions.cs: actions that run code, open other files or leave the
// document. They are taken out where they hang (/A, /AA, /OpenAction, /Next), and the name tree of document scripts
// goes whole.

struct ActionCounts {
    let javaScript: Int
    let launch: Int
    let uri: Int
}

enum SanitizeActions {
    private static let leaving: Set<String> =
        ["Launch", "GoToR", "GoToE", "ImportData", "SubmitForm", "Thread", "Movie", "Sound", "Rendition", "RichMediaExecute"]

    private static let known: Set<String> =
        Set(["GoTo", "Named", "SetOCGState", "Hide", "ResetForm", "Trans", "GoTo3DView", "JavaScript", "URI"]).union(leaving)

    /// Counts, and with the options takes out, JavaScript, launching or leaving actions, and links to a URI; also counts how many of each went.
    static func run(_ document: PdfDocument, _ removeScripts: Bool, _ removeLaunch: Bool, _ removeUri: Bool) throws -> (found: ActionCounts, taken: ActionCounts) {
        let chains = Chains(document)
        func wanted(_ kind: String) -> Bool {
            switch kind {
            case "JavaScript": return removeScripts
            case "URI": return removeUri
            default: return removeLaunch
            }
        }
        func hang(_ holder: PdfDictionary, _ key: String) throws {
            guard let action = document.dict(holder, key), let written = holder[key] else { return }
            if let kept = try chains.filter(written, action, true, wanted) {
                holder[key] = kept
            } else {
                holder.remove(key)
            }
        }
        for dictionary in PdfGraph.allDictionaries(document) {
            if dictionary.containsKey("OnInstantiate") {
                chains.found[0] += 1
                if removeScripts {
                    chains.taken[0] += 1
                    dictionary.remove("OnInstantiate")
                }
            }
            for key in ["A", "OpenAction", "PA", "NA"] { try hang(dictionary, key) }
            guard let triggers = document.dict(dictionary, "AA") else { continue }
            for (name, _) in triggers.entries { try hang(triggers, name) }
            if triggers.count == 0 { dictionary.remove("AA") }
        }

        let names = document.dict(document.catalog, "Names")
        // Pages a script can spawn (12.7.6) and slide shows are content only the viewer's scripting or presentation mode reaches.
        for key in ["JavaScript", "Templates", "Pages", "AlternatePresentations"] {
            guard let names, names.containsKey(key) else { continue }
            let entries = PdfNameTree.read(document, names[key])
            let n = max(1, entries.count)
            chains.found[0] += n
            if removeScripts { chains.taken[0] += n }
            // What follows an entry is an action too; the entries themselves are counted above.
            for entry in entries {
                if let action = document.resolve(entry.value) as? PdfDictionary {
                    _ = try chains.filter(entry.value, action, false, { removeScripts || wanted($0) })
                }
            }
            if removeScripts { names.remove(key) }
        }
        if let form = document.dict(document.catalog, "AcroForm"), xfaHasScript(document, form["XFA"]) {
            chains.found[0] += 1
            if removeScripts {
                chains.taken[0] += 1
                form.remove("XFA")
            }
        }
        if document.dict(document.catalog, "URI") != nil {
            chains.found[2] += 1
            if removeUri {
                chains.taken[2] += 1
                document.catalog.remove("URI")
            }
        }
        return (ActionCounts(javaScript: chains.found[0], launch: chains.found[1], uri: chains.found[2]),
                ActionCounts(javaScript: chains.taken[0], launch: chains.taken[1], uri: chains.taken[2]))
    }

    static func kind(_ document: PdfDocument, _ action: PdfDictionary) -> String {
        guard let type = document.name(action, "S"), known.contains(type) else { return "Other" }
        if type == "Rendition" && action.containsKey("JS") { return "JavaScript" }
        return type == "JavaScript" ? "JavaScript" : type == "URI" ? "URI" : leaving.contains(type) ? "Launch" : "Other"
    }

    private static func chained(_ document: PdfDocument, _ action: PdfDictionary) -> [(item: PdfObject, action: PdfDictionary)] {
        guard let written = action["Next"] else { return [] }
        switch document.resolve(written) {
        case let next as PdfDictionary:
            return [(written, next)]
        case let list as PdfArray:
            return list.items.compactMap { item in (document.resolve(item) as? PdfDictionary).map { (item: item, action: $0) } }
        default:
            return []
        }
    }

    private static func xfaHasScript(_ document: PdfDocument, _ xfa: PdfObject?) -> Bool {
        let parts: [PdfObject?] = (document.resolve(xfa) as? PdfArray).map { $0.items.map { document.resolve($0) } } ?? [document.resolve(xfa)]
        let needle = Array("<script".utf8)
        for part in parts {
            guard let stream = part as? PdfStream, let data = try? document.data(stream) else { continue }
            if data.count < needle.count { continue }
            for i in 0...(data.count - needle.count) {
                var match = true
                for k in 0..<needle.count {
                    let b = data[i + k]
                    if (b >= 65 && b <= 90 ? b + 32 : b) != needle[k] {
                        match = false
                        break
                    }
                }
                if match { return true }
            }
        }
        return false
    }

    // The chain after an action is a graph (/Next may name an action twice or loop), so it is walked with a work list.
    // An action that stays is kept even behind one that goes: it takes the removed one's place in each link, and in the
    // holder when the root goes. A crafted file can make that rewiring quadratic, so the links written share one budget.
    private final class Chains {
        private static let maxLinks = 200_000

        // Where /Next leads from an action that stays: an action as it is, or what stays behind one that goes.
        private enum Source {
            case direct(PdfDictionary)
            case through(PdfDictionary)
        }

        let document: PdfDocument
        var found = [0, 0, 0]
        var taken = [0, 0, 0]
        private var budget = Chains.maxLinks

        init(_ document: PdfDocument) {
            self.document = document
        }

        /// Takes the actions `wanted` chooses out of the chain that starts at `root`, which `item` is as written.
        /// Returns what the holder names now, or nil when nothing is left. A root that is not `counted` is counted
        /// elsewhere and stays.
        func filter(_ item: PdfObject, _ root: PdfDictionary, _ counted: Bool, _ wanted: (String) -> Bool) throws -> PdfObject? {
            var raw: [ObjectIdentifier: PdfObject] = [ObjectIdentifier(root): item]
            var rawOrder: [PdfDictionary] = [root]
            var gone = Set<ObjectIdentifier>()
            var pending = [root]
            while let action = pending.popLast() {
                let kind = SanitizeActions.kind(document, action)
                if kind != "Other" && (counted || action !== root) {
                    let slot = kind == "JavaScript" ? 0 : kind == "Launch" ? 1 : 2
                    // A rendition with a script is still a media action, and it goes under either option.
                    let media = kind == "JavaScript" && document.name(action, "S") == "Rendition"
                    found[slot] += 1
                    if media { found[1] += 1 }
                    if wanted(kind) || (media && wanted("Launch")) {
                        gone.insert(ObjectIdentifier(action))
                        taken[slot] += 1
                        if media { taken[1] += 1 }
                    }
                }
                for (link, next) in SanitizeActions.chained(document, action) where raw[ObjectIdentifier(next)] == nil {
                    raw[ObjectIdentifier(next)] = link
                    rawOrder.append(next)
                    pending.append(next)
                }
            }
            if gone.isEmpty { return item }

            var cache: [ObjectIdentifier: [PdfDictionary]] = [:]
            for action in rawOrder where !gone.contains(ObjectIdentifier(action)) {
                let links = SanitizeActions.chained(document, action)
                if links.contains(where: { gone.contains(ObjectIdentifier($0.action)) }) {
                    setNext(action, links.map { gone.contains(ObjectIdentifier($0.action)) ? Source.through($0.action) : Source.direct($0.action) }, raw, gone, &cache)
                }
            }
            if !gone.contains(ObjectIdentifier(root)) { return item }
            let left = surviving(root, gone, &cache)
            guard let first = left.first else { return nil }
            if left.count == 1 { return raw[ObjectIdentifier(first)] }
            // A holder names one action. The first survivor may be named elsewhere too, so a copy carries the others.
            let head = PdfDictionary()
            for (key, value) in first.entries { head.add(key, value) }
            let rest = SanitizeActions.chained(document, first).map { Source.direct($0.action) } + left.dropFirst().map { Source.direct($0) }
            setNext(head, rest, raw, gone, &cache)
            return try document.add(head)
        }

        // The actions that stay among those chained after this one, looking through the ones that go.
        private func surviving(_ from: PdfDictionary, _ gone: Set<ObjectIdentifier>, _ cache: inout [ObjectIdentifier: [PdfDictionary]]) -> [PdfDictionary] {
            if let cached = cache[ObjectIdentifier(from)] { return cached }
            var found: [PdfDictionary] = []
            var listed = Set<ObjectIdentifier>()
            var visited: Set<ObjectIdentifier> = [ObjectIdentifier(from)]
            var pending: [PdfDictionary] = []
            expand(from, &pending)
            while budget > 0, let action = pending.popLast() {
                if !gone.contains(ObjectIdentifier(action)) {
                    if listed.insert(ObjectIdentifier(action)).inserted { found.append(action) }
                } else if visited.insert(ObjectIdentifier(action)).inserted {
                    expand(action, &pending)
                }
            }
            cache[ObjectIdentifier(from)] = found
            return found
        }

        private func expand(_ action: PdfDictionary, _ pending: inout [PdfDictionary]) {
            let links = SanitizeActions.chained(document, action)
            budget -= links.count
            for i in stride(from: links.count - 1, through: 0, by: -1) { pending.append(links[i].action) }
        }

        private func setNext(_ action: PdfDictionary, _ next: [Source], _ raw: [ObjectIdentifier: PdfObject], _ gone: Set<ObjectIdentifier>,
                             _ cache: inout [ObjectIdentifier: [PdfDictionary]]) {
            // The limit is taken before the sources are read, which spend the budget as they go.
            let limit = max(0, budget)
            var seen = Set<ObjectIdentifier>()
            var items: [PdfObject] = []
            collect: for source in next {
                if limit == 0 { break }
                let actions: [PdfDictionary]
                switch source {
                case .direct(let one): actions = [one]
                case .through(let from): actions = surviving(from, gone, &cache)
                }
                for candidate in actions where seen.insert(ObjectIdentifier(candidate)).inserted {
                    if let written = raw[ObjectIdentifier(candidate)] { items.append(written) }
                    if items.count == limit { break collect }
                }
            }
            budget -= items.count
            if items.isEmpty {
                action.remove("Next")
            } else if items.count == 1 && !(document.resolve(action["Next"]) is PdfArray) {
                action["Next"] = items[0]
            } else {
                action["Next"] = PdfArray(items)
            }
        }
    }
}
