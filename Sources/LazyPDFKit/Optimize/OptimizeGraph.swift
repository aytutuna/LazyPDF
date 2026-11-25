import Foundation

// Twin of windows/LazyPDF.Core/Optimize/OptimizeGraph.cs: walks over the objects of an open document, without
// following references.

enum PdfGraph {
    private static let maxDepth = 64

    /// The objects the document lists, as (number, value); free and unreadable ones are left out.
    static func objects(_ document: PdfDocument) -> [(number: Int, value: PdfObject)] {
        var list: [(number: Int, value: PdfObject)] = []
        for number in document.objectNumbers {
            if let value = document.get(number), !(value is PdfNull) { list.append((number, value)) }
        }
        return list
    }

    /// Every dictionary inside `root`, stream dictionaries and direct ones included, the root's own first.
    static func dictionaries(_ root: PdfObject?) -> [PdfDictionary] {
        var found: [PdfDictionary] = []
        var stack: [(value: PdfObject, depth: Int)] = []
        if let root { stack.append((root, 0)) }
        while let (value, depth) = stack.popLast() {
            if depth > maxDepth { continue }
            switch value {
            case let stream as PdfStream:
                stack.append((stream.dictionary, depth))
            case let dictionary as PdfDictionary:
                found.append(dictionary)
                for (_, item) in dictionary.entries { stack.append((item, depth + 1)) }
            case let array as PdfArray:
                for item in array.items { stack.append((item, depth + 1)) }
            default:
                break
            }
        }
        return found
    }

    /// Every dictionary in the file, indirect or not, in object order.
    static func allDictionaries(_ document: PdfDocument) -> [PdfDictionary] {
        var all: [PdfDictionary] = []
        for (_, value) in objects(document) { all += dictionaries(value) }
        all += dictionaries(document.trailer)
        return all
    }

    /// The references written inside `root`.
    static func references(_ root: PdfObject?) -> [PdfReference] {
        var found: [PdfReference] = []
        var stack: [(value: PdfObject, depth: Int)] = []
        if let root { stack.append((root, 0)) }
        while let (value, depth) = stack.popLast() {
            if depth > maxDepth { continue }
            switch value {
            case let reference as PdfReference:
                found.append(reference)
            case let stream as PdfStream:
                stack.append((stream.dictionary, depth))
            case let dictionary as PdfDictionary:
                for (_, item) in dictionary.entries { stack.append((item, depth + 1)) }
            case let array as PdfArray:
                for item in array.items { stack.append((item, depth + 1)) }
            default:
                break
            }
        }
        return found
    }

    /// Points every reference to a key of `map` at its value, in every object and the trailer.
    static func redirect(_ document: PdfDocument, _ map: [Int: Int]) {
        if map.isEmpty { return }
        for (_, value) in objects(document) { redirectIn(value, map) }
        redirectIn(document.trailer, map)
    }

    private static func redirectIn(_ root: PdfObject, _ map: [Int: Int]) {
        for container in containersOf(root) {
            if let dictionary = container as? PdfDictionary {
                for (key, item) in dictionary.entries {
                    if let r = item as? PdfReference, let to = map[r.number] { dictionary[key] = PdfReference(to, 0) }
                }
            } else if let array = container as? PdfArray {
                for i in 0..<array.items.count {
                    if let r = array.items[i] as? PdfReference, let to = map[r.number] { array.items[i] = PdfReference(to, 0) }
                }
            }
        }
    }

    /// The dictionaries and arrays inside `root`, its own first.
    static func containersOf(_ root: PdfObject) -> [PdfObject] {
        var found: [PdfObject] = []
        var stack: [(value: PdfObject, depth: Int)] = [(root, 0)]
        while let (value, depth) = stack.popLast() {
            if depth > maxDepth { continue }
            switch value {
            case let stream as PdfStream:
                stack.append((stream.dictionary, depth))
            case let dictionary as PdfDictionary:
                found.append(dictionary)
                for (_, item) in dictionary.entries { stack.append((item, depth + 1)) }
            case let array as PdfArray:
                found.append(array)
                for item in array.items { stack.append((item, depth + 1)) }
            default:
                break
            }
        }
        return found
    }

    /// Takes the references to `numbers` out of every dictionary (the entry goes) and array (the item goes).
    static func detach(_ document: PdfDocument, _ numbers: Set<Int>) {
        if numbers.isEmpty { return }
        for (_, value) in objects(document) {
            for container in containersOf(value) {
                if let dictionary = container as? PdfDictionary {
                    for (key, item) in dictionary.entries {
                        if let r = item as? PdfReference, numbers.contains(r.number) { dictionary.remove(key) }
                    }
                } else if let array = container as? PdfArray {
                    array.items.removeAll { ($0 as? PdfReference).map { numbers.contains($0.number) } ?? false }
                }
            }
        }
    }

    /// The dictionary's text with references named by `name`, entries sorted, /Length left out for a stream.
    static func canonical(_ value: PdfObject, _ name: (Int) -> Int, _ skipLength: Bool) -> String {
        var text = ""
        write(&text, value, name, skipLength, 0)
        return text
    }

    private static func write(_ text: inout String, _ value: PdfObject, _ name: (Int) -> Int, _ skipLength: Bool, _ depth: Int) {
        if depth > maxDepth {
            text.append("~")
            return
        }
        switch value {
        case let reference as PdfReference:
            text.append("R\(name(reference.number)) ")
        case let stream as PdfStream:
            write(&text, stream.dictionary, name, true, depth)
        case let dictionary as PdfDictionary:
            text.append("<<")
            var keys: [String] = []
            var known = Set<String>()
            for (key, _) in dictionary.entries where known.insert(key).inserted { keys.append(key) }
            keys.sort { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) }
            for key in keys {
                if skipLength && key == "Length" { continue }
                text.append("/\(key) ")
                if let item = dictionary[key] { write(&text, item, name, false, depth + 1) }
            }
            text.append(">>")
        case let array as PdfArray:
            text.append("[")
            for item in array.items { write(&text, item, name, false, depth + 1) }
            text.append("]")
        case let string as PdfString:
            text.append("(\(hex(string.bytes)))")
        default:
            value.writeTo(&text)
            text.append(" ")
        }
    }

    /// Upper-case hexadecimal, as `Convert.ToHexString`.
    static func hex(_ bytes: [UInt8]) -> String {
        let digits = Array("0123456789ABCDEF".unicodeScalars)
        var text = String.UnicodeScalarView()
        for b in bytes {
            text.append(digits[Int(b >> 4)])
            text.append(digits[Int(b & 15)])
        }
        return String(text)
    }

    /// Gives a stream new content, deflated when that is smaller; its old filter and parameters go.
    static func setData(_ stream: PdfStream, _ data: [UInt8]) {
        let packed = PdfFilterEncoders.flate(data, .smallestSize)
        stream.dictionary.remove("DecodeParms")
        if packed.count < data.count {
            stream.data = packed
            stream.dictionary["Filter"] = PdfName("FlateDecode")
        } else {
            stream.data = data
            stream.dictionary.remove("Filter")
        }
    }

    /// Bytes an object takes in a file, near enough for counting: its text, and a stream's stored data.
    static func sizeOf(_ document: PdfDocument, _ value: PdfObject) -> Int {
        var text = ""
        write(&text, (value as? PdfStream)?.dictionary ?? value, { $0 }, false, 0)
        var size = text.utf16.count + 20
        if let stream = value as? PdfStream { size += document.rawData(stream).count + 18 }
        return size
    }
}
