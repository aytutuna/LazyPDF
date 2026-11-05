import Foundation

// Twin of windows/LazyPDF.Core/Standards/PdfAChecker.Metadata.cs: the catalog: output intents, XMP metadata and its
// agreement with /Info, optional content, names and open action.

extension PdfAChecker {
    func checkCatalog() {
        let catalog = document.catalog
        checkOutputIntents()
        checkMetadata()
        checkOptionalContent()
        if catalog.containsKey("AA") { add(part == 4 ? "6.6.3" : c("6.6.2", "6.5.2"), PdfAText.catalog, PdfAText.catalogTriggers) }
        if !isPart1 && catalog.containsKey("NeedsRendering") { add("6.4.2", PdfAText.catalog, PdfAText.needsRendering) }
        checkAction(catalog["OpenAction"], PdfAText.catalog)
        checkOutlines()
        if document.dict(document.dict(catalog, "Names"), "JavaScript") != nil { add(c("6.6.1", "6.5.1"), PdfAText.catalog, PdfAText.javaScript) }
        checkForm()
    }

    private func checkOutputIntents() {
        let clause = c("6.2.2", "6.2.3")
        var profileNumber: Int?
        for item in document.array(document.catalog, "OutputIntents")?.items.prefix(16) ?? [] {
            guard let intent = document.resolve(item) as? PdfDictionary else { continue }
            if !(document.resolve(intent["OutputConditionIdentifier"]) is PdfString) { add(clause, PdfAText.outputIntent, PdfAText.noConditionIdentifier) }
            guard let profile = document.stream(intent, "DestOutputProfile") else {
                if document.name(intent, "S") == "GTS_PDFA1" { add(clause, PdfAText.outputIntent, PdfAText.noProfile) }
                continue
            }
            let number = (intent["DestOutputProfile"] as? PdfReference)?.number
            if let first = profileNumber, first != number { add(clause, PdfAText.outputIntent, PdfAText.profilesDiffer) }
            profileNumber = profileNumber ?? number
            guard let n = document.integer(profile.dictionary, "N"), n == 1 || n == 3 || n == 4 else {
                add(clause, PdfAText.outputIntent, PdfAText.profileComponents)
                continue
            }
            let fault: String?
            do {
                fault = Self.iccProblem(try document.data(profile, 32 << 20), n, isPart1 ? 2 : 4, true)
            } catch {
                fault = PdfAText.profileUnreadable
            }
            if let fault {
                add(clause, PdfAText.outputIntent, fault)
            } else if intentComponents == 0 && document.name(intent, "S") == "GTS_PDFA1" {
                intentComponents = n
            }
        }
    }

    private func checkMetadata() {
        let clause = c("6.7.2", "6.6.2.1")
        guard let stream = document.stream(document.catalog, "Metadata") else {
            add(clause, PdfAText.catalog, PdfAText.noMetadata)
            return
        }
        if stream.dictionary.containsKey("Filter") { add(clause, PdfAText.metadata, PdfAText.metadataFilter) }
        let bytes: [UInt8]
        do {
            bytes = try document.data(stream, 16 << 20)
        } catch {
            add(clause, PdfAText.metadata, PdfAText.xmpNotWellFormed)
            return
        }
        let (xmp, problem) = PdfAXmp.parse(bytes)
        guard let xmp else {
            add(clause, PdfAText.metadata, problem ?? "")
            return
        }
        checkIdentification(xmp)
        for ns in xmp.undeclaredNamespaces() { add(c("6.7.8", "6.6.2.3.1"), PdfAText.metadata, PdfAText.noExtensionSchema(ns)) }
        checkInfo(xmp)
    }

    private func checkIdentification(_ xmp: PdfAXmp) {
        let clause = c("6.7.11", "6.6.4")
        let part = xmp.get(PdfAXmp.id, "part").map { PdfDate.trimmed($0) }
        let conformance = xmp.get(PdfAXmp.id, "conformance").map { PdfDate.trimmed($0) }
        guard let found = part else {
            add(clause, PdfAText.metadata, PdfAText.noIdentification)
            return
        }
        if found != String(self.part) { add(clause, PdfAText.metadata, PdfAText.wrongPart(found, self.part)) }
        if self.part == 4 {
            if xmp.get(PdfAXmp.id, "rev").map({ PdfDate.trimmed($0) }) != "2020" { add(clause, PdfAText.metadata, PdfAText.noRevision) }
            return
        }
        let accepted = level.needsUnicode() ? ["U", "A"] : isPart1 ? ["B", "A"] : ["B", "U", "A"]
        if conformance == nil || !accepted.contains(conformance ?? "") {
            add(clause, PdfAText.metadata, PdfAText.wrongConformance(conformance, level.conformance() ?? ""))
        }
    }

    // 6.7.3 in part 1: every /Info entry that has an XMP property has the same value there.
    private func checkInfo(_ xmp: PdfAXmp) {
        guard let info = document.info else { return }
        let clause = c("6.7.3", "6.6.2.3")
        if part == 4 {
            for (key, _) in info.entries where key != "CreationDate" && key != "ModDate" { add("6.1.3", PdfAText.info, PdfAText.infoKey(key)) }
        }
        func same(_ key: String, _ other: String, _ ns: String, _ property: String) {
            guard let value = PdfText.read(document, info, key) else { return }
            let xmpValue = xmp.get(ns, property)
            let equal: Bool
            if key == "CreationDate" || key == "ModDate" {
                if let a = PdfDate.parse(value), let b = PdfDate.parseXmp(xmpValue) {
                    equal = Self.wholeSeconds(a) == Self.wholeSeconds(b)
                } else {
                    equal = false
                }
            } else {
                equal = xmpValue == value
            }
            if !equal { add(clause, PdfAText.info, PdfAText.infoDiffers(key, other)) }
        }
        if part == 4 {
            same("CreationDate", "xmp:CreateDate", PdfAXmp.xmp, "CreateDate")
            same("ModDate", "xmp:ModifyDate", PdfAXmp.xmp, "ModifyDate")
            return
        }
        same("Title", "dc:title", PdfAXmp.dc, "title")
        same("Author", "dc:creator", PdfAXmp.dc, "creator")
        same("Subject", "dc:description", PdfAXmp.dc, "description")
        same("Keywords", "pdf:Keywords", PdfAXmp.pdf, "Keywords")
        same("Creator", "xmp:CreatorTool", PdfAXmp.xmp, "CreatorTool")
        same("Producer", "pdf:Producer", PdfAXmp.pdf, "Producer")
        same("CreationDate", "xmp:CreateDate", PdfAXmp.xmp, "CreateDate")
        same("ModDate", "xmp:ModifyDate", PdfAXmp.xmp, "ModifyDate")
    }

    // ToUnixTimeSeconds drops the fraction of a second; the same instant at whole seconds.
    private static func wholeSeconds(_ date: DateTimeOffset) -> DateTimeOffset {
        DateTimeOffset(valid: date.year, date.month, date.day, date.hour, date.minute, date.second, ticks: 0, offsetMinutes: date.offsetMinutes) ?? date
    }

    private func checkOptionalContent() {
        guard let properties = document.dict(document.catalog, "OCProperties") else { return }
        if isPart1 {
            add("6.1.13", PdfAText.catalog, PdfAText.optionalContent)
            return
        }
        let clause = "6.9"
        var configs: [PdfDictionary] = []
        if let main = document.dict(properties, "D") {
            configs.append(main)
        } else {
            add(clause, PdfAText.catalog, PdfAText.noDefaultConfig)
        }
        for item in document.array(properties, "Configs")?.items.prefix(256) ?? [] {
            if let config = document.resolve(item) as? PdfDictionary { configs.append(config) }
        }

        var names = Set<String>()
        let groups = Set((document.array(properties, "OCGs")?.items ?? []).compactMap { ($0 as? PdfReference)?.number })
        for config in configs {
            if let name = document.resolve(config["Name"]) as? PdfString {
                if !names.insert(Latin1.string(name.bytes)).inserted { add(clause, PdfAText.catalog, PdfAText.configNameTwice) }
            } else {
                add(clause, PdfAText.catalog, PdfAText.configName)
            }
            if config.containsKey("AS") { add(clause, PdfAText.catalog, PdfAText.autoState) }
            if let order = document.array(config, "Order"), !groups.isSubset(of: Self.listed(order)) { add(clause, PdfAText.catalog, PdfAText.orderIncomplete) }
        }
    }

    private static func listed(_ order: PdfArray) -> Set<Int> {
        var numbers = Set<Int>()
        var stack = [order]
        var steps = 0
        while steps < 10_000, let next = stack.popLast() {
            for item in next.items {
                if let r = item as? PdfReference {
                    numbers.insert(r.number)
                } else if let inner = item as? PdfArray {
                    stack.append(inner)
                }
            }
            steps += 1
        }
        return numbers
    }
}
