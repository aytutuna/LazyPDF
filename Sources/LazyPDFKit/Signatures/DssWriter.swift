import Foundation

// Twin of windows/LazyPDF.Core/Signatures/DssWriter.cs: the /DSS dictionary (ETSI EN 319 142-1 5.4.2): shared streams
// of certificates, OCSP responses and CRLs, and a /VRI entry per signature, keyed by the SHA-1 of its /Contents. What
// the file already holds is reused, not written twice.

final class DssWriter {
    final class Entry {
        var certificates: [PdfReference] = []
        var ocsps: [PdfReference] = []
        var crls: [PdfReference] = []
    }

    private let document: PdfDocument
    private let dss: PdfDictionary
    private let dssReference: PdfReference?
    private let vri: PdfDictionary
    private var known: [String: PdfReference] = [:]
    private var touched = false

    init(_ document: PdfDocument) throws {
        self.document = document
        if let reference = document.catalog["DSS"] as? PdfReference, let existing = document.resolve(reference) as? PdfDictionary {
            dss = existing
            dssReference = reference
        } else if let direct = document.catalog["DSS"] as? PdfDictionary {
            dss = direct
            dssReference = nil
        } else {
            dss = PdfDictionary()
            dss["Type"] = PdfName("DSS")
            dssReference = nil
        }
        vri = document.dict(dss, "VRI") ?? PdfDictionary()
        for key in ["Certs", "OCSPs", "CRLs"] {
            guard let array = document.array(dss, key) else { continue }
            for item in array.items {
                if let r = item as? PdfReference, let stream = document.resolve(r) as? PdfStream {
                    let hash = Self.hash(try document.data(stream))
                    if known[hash] == nil { known[hash] = r }
                }
            }
        }
    }

    func certificate(_ certificate: X509Certificate) throws -> PdfReference { try stream("Certs", certificate.rawData) }
    func ocsp(_ der: [UInt8]) throws -> PdfReference { try stream("OCSPs", der) }
    func crl(_ der: [UInt8]) throws -> PdfReference { try stream("CRLs", der) }

    func signature(_ contents: [UInt8], _ entry: Entry, _ time: DateTimeOffset) {
        let key = Sha1.hash(contents).map { String(format: "%02X", $0) }.joined()
        if vri.containsKey(key) { return }
        let dictionary = PdfDictionary()
        dictionary["Type"] = PdfName("VRI")
        Self.addList(dictionary, "Cert", entry.certificates)
        Self.addList(dictionary, "OCSP", entry.ocsps)
        Self.addList(dictionary, "CRL", entry.crls)
        dictionary["TU"] = PdfString(bytes: Array(PdfDate.format(time).utf8), isHex: false)
        vri[key] = dictionary
        touched = true
    }

    /// Puts the dictionary in the catalog; nothing changes in the document when nothing was added.
    func save() throws {
        if !touched { return }
        if !dss.containsKey("VRI") { dss["VRI"] = vri }
        if dssReference == nil && document.catalog["DSS"] == nil { document.catalog["DSS"] = try document.add(dss) }
    }

    private func stream(_ list: String, _ bytes: [UInt8]) throws -> PdfReference {
        let hash = Self.hash(bytes)
        if let existing = known[hash] { return existing }
        let dictionary = PdfDictionary()
        dictionary["Filter"] = PdfName("FlateDecode")
        let reference = try document.add(PdfStream(dictionary, data: PdfFilterEncoders.flate(bytes)))
        known[hash] = reference
        touched = true
        if let array = document.array(dss, list) {
            array.items.append(reference)
        } else {
            dss[list] = PdfArray([reference])
        }
        return reference
    }

    private static func addList(_ dictionary: PdfDictionary, _ key: String, _ items: [PdfReference]) {
        if items.isEmpty { return }
        var distinct: [PdfReference] = []
        for item in items where !distinct.contains(item) { distinct.append(item) }
        dictionary[key] = PdfArray(distinct)
    }

    private static func hash(_ bytes: [UInt8]) -> String {
        Sha256.hash(bytes).map { String(format: "%02X", $0) }.joined()
    }
}
