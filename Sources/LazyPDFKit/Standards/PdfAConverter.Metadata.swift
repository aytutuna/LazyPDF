import Foundation

// Twin of windows/LazyPDF.Core/Standards/PdfAConverter.Metadata.cs: the output intent, the XMP packet and /Info.

extension PdfAConversionRun {
    func setOutputIntent() throws {
        var keep: PdfObject?
        for item in document.array(document.catalog, "OutputIntents")?.items.prefix(16) ?? [] {
            if let intent = document.resolve(item) as? PdfDictionary, let profile = document.stream(intent, "DestOutputProfile"), profileUsable(profile) {
                keep = item
                break
            }
        }
        if let keep, let kept = document.resolve(keep) as? PdfDictionary {
            kept["S"] = PdfName("GTS_PDFA1")
            if !(document.resolve(kept["OutputConditionIdentifier"]) is PdfString) {
                kept["OutputConditionIdentifier"] = PdfString(bytes: Array("Custom".utf8), isHex: false)
            }
            document.catalog["OutputIntents"] = PdfArray([keep])
            return
        }
        let dictionary = PdfDictionary()
        dictionary["N"] = PdfNumber(3)
        dictionary["Filter"] = PdfName("FlateDecode")
        let profileReference = try document.add(PdfStream(dictionary, data: PdfFilterEncoders.flate(PdfASrgb.srgbProfile)))
        let intentReference = try document.add(PdfAPacket.outputIntent(profileReference))
        document.catalog["OutputIntents"] = PdfArray([intentReference])
        changed(PdfAText.intentAdded)
    }

    private func profileUsable(_ profile: PdfStream) -> Bool {
        do {
            guard let n = document.integer(profile.dictionary, "N"), n == 1 || n == 3 || n == 4 else { return false }
            return PdfAChecker.iccProblem(try document.data(profile, 32 << 20), n, part == 1 ? 2 : 4) == nil
        } catch {
            return false
        }
    }

    func setMetadata() throws {
        var found = DocumentMetadata.read(document)
        found.title = PdfAPacket.strip(found.title)
        found.author = PdfAPacket.strip(found.author)
        found.subject = PdfAPacket.strip(found.subject)
        found.keywords = PdfAPacket.strip(found.keywords)
        found.creator = PdfAPacket.strip(found.creator)
        found.producer = PdfAPacket.strip(found.producer) ?? PdfAText.producer
        let created = found.created ?? date
        found.created = created
        found.modified = date

        let info: PdfDictionary
        if let existing = document.info {
            info = existing
        } else {
            info = PdfDictionary()
            document.trailer["Info"] = try document.add(info)
        }
        func put(_ key: String, _ value: String?) {
            if let value { info[key] = PdfText.toObject(value) } else { info.remove(key) }
        }
        if part == 4 {
            for (key, _) in info.entries where key != "CreationDate" && key != "ModDate" { info.remove(key) }
        } else {
            put("Title", found.title)
            put("Author", found.author)
            put("Subject", found.subject)
            put("Keywords", found.keywords)
            put("Creator", found.creator)
            put("Producer", found.producer)
        }
        info["CreationDate"] = PdfString(bytes: Array(PdfDate.format(created).utf8), isHex: false)
        info["ModDate"] = PdfString(bytes: Array(PdfDate.format(date).utf8), isHex: false)

        meta = found
        try putPacket(declare: true)
        changed(PdfAText.metadataWritten(level))
    }

    // The packet names the level only for a file the validator passes: a file that says it is PDF/A and is not
    // is worse than one that makes no claim.
    func putPacket(declare: Bool) throws {
        guard let meta else { return }
        let dictionary = PdfDictionary()
        dictionary["Type"] = PdfName("Metadata")
        dictionary["Subtype"] = PdfName("XML")
        document.catalog["Metadata"] = try document.add(PdfStream(dictionary, data: PdfAPacket.xmp(level, meta, date, declare)))
    }
}
