import Foundation

// Twin of windows/LazyPDF.Core/Document/PdfDocument.Repair.cs: when the cross-reference data fails, the file is
// scanned once for "n g obj" and for trailers, and the table built from what is there, the newest definition of
// an object winning. One pass over the bytes; a stream is skipped by its length or its "endstream", so nothing
// is looked at twice.

extension PdfDocument {
    /// What a scan of the whole file found. `objectOrder` is the order the numbers were first met, which a
    /// .NET Dictionary keeps and the search for a catalog in an object stream depends on.
    final class Scan {
        var objects: [Int: (offset: Int, generation: Int)] = [:]
        var objectOrder: [Int] = []
        var trailers: [PdfDictionary] = []
        var objectStreams: [Int] = []
        var catalogs: [Int] = []
        var pageTrees: [Int] = []
        var pages: [Int] = []
        var highest = 0
        var wasted = 0
    }

    func ensureScan() -> Scan {
        if let scan = scanned { return scan }
        let scan = runScan()
        scanned = scan
        return scan
    }

    private func runScan() -> Scan {
        let scan = Scan()
        let obj = "obj".keywordBytes, trailerWord = "trailer".keywordBytes
        var pos = 0, nextObject = -1, nextTrailer = -1
        while true {
            if nextObject < pos { nextObject = next(obj, pos) }
            if nextTrailer < pos { nextTrailer = next(trailerWord, pos) }
            if nextObject == Int.max && nextTrailer == Int.max { break }
            if nextTrailer < nextObject {
                pos = nextTrailer + trailerWord.count
                if let (trailer, end) = tryRead(scan, pos, nextTrailer) {
                    if let dictionary = trailer as? PdfDictionary { scan.trailers.append(dictionary) }
                    pos = end
                }
                continue
            }
            let at = nextObject
            pos = at + 3
            guard let (start, number, generation) = objectHeader(at) else { continue }
            if scan.objects.updateValue((start, generation), forKey: number) == nil { scan.objectOrder.append(number) }
            scan.highest = max(scan.highest, number)
            guard let (value, valueEnd) = tryRead(scan, pos, at) else { continue }
            pos = max(pos, valueEnd)
            if let stream = value as? PdfStream {
                stream.number = number
                pos = max(pos, scanStreamEnd(stream))
            }
            classify(scan, number, (value as? PdfStream)?.dictionary ?? value as? PdfDictionary)
        }
        return scan
    }

    private func next(_ pattern: [UInt8], _ from: Int) -> Int {
        source.indexOf(pattern, from: from) ?? Int.max
    }

    /// Reads an object at `position`. What a failed read cost is added up, and once it passes the file's size
    /// nothing more is parsed: a stray "(" that swallows the rest of the file would otherwise be paid for again
    /// at every later header.
    private func tryRead(_ scan: Scan, _ position: Int, _ origin: Int) -> (value: PdfObject, end: Int)? {
        if scan.wasted > source.count { return nil }
        let lexer = PdfLexer(sourceBytes, position: position)
        do {
            let value = try lexer.readObject()
            return (value, lexer.position)
        } catch {
            scan.wasted += lexer.position - origin
            return nil
        }
    }

    /// "n g obj" ending at the "obj" at `at`; the digits before it are the number and generation.
    private func objectHeader(_ at: Int) -> (start: Int, number: Int, generation: Int)? {
        if at + 3 < source.count && isRegular(source[at + 3]) { return nil }
        var p = at - 1
        if !stepBackOver(&p, white: true, 8) { return nil }
        let generationEnd = p + 1
        if !stepBackOver(&p, white: false, 6) || p + 1 == generationEnd { return nil }
        let generationStart = p + 1
        let gapEnd = p + 1
        if !stepBackOver(&p, white: true, 8) || p + 1 == gapEnd { return nil }
        let numberEnd = p + 1
        if !stepBackOver(&p, white: false, 10) || p + 1 == numberEnd { return nil }
        let start = p + 1
        var n = 0, g = 0
        for i in start..<numberEnd { n = n * 10 + Int(source[i] - 0x30) }
        for i in generationStart..<generationEnd { g = g * 10 + Int(source[i] - 0x30) }
        if n < 1 || n > Self.maxObjectNumber || g > 65535 { return nil }
        return (start, n, g)
    }

    /// Moves `p` back over white space or digits, at most `limit` of them; false when it ran into the limit.
    private func stepBackOver(_ p: inout Int, white: Bool, _ limit: Int) -> Bool {
        var steps = 0
        while p >= 0 && (white ? PdfLexer.isWhiteSpace(Int(source[p])) : (source[p] >= 0x30 && source[p] <= 0x39)) {
            steps += 1
            if steps > limit { return false }
            p -= 1
        }
        return true
    }

    private func isRegular(_ b: UInt8) -> Bool {
        !PdfLexer.isWhiteSpace(Int(b)) && !PdfLexer.isDelimiter(Int(b))
    }

    private func scanStreamEnd(_ stream: PdfStream) -> Int {
        let start = stream.dataOffset
        if let declared = (stream.dictionary["Length"] as? PdfNumber)?.integer, declared >= 0,
           declared <= source.count - start, endstreamFollows(start + declared) {
            return start + declared
        }
        return findStreamEnd(start)
    }

    private func classify(_ scan: Scan, _ number: Int, _ dictionary: PdfDictionary?) {
        switch (dictionary?["Type"] as? PdfName)?.value {
        case "ObjStm": scan.objectStreams.append(number)
        case "XRef": if let dictionary { scan.trailers.append(dictionary) }
        case "Catalog": scan.catalogs.append(number)
        case "Pages": scan.pageTrees.append(number)
        case "Page": scan.pages.append(number)
        default: break
        }
    }

    func rebuild(_ reason: String) throws {
        addRepair("\(reason) Rebuilt the cross-reference table by scanning the file.")
        let scan = ensureScan()
        xrefRebuilt = true
        startXref = 0
        xrefIsStream = false
        entries.removeAll()
        objects.removeAll()
        objectStreams.removeAll()
        // Where each object was found: an object stream's members count as written where the stream is.
        var written: [Int: Int] = [:]
        var order = scan.objectOrder
        for number in scan.objectOrder {
            guard let found = scan.objects[number] else { continue }
            entries[number] = Entry(.inUse, found.offset, found.generation, 0)
            written[number] = found.offset
        }

        let rebuilt = PdfDictionary()
        var size = 0
        for found in scan.trailers {
            for key in Self.trailerKeys {
                if let value = found[key] { rebuilt[key] = value }
            }
            if let s = (found["Size"] as? PdfNumber)?.integer { size = max(size, s) }
        }
        if scan.trailers.isEmpty { addRepair("The file has no trailer.") }
        trailer = rebuilt
        nextObjectNumber = max(scan.highest + 1, Swift.min(size, Self.maxObjectNumber))

        try openSecurity()
        for streamNumber in scan.objectStreams {
            guard let members = loadObjectStream(streamNumber), let at = written[streamNumber] else { continue }
            for number in members.numbers {
                if let existing = written[number], existing >= at { continue }
                if entries[number] == nil { order.append(number) }
                entries[number] = Entry(.compressed, 0, 0, streamNumber)
                written[number] = at
                nextObjectNumber = max(nextObjectNumber, number + 1)
            }
        }

        if !catalogUsable() { try findCatalog(scan, order) }
        trailer["Size"] = PdfNumber(nextObjectNumber)
    }

    /// A catalog the trailer did not name, or failing that one made from the page tree that is there.
    private func findCatalog(_ scan: Scan, _ order: [Int]) throws {
        var candidates = scan.catalogs
        // A catalog in an object stream is not in the scan: look at the stored ones if no plain one will do.
        if !candidates.contains(where: hasPages) {
            candidates += order.filter { entries[$0]?.kind == .compressed }
        }
        for number in candidates.reversed() {
            if let found = get(number) as? PdfDictionary, name(found, "Type") == "Catalog", hasPages(number) {
                trailer["Root"] = PdfReference(number, generationOf(number))
                catalog = found
                addRepair("Found the catalog (object \(number)) by scanning.")
                return
            }
        }

        var tree: PdfReference?
        for number in scan.pageTrees.reversed() where tree == nil {
            // The root of the tree is the node that has no parent.
            if let node = get(number) as? PdfDictionary, resolve(node["Parent"]) == nil {
                tree = PdfReference(number, generationOf(number))
            }
        }
        if tree == nil && !scan.pages.isEmpty {
            let kids = PdfArray(scan.pages.map { PdfReference($0, generationOf($0)) as PdfObject })
            let root = PdfDictionary()
            root.add("Type", PdfName("Pages"))
            root.add("Kids", kids)
            root.add("Count", PdfNumber(scan.pages.count))
            tree = try addRepaired(root)
            addRepair("Made a page tree for \(scan.pages.count) pages found by scanning.")
        }
        guard let pages = tree else { throw PdfReadException.damaged("The file has no catalog and no pages.") }

        if let existing = resolve(trailer["Root"]) as? PdfDictionary {
            existing["Pages"] = pages
            catalog = existing
            addRepair("The catalog had no page tree; set it to the one found.")
            return
        }
        let made = PdfDictionary()
        made.add("Type", PdfName("Catalog"))
        made.add("Pages", pages)
        trailer["Root"] = try addRepaired(made)
        catalog = made
        addRepair("The file has no catalog; made one.")
    }

    private func addRepaired(_ value: PdfObject) throws -> PdfReference {
        if nextObjectNumber > Self.maxObjectNumber {
            throw PdfReadException.damaged("The file has no object numbers left to repair it with.")
        }
        return try add(value)
    }

    private func hasPages(_ number: Int) -> Bool {
        guard let found = get(number) as? PdfDictionary else { return false }
        return resolve(found["Pages"]) is PdfDictionary
    }
}
