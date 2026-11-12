import Foundation

// Twin of windows/LazyPDF.Core/Signatures/SignatureField.cs: the form side of signing: the field that holds the
// signature, its widget, the signature dictionary and the entries that make a file certified or its fields locked.

enum SignatureField {
    private static let widgetFlags = 4 | 128 // Print, Locked

    /// Where the signature goes, found or made. Nothing is changed in the document until `attach`.
    struct Target {
        var field: PdfDictionary
        var fieldReference: PdfReference?
        var widget: PdfDictionary
        var rect: PdfRect
        var page: PdfPage
        var isNew: Bool
        var placed: Bool
        var name: String
    }

    static func resolve(_ document: PdfDocument, _ job: SignJob) throws -> Target {
        let request = job.request
        let form = PdfForm.read(document)
        if let wanted = request.fieldName, let existing = form.find(wanted) {
            if existing.kind != .signature || existing.isSigned { throw InvalidOperationException(SignatureText.fieldTaken) }
            try SeedValues.apply(document, existing.dictionary, job)
            if job.lock == nil, let lockDictionary = document.dict(existing.dictionary, "Lock") { job.lock = readLock(document, lockDictionary) }
            if let widget = existing.widgets.first, widget.pageIndex >= 0 {
                let pages = document.pages
                guard widget.pageIndex < pages.count else { throw ArgumentException(SignatureText.noPage) }
                return Target(field: existing.dictionary, fieldReference: existing.reference, widget: widget.dictionary, rect: widget.rect,
                              page: pages[widget.pageIndex], isNew: false, placed: true, name: existing.name)
            }
            // A field nobody placed gets a widget when it is signed.
            return Target(field: existing.dictionary, fieldReference: existing.reference, widget: existing.dictionary,
                          rect: request.rect ?? PdfRect(0, 0, 0, 0), page: try page(document, request.pageIndex), isNew: false, placed: false,
                          name: existing.name)
        }

        let name = request.fieldName ?? unique(form, "Signature")
        let field = PdfDictionary()
        return Target(field: field, fieldReference: nil, widget: field, rect: request.rect ?? PdfRect(0, 0, 0, 0),
                      page: try page(document, request.pageIndex), isNew: true, placed: false, name: name)
    }

    /// Why an earlier signature forbids this one: a certification that allows no changes, or a lock on the field to sign.
    static func refusal(_ document: PdfDocument, _ target: Target) -> String? {
        if SignatureChecker.level(document, 0).level == 1 { return SignatureText.certifiedClosed }
        if target.isNew { return nil }
        for found in attached(document) {
            for item in document.array(found.dictionary, "Reference")?.items ?? [] {
                guard let reference = document.resolve(item) as? PdfDictionary, document.name(reference, "TransformMethod") == "FieldMDP",
                      let parameters = document.dict(reference, "TransformParams"), let fieldLock = readLock(document, parameters) else { continue }
                let listed = fieldLock.fields.contains { sameText($0, target.name) }
                if fieldLock.action == .all || listed == (fieldLock.action == .include) { return SignatureText.fieldLocked }
            }
        }
        return nil
    }

    /// The signatures a field's /V or the catalog's /Perms /DocMDP still points to; a cleared one stays in the bytes but its locks and certification no longer apply.
    static func attached(_ document: PdfDocument) -> [FoundSignature] {
        var numbers = Set(PdfForm.read(document).fields.compactMap { ($0.dictionary["V"] as? PdfReference)?.number })
        if let perms = document.dict(document.catalog, "Perms"), let certification = perms["DocMDP"] as? PdfReference { numbers.insert(certification.number) }
        return SignatureScan.find(document.source).filter { numbers.contains($0.number) }
    }

    private static func page(_ document: PdfDocument, _ index: Int) throws -> PdfPage {
        let pages = document.pages
        guard index >= 0, index < pages.count else { throw ArgumentException(SignatureText.noPage) }
        return pages[index]
    }

    static func unique(_ form: PdfForm, _ prefix: String) -> String {
        var n = 1
        while true {
            let name = "\(prefix)\(n)"
            if form.find(name) == nil { return name }
            n += 1
        }
    }

    /// Hooks the signature into the file: the field's value, its widget and appearance, the form and the page.
    static func attach(_ document: PdfDocument, _ target: Target, _ signature: PdfReference, _ appearance: PdfReference?) throws {
        let field = target.field
        let widget = target.widget
        let placed = target.placed
        if target.isNew {
            field["FT"] = PdfName("Sig")
            field["T"] = PdfText.toObject(target.name)
        }
        field["V"] = signature
        if !placed {
            widget["Type"] = PdfName("Annot")
            widget["Subtype"] = PdfName("Widget")
            widget["Rect"] = target.rect.toArray()
            widget["F"] = PdfNumber(widgetFlags)
            widget["P"] = target.page.reference
        }
        if let appearance {
            let ap = PdfDictionary()
            ap["N"] = appearance
            widget["AP"] = ap
        }

        let reference = try target.fieldReference ?? document.add(field)
        if !placed {
            if let annots = document.array(target.page.dictionary, "Annots") {
                annots.items.append(reference)
            } else {
                target.page.dictionary["Annots"] = PdfArray([reference])
            }
        }
        if target.isNew || target.fieldReference == nil { addToForm(document, reference) } else { ensureFlags(document) }
    }

    private static func addToForm(_ document: PdfDocument, _ field: PdfReference) {
        var form = document.dict(document.catalog, "AcroForm")
        if form == nil {
            form = PdfDictionary()
            document.catalog["AcroForm"] = form
        }
        guard let form else { return }
        if let fields = document.array(form, "Fields") {
            fields.items.append(field)
        } else {
            form["Fields"] = PdfArray([field])
        }
        ensureFlags(document)
    }

    // SignaturesExist and AppendOnly: a viewer must save this file by incremental update.
    private static func ensureFlags(_ document: PdfDocument) {
        guard let form = document.dict(document.catalog, "AcroForm") else { return }
        form["SigFlags"] = PdfNumber((document.integer(form, "SigFlags") ?? 0) | 3)
    }

    static func dictionary(_ document: PdfDocument, _ job: SignJob, _ contents: PdfString, _ subFilter: String) -> PdfDictionary {
        let request = job.request
        let sig = PdfDictionary()
        sig["Type"] = PdfName("Sig")
        sig["Filter"] = PdfName("Adobe.PPKLite")
        sig["SubFilter"] = PdfName(subFilter)
        sig["ByteRange"] = SignedUpdate.byteRangePlaceholder()
        sig["Contents"] = contents
        sig["M"] = PdfString(bytes: Array(PdfDate.format(request.time).utf8), isHex: false)
        sig["Name"] = PdfText.toObject(job.name)
        if let reason = job.reason, !reason.isEmpty { sig["Reason"] = PdfText.toObject(reason) }
        if let location = request.location, !location.isEmpty { sig["Location"] = PdfText.toObject(location) }
        if let contact = request.contactInfo, !contact.isEmpty { sig["ContactInfo"] = PdfText.toObject(contact) }

        var references: [PdfObject] = []
        if job.certify != .none {
            let parameters = PdfDictionary()
            parameters["Type"] = PdfName("TransformParams")
            parameters["P"] = PdfNumber(job.certify.rawValue)
            parameters["V"] = PdfName("1.2")
            references.append(reference("DocMDP", parameters, document))
        }
        if let fieldLock = job.lock {
            let parameters = PdfDictionary()
            parameters["Type"] = PdfName("TransformParams")
            parameters["Action"] = PdfName(fieldLock.action.rawValue)
            parameters["V"] = PdfName("1.2")
            if fieldLock.action != .all { parameters["Fields"] = PdfArray(fieldLock.fields.map { PdfText.toObject($0) }) }
            references.append(reference("FieldMDP", parameters, document))
        }
        if !references.isEmpty { sig["Reference"] = PdfArray(references) }
        return sig
    }

    private static func reference(_ method: String, _ parameters: PdfDictionary, _ document: PdfDocument) -> PdfDictionary {
        let result = PdfDictionary()
        result["Type"] = PdfName("SigRef")
        result["TransformMethod"] = PdfName(method)
        result["TransformParams"] = parameters
        result["Data"] = document.trailer["Root"] ?? PdfNull.instance
        return result
    }

    /// The catalog's /Perms /DocMDP, which is what makes a signature a certification.
    static func certify(_ document: PdfDocument, _ signature: PdfReference) {
        var perms = document.dict(document.catalog, "Perms")
        if perms == nil {
            perms = PdfDictionary()
            document.catalog["Perms"] = perms
        }
        perms?["DocMDP"] = signature
    }

    /// A field's /Lock dictionary; the lock a signature of the field applies.
    static func writeLock(_ field: PdfDictionary, _ fieldLock: FieldLock) {
        let dictionary = PdfDictionary()
        dictionary["Type"] = PdfName("SigFieldLock")
        dictionary["Action"] = PdfName(fieldLock.action.rawValue)
        if fieldLock.action != .all { dictionary["Fields"] = PdfArray(fieldLock.fields.map { PdfText.toObject($0) }) }
        field["Lock"] = dictionary
    }

    static func readLock(_ document: PdfDocument, _ dictionary: PdfDictionary) -> FieldLock? {
        guard let name = document.name(dictionary, "Action"), let action = FieldLockAction(rawValue: name) else { return nil }
        let fields = document.array(dictionary, "Fields")?.items.compactMap { PdfText.read(document, $0) } ?? []
        return FieldLock(action, fields)
    }
}
