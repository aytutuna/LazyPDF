import Foundation

// Twin of windows/LazyPDF.Core/Annotations/Fdf/ObjectCopier.cs: copies a value and everything it refers to from one
// object space into another (a document into an FDF file or the other way round), once per source object, cycles
// included.

final class ObjectCopier {
    private static let maxObjects = 100_000
    private static let maxDepth = 64

    private let resolve: (PdfObject?) -> PdfObject?
    private let rawData: (PdfStream) -> [UInt8]
    private let reserve: () throws -> PdfReference
    private let store: (PdfReference, PdfObject) -> Void

    private var map: [Int: PdfReference] = [:]
    private var count = 0

    init(resolve: @escaping (PdfObject?) -> PdfObject?, rawData: @escaping (PdfStream) -> [UInt8],
         reserve: @escaping () throws -> PdfReference, store: @escaping (PdfReference, PdfObject) -> Void) {
        self.resolve = resolve
        self.rawData = rawData
        self.reserve = reserve
        self.store = store
    }

    /// Says that source object `number` is already `target` over there.
    func preload(_ number: Int, _ target: PdfReference) {
        map[number] = target
    }

    func copy(_ value: PdfObject, _ depth: Int = 0) throws -> PdfObject {
        if depth > Self.maxDepth { return PdfNull.instance }
        if let reference = value as? PdfReference {
            if let mapped = map[reference.number] { return mapped }
            guard count < Self.maxObjects, let source = resolve(reference) else { return PdfNull.instance }
            count += 1
            let target = try reserve()
            map[reference.number] = target
            store(target, try copy(source, depth + 1))
            return target
        }
        if let dictionary = value as? PdfDictionary { return try copyDictionary(dictionary, depth) }
        if let array = value as? PdfArray { return PdfArray(try array.items.map { try copy($0, depth + 1) }) }
        if let stream = value as? PdfStream {
            let dictionary = try copyDictionary(stream.dictionary, depth)
            dictionary.remove("Length")
            return PdfStream(dictionary, data: rawData(stream))
        }
        if let text = value as? PdfString { return PdfString(bytes: text.bytes, isHex: text.isHex) }
        return value
    }

    private func copyDictionary(_ dictionary: PdfDictionary, _ depth: Int) throws -> PdfDictionary {
        let copy = PdfDictionary()
        for entry in dictionary.entries { copy[entry.key] = try self.copy(entry.value, depth + 1) }
        return copy
    }
}
