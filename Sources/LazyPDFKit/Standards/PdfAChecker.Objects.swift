import Foundation

// Twin of windows/LazyPDF.Core/Standards/PdfAChecker.Objects.cs: every object reachable from the trailer: implementation
// limits, stream keys and filters, file specifications.

extension PdfAChecker {
    static let maxSteps = 20_000_000

    static let table6: Set<String> = [
        "ASCIIHexDecode", "ASCII85Decode", "LZWDecode", "FlateDecode", "RunLengthDecode", "CCITTFaxDecode", "JBIG2Decode", "DCTDecode", "JPXDecode", "Crypt",
    ]

    // The short names ISO 32000-1 Table 94 allows in an inline image.
    static let inlineFilters: Set<String> = ["AHx", "A85", "LZW", "Fl", "RL", "CCF", "DCT"]

    func checkObjects() {
        var visited = Set<Int>()
        var stack: [(value: PdfObject, owner: Int)] = [(document.trailer, 0)]
        var steps = 0
        while steps < Self.maxSteps, let (value, owner) = stack.popLast() {
            steps += 1
            // The place goes through the localiser, so it is built only where an issue is added.
            func place() -> String { owner == 0 ? PdfAText.trailer : PdfAText.objectName(owner) }
            switch value {
            case let reference as PdfReference:
                if visited.insert(reference.number).inserted, let target = document.get(reference.number) { stack.append((target, reference.number)) }
            case let array as PdfArray:
                checkLimits(array, place())
                for item in array.items { stack.append((item, owner)) }
            case let stream as PdfStream:
                checkStream(stream, owner, place())
                stack.append((stream.dictionary, owner))
            case let dictionary as PdfDictionary:
                checkLimits(dictionary, place())
                if dictionary.containsKey("EF") { checkFileSpec(dictionary, place()) }
                for entry in dictionary.entries { stack.append((entry.value, owner)) }
            default:
                checkLimits(value, place())
            }
        }
    }

    // The limits one value can break: 6.1.12 in part 1, 6.1.13 after. Part 1 also bounds reals and the size of arrays and dictionaries.
    func checkLimits(_ value: PdfObject, _ place: @autoclosure () -> String) {
        let clause = c("6.1.12", "6.1.13")
        switch value {
        case let text as PdfString where text.bytes.count > (isPart1 ? 65535 : 32767):
            add(clause, place(), PdfAText.stringTooLong(text.bytes.count))
        case let name as PdfName where name.value.utf8.count > 127:
            add(clause, place(), PdfAText.nameTooLong)
        case let number as PdfNumber where number.isInteger && (number.value > Double(Int32.max) || number.value < Double(Int32.min)):
            add(clause, place(), PdfAText.integerTooBig(number.text))
        case let real as PdfNumber where !real.isInteger && isPart1 && abs(real.value) > 32767:
            add(clause, place(), PdfAText.realTooBig(real.text))
        case let array as PdfArray where isPart1 && array.items.count > 8191:
            add(clause, place(), PdfAText.arrayTooLong(array.items.count))
        case let dictionary as PdfDictionary where isPart1 && dictionary.count > 4095:
            add(clause, place(), PdfAText.dictionaryTooBig(dictionary.count))
        default:
            break
        }
    }

    func checkStream(_ stream: PdfStream, _ owner: Int, _ place: @autoclosure () -> String) {
        let d = stream.dictionary
        if owner > 0 { checkStreamSyntax(stream, place()) }
        for key in ["F", "FFilter", "FDecodeParms"] where d.containsKey(key) { add("6.1.7", place(), PdfAText.streamKey(key)) }
        checkFilters(d, place(), false)
    }

    // Part 1 names LZW alone (6.1.10). Later parts name it with the other filters in 6.1.7.2 and keep 6.1.10 for inline images; they list the
    // filters of Table 6 in ISO 32000-1 and take a Crypt filter only as the identity, in a stream and never in an inline image.
    func checkFilters(_ owner: PdfDictionary, _ place: @autoclosure () -> String, _ inline: Bool) {
        let clause = isPart1 || inline ? "6.1.10" : "6.1.7.2"
        let filters = filterNames(owner)
        for (i, filter) in filters.enumerated() {
            if Self.isFilter(filter, "LZWDecode", "LZW") {
                add(clause, place(), PdfAText.lzw)
            } else if filter == "Crypt" && inline {
                add(clause, place(), PdfAText.cryptFilter)
            } else if filter == "Crypt" {
                checkCrypt(owner, i, clause, place())
            } else if !isPart1 && !filter.isEmpty && !Self.table6.contains(filter) && !(inline && Self.inlineFilters.contains(filter)) {
                add(clause, place(), PdfAText.unknownFilter(filter))
            }
        }
    }

    private func checkCrypt(_ owner: PdfDictionary, _ index: Int, _ clause: String, _ place: @autoclosure () -> String) {
        let parameters: PdfDictionary?
        switch document.resolve(owner["DecodeParms"] ?? owner["DP"]) {
        case let list as PdfArray: parameters = index < list.items.count ? document.resolve(list.items[index]) as? PdfDictionary : nil
        case let single as PdfDictionary: parameters = single
        default: parameters = nil
        }
        if isPart1 || (document.name(parameters, "Name") ?? "Identity") != "Identity" { add(clause, place(), PdfAText.cryptFilter) }
    }

    func checkFileSpec(_ spec: PdfDictionary, _ place: @autoclosure () -> String) {
        if part == 1 || part == 4 {
            add(isPart1 ? "6.1.11" : "6.8", place(), PdfAText.embeddedFile)
            return
        }
        var stream: PdfStream?
        if let ef = document.dict(spec, "EF") { stream = document.stream(ef, "F") ?? document.stream(ef, "UF") }
        if part == 2 {
            if let stream, Self.isPdfA(document, stream) { return }
            add("6.8", place(), PdfAText.embeddedNotPdfA)
            return
        }
        if !spec.containsKey("AFRelationship") { add("6.8", place(), PdfAText.noRelationship) }
        if let stream, document.name(stream.dictionary, "Subtype") == nil { add("6.8", place(), PdfAText.noMimeType) }
    }

    static func isPdfA(_ document: PdfDocument, _ stream: PdfStream) -> Bool {
        do {
            let data = try document.data(stream, 256 << 20)
            if !data.hasPattern(Array("%PDF-".utf8), at: 0) { return false }
            let inner = try PdfDocument.open(data)
            return inner.pdfAPart == 1 || inner.pdfAPart == 2
        } catch {
            return false
        }
    }
}
