import Foundation

// Twin of windows/LazyPDF.Core/Office/OpcPackage.cs.

struct OpcRelationship {
    let id: String
    let type: String
    let target: String
    let part: String
}

/// An Office Open XML package on top of `ZipReader`: content types, relationships and parsed parts. Part names are
/// absolute (no leading slash), relationship targets are resolved against their source part, and external targets are
/// never followed.
final class OpcPackage {
    static let contentTypesNs = "http://schemas.openxmlformats.org/package/2006/content-types"
    static let relationshipsNs = "http://schemas.openxmlformats.org/package/2006/relationships"
    static let officeDocument = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument"

    private let zip: ZipReader
    private var defaults: [String: String] = [:]
    private var overrides: [String: String] = [:]
    private var parsed: [String: OfficeXmlElement] = [:]

    private init(_ zip: ZipReader) { self.zip = zip }

    static func open(_ data: [UInt8], _ limits: ZipLimits = .standard) throws -> OpcPackage {
        let package = OpcPackage(try ZipReader.open(data, limits))
        guard package.zip.contains("[Content_Types].xml") else {
            throw PdfReadException.damaged("The file is not an Office document: it has no [Content_Types].xml.")
        }
        for e in try package.xml("[Content_Types].xml").elements {
            if e.uri != contentTypesNs { continue }
            guard let type = e.attribute("ContentType") else { continue }
            if e.name == "Default", let ext = e.attribute("Extension") {
                package.defaults[ZipReader.key(ext)] = type
            } else if e.name == "Override", let name = e.attribute("PartName") {
                let trimmed = String(String.UnicodeScalarView(name.unicodeScalars.drop { $0 == "/" }))
                package.overrides[ZipReader.key(trimmed)] = type
            }
        }
        return package
    }

    func contains(_ part: String) -> Bool { zip.contains(part) }

    func bytes(_ part: String) throws -> [UInt8] { try zip.read(part) }

    func xml(_ part: String) throws -> OfficeXmlElement {
        let key = ZipReader.key(part)
        if let known = parsed[key] { return known }
        let root = try OfficeXml.parse(try zip.read(part))
        parsed[key] = root
        return root
    }

    func contentType(_ part: String) -> String? {
        if let type = overrides[ZipReader.key(part)] { return type }
        let scalars = Array(part.unicodeScalars)
        guard let dot = scalars.lastIndex(of: ".") else { return nil }
        return defaults[ZipReader.key(String(String.UnicodeScalarView(scalars[(dot + 1)...])))]
    }

    /// The internal relationships of `part` (empty string for the package itself).
    func relationships(_ part: String) throws -> [OpcRelationship] {
        let scalars = Array(part.unicodeScalars)
        let slash = scalars.lastIndex(of: "/")
        let folder = slash.map { String(String.UnicodeScalarView(scalars[..<$0])) } ?? ""
        let name = slash.map { String(String.UnicodeScalarView(scalars[($0 + 1)...])) } ?? part
        let path = (folder.isEmpty ? "" : folder + "/") + "_rels/" + name + ".rels"
        var list: [OpcRelationship] = []
        if !zip.contains(path) { return list }
        for e in try xml(path).elements(Self.relationshipsNs, "Relationship") {
            guard let id = e.attribute("Id"), let type = e.attribute("Type"), let target = e.attribute("Target"),
                  e.attribute("TargetMode") != "External" else { continue }
            list.append(OpcRelationship(id: id, type: type, target: Self.resolve(part, target), part: part))
        }
        return list
    }

    private static func split(_ text: String) -> [String] {
        text.unicodeScalars.split(separator: "/", omittingEmptySubsequences: false).map { String(String.UnicodeScalarView($0)) }
    }

    private static func resolve(_ source: String, _ target: String) -> String {
        var segments: [String] = []
        if !target.unicodeScalars.starts(with: "/".unicodeScalars) {
            let scalars = Array(source.unicodeScalars)
            if let slash = scalars.lastIndex(of: "/") {
                segments.append(contentsOf: split(String(String.UnicodeScalarView(scalars[..<slash]))))
            }
        }
        for s in split(String(String.UnicodeScalarView(target.unicodeScalars.map { $0 == "\\" ? "/" : $0 }))) {
            if s == ".." {
                if !segments.isEmpty { segments.removeLast() }
            } else if !s.isEmpty && s != "." {
                segments.append(s)
            }
        }
        return segments.joined(separator: "/")
    }
}
