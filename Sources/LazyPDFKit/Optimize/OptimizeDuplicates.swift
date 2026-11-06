import Foundation

// Twin of windows/LazyPDF.Core/Optimize/OptimizeDuplicates.cs: objects that say the same thing are written once.
// Streams count as equal when their dictionaries and stored bytes are; a few kinds of plain dictionaries (fonts,
// descriptors, graphics states) too. Pages, annotations and the like never merge, because their identity matters.

enum OptimizeDuplicates {
    private static let rounds = 8

    static func run(_ document: PdfDocument) -> Int {
        var merged = 0
        var hashes: [Int: String] = [:]
        for _ in 0..<rounds {
            var groups: [String: [Int]] = [:]
            var order: [String] = []
            let live = reachable(document)
            for (number, value) in PdfGraph.objects(document) {
                if !live.contains(number) || !mergeable(document, value) { continue }
                var key = PdfGraph.canonical(value, { $0 }, true)
                if let stream = value as? PdfStream {
                    let hash: String
                    if let known = hashes[number] {
                        hash = known
                    } else {
                        hash = PdfGraph.hex(Sha256.hash(document.rawData(stream)))
                        hashes[number] = hash
                    }
                    key += hash
                }
                if groups[key] == nil { order.append(key) }
                groups[key, default: []].append(number)
            }
            var map: [Int: Int] = [:]
            for key in order {
                guard let list = groups[key], list.count >= 2 else { continue }
                let keep = list[0]
                for other in list.dropFirst() where same(document, keep, other) { map[other] = keep }
            }
            if map.isEmpty { break }
            PdfGraph.redirect(document, map)
            merged += map.count
        }
        return merged
    }

    private static func reachable(_ document: PdfDocument) -> Set<Int> {
        var reached = Set<Int>()
        var queue: [PdfObject?] = [document.trailer]
        for page in document.pages { queue.append(page.dictionary) }
        var next = 0
        while next < queue.count {
            let root = queue[next]
            next += 1
            for reference in PdfGraph.references(root) where reached.insert(reference.number).inserted {
                queue.append(document.get(reference.number))
            }
        }
        return reached
    }

    private static func same(_ document: PdfDocument, _ a: Int, _ b: Int) -> Bool {
        if let x = document.get(a) as? PdfStream, let y = document.get(b) as? PdfStream { return document.rawData(x) == document.rawData(y) }
        return true
    }

    private static func mergeable(_ document: PdfDocument, _ value: PdfObject) -> Bool {
        if let stream = value as? PdfStream {
            guard let type = document.name(stream.dictionary, "Type") else { return true }
            return !(type == "Metadata" || type == "XRef" || type == "ObjStm")
        }
        guard let dictionary = value as? PdfDictionary else { return false }
        if let type = document.name(dictionary, "Type"), type == "Font" || type == "FontDescriptor" || type == "ExtGState" { return true }
        if let subtype = document.name(dictionary, "Subtype"),
           ["Type1", "TrueType", "Type0", "CIDFontType0", "CIDFontType2", "MMType1"].contains(subtype) { return true }
        return dictionary.containsKey("FunctionType")
    }
}
