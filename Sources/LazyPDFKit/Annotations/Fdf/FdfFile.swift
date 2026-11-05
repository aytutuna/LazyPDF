import Foundation

// Twin of windows/LazyPDF.Core/Annotations/Fdf/FdfFile.cs: what an FDF file holds (ISO 32000-1 12.7.7), the same for
// XFDF (ISO 19444-1): the PDF it belongs to, field values and annotations. Annotation dictionaries refer to each other
// (/IRT, /Popup) and to streams through the file's own object table, as in an FDF file; one read from XFDF gets its
// objects when it is first written or imported.

/// A field of an FDF or XFDF file (ISO 32000-1 12.7.7.3): its partial name, its value as written, and its kids.
public struct FdfField {
    public let name: String
    public let value: PdfObject?
    public let kids: [FdfField]

    public init(_ name: String, _ value: PdfObject?, _ kids: [FdfField]) {
        self.name = name
        self.value = value
        self.kids = kids
    }
}

/// An annotation of an FDF or XFDF file: the page it belongs to (from 0) and its dictionary.
public struct FdfAnnotation {
    public let pageIndex: Int
    public let dictionary: PdfDictionary

    public init(_ pageIndex: Int, _ dictionary: PdfDictionary) {
        self.pageIndex = pageIndex
        self.dictionary = dictionary
    }
}

public final class FdfFile {
    private static let maxObjects = 200_000

    private var next = 2

    /// The /F entry: the file the data was exported from.
    public var fileName: String?

    public var fields: [FdfField] = []

    public var annotations: [FdfAnnotation] = []

    var objects: [Int: PdfObject] = [:]

    public init() {}

    /// Follows a reference into the file's objects; anything else comes back as it is.
    public func resolve(_ value: PdfObject?) -> PdfObject? {
        var value = value
        var hops = 0
        while hops < 32, let reference = value as? PdfReference {
            value = objects[reference.number]
            hops += 1
        }
        return value is PdfReference ? nil : value
    }

    /// The fields with their dotted full names, in order; fields with kids are listed only through their kids.
    public func flatFields() -> [(key: String, value: PdfObject?)] {
        var list: [(key: String, value: PdfObject?)] = []
        for field in fields { Self.flatten(field, "", &list) }
        return list
    }

    private static func flatten(_ field: FdfField, _ prefix: String, _ list: inout [(key: String, value: PdfObject?)]) {
        if list.count >= maxObjects { return }
        let name = prefix.isEmpty ? field.name : field.name.isEmpty ? prefix : prefix + "." + field.name
        if field.kids.isEmpty {
            list.append((name, field.value))
        } else {
            if field.value != nil { list.append((name, field.value)) }
            for kid in field.kids { flatten(kid, name, &list) }
        }
    }

    func reserve() throws -> PdfReference {
        if next > Self.maxObjects { throw PdfReadException.damaged("The FDF data holds too many objects.") }
        let reference = PdfReference(next, 0)
        next += 1
        objects[reference.number] = PdfNull.instance
        return reference
    }

    func store(_ reference: PdfReference, _ value: PdfObject) {
        objects[reference.number] = value
    }

    func add(_ number: Int, _ value: PdfObject) {
        objects[number] = value
        if number >= next { next = number >= Int(Int32.max) ? Int(Int32.max) : number + 1 }
    }

    /// Gives every annotation an object of its own, turns an /IRT that names an annotation by /NM (XFDF) into a
    /// reference, and a direct /Popup dictionary into a popup annotation. Safe to repeat.
    func link() throws {
        var byDictionary: [ObjectIdentifier: PdfReference] = [:]
        for number in objects.keys.sorted() {
            if let dictionary = objects[number] as? PdfDictionary { byDictionary[ObjectIdentifier(dictionary)] = PdfReference(number, 0) }
        }
        for annotation in annotations where byDictionary[ObjectIdentifier(annotation.dictionary)] == nil {
            let reference = try reserve()
            store(reference, annotation.dictionary)
            byDictionary[ObjectIdentifier(annotation.dictionary)] = reference
        }
        var byName: [String: PdfReference] = [:]
        for annotation in annotations {
            if let nm = annotation.dictionary["NM"] as? PdfString, let reference = byDictionary[ObjectIdentifier(annotation.dictionary)] {
                let key = PdfText.decode(nm.bytes)
                if byName[key] == nil { byName[key] = reference }
            }
        }
        for annotation in annotations {
            let d = annotation.dictionary
            if let by = d["IRT"] as? PdfString {
                // A name that is none of this file's may be an annotation of the document it is imported into.
                if let parent = byName[PdfText.decode(by.bytes)] { d["IRT"] = parent }
            }
            if let popup = d["Popup"] as? PdfDictionary {
                let reference = try reserve()
                popup["Subtype"] = PdfName("Popup")
                if let owner = byDictionary[ObjectIdentifier(d)] { popup["Parent"] = owner }
                store(reference, popup)
                byDictionary[ObjectIdentifier(popup)] = reference
                d["Popup"] = reference
                annotations.append(FdfAnnotation(annotation.pageIndex, popup))
            }
        }
    }
}
