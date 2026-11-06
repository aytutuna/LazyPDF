import Foundation

// Twin of windows/LazyPDF.Core/Optimize/SanitizeSignatures.cs: a rewrite breaks every signature (the byte ranges no
// longer match), and what stays behind still names the signer: the CMS blob with the certificate chain, the reason
// and place, the appearance, the validation data of /DSS and the permissions of /Perms.

enum SanitizeSignatures {
    /// Takes signature values, their appearances, /DSS, /Perms and /SigFlags out of `document`; returns how many signatures there were.
    static func strip(_ document: PdfDocument) -> Int {
        var count = 0
        for field in PdfGraph.allDictionaries(document) {
            if !isSignature(document, field) { continue }
            field.remove("V")
            clearAppearances(document, field)
            count += 1
        }
        let form = document.dict(document.catalog, "AcroForm")
        let left = document.catalog.containsKey("Perms") || document.catalog.containsKey("DSS") || form?.containsKey("SigFlags") == true
        document.catalog.remove("Perms")
        document.catalog.remove("DSS")
        form?.remove("SigFlags")
        return count == 0 && left ? 1 : count
    }

    // The kids of a field, however deep, are its widgets and sub-fields; none of them has a value of its own to be known by.
    private static func clearAppearances(_ document: PdfDocument, _ field: PdfDictionary) {
        var seen: Set<ObjectIdentifier> = [ObjectIdentifier(field)]
        var pending = [field]
        while let node = pending.popLast() {
            node.remove("AP")
            guard let kids = document.array(node, "Kids") else { continue }
            for kid in kids.items {
                if let child = document.resolve(kid) as? PdfDictionary, seen.insert(ObjectIdentifier(child)).inserted { pending.append(child) }
            }
        }
    }

    // /Type of the value is optional (12.8.1), so a signature field is also known by its inherited /FT.
    private static func isSignature(_ document: PdfDocument, _ field: PdfDictionary) -> Bool {
        guard let value = document.dict(field, "V") else { return false }
        if let type = document.name(value, "Type"), type == "Sig" || type == "DocTimeStamp" { return true }
        if value.containsKey("ByteRange") { return true }
        var node: PdfDictionary? = field
        var depth = 0
        while let current = node, depth < 16 {
            if let type = document.name(current, "FT") { return type == "Sig" }
            node = document.dict(current, "Parent")
            depth += 1
        }
        return false
    }
}
