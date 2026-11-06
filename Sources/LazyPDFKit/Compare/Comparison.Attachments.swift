import Foundation

// Twin of windows/LazyPDF.Core/Compare/Comparison.Attachments.cs: the embedded files of the two documents, compared by
// content within a size cap and a budget.

extension Comparison {
    private static let maxAttachmentBytes = 64 << 20
    private static let attachmentBudget = 256 << 20
    private static let minReadCharge = 256 << 10

    /// A file name used twice keeps its later files under "name (2)", "name (3)".
    private func attachments(_ document: PdfDocument) throws -> InsertionMap<PdfStream> {
        var result = InsertionMap<PdfStream>()
        var used: [[UInt16]: Int] = [:]
        for attachment in PdfAttachments.list(document) {
            try Task.checkCancellation()
            guard let stream = PdfAttachments.streamOf(document, attachment) else { continue }
            let file = attachment.fileName
            let key = Array(file.utf16)
            var n = used[key] ?? 1
            var name = file
            while result.contains(name) {
                n += 1
                name = "\(file) (\(n))"
            }
            used[key] = n
            result.set(name, stream)
        }
        return result
    }

    /// What each file looks like in the file it is stored in. Streams may overlap, so the bytes read are limited to the
    /// size of the document plus the budget; a stream past that is described by its size alone.
    private func stored(_ document: PdfDocument, _ streams: InsertionMap<PdfStream>) throws -> InsertionMap<String> {
        var known: [StreamKey: String] = [:]
        var result = InsertionMap<String>()
        var budget = document.length + Self.attachmentBudget
        for (name, stream) in streams.entries {
            try Task.checkCancellation()
            var text = known[StreamKey(stream)]
            if text == nil {
                let size = document.rawLength(stream)
                if size > budget {
                    text = "\(size) bytes stored, not read"
                } else {
                    let bytes = document.rawData(stream)
                    budget -= bytes.count
                    text = "\(bytes.count) bytes stored, \(ImageLook.toHexString(Array(Sha256.hash(bytes).prefix(6))))"
                }
                known[StreamKey(stream)] = text
            }
            result.set(name, text ?? "")
        }
        return result
    }

    /// The decoded content of the files, nil for one that is larger than the cap, over the budget, or does not decode. A
    /// stream shared by several specifications is read once; a failed decode is charged its full limit, since it may have
    /// run to the limit before it gave up.
    private func decoded(_ document: PdfDocument, _ streams: InsertionMap<PdfStream>, _ skip: Set<[UInt16]>) throws -> InsertionMap<String?> {
        var known: [StreamKey: String?] = [:]
        var result = InsertionMap<String?>()
        var budget = Self.attachmentBudget, read = Self.attachmentBudget
        for (name, stream) in streams.entries {
            try Task.checkCancellation()
            if skip.contains(Array(name.utf16)) { continue }
            let text: String?
            if let seen = known[StreamKey(stream)] {
                text = seen
            } else {
                text = try Self.decode(document, stream, &budget, &read)
                known[StreamKey(stream)] = text
            }
            result.set(name, text)
        }
        return result
    }

    // The stored bytes of a stream are copied before any limit applies, and a filter allocates its buffers, so each stream
    // is charged to the read budget with a floor; one too long to come under the limit even after a filter (hex halves,
    // nothing shrinks more) is not read at all.
    private static func decode(_ document: PdfDocument, _ stream: PdfStream, _ budget: inout Int, _ read: inout Int) throws -> String? {
        let limit = min(maxAttachmentBytes, budget)
        if limit <= 0 { return nil }
        let size = document.rawLength(stream)
        let charge = max(size, minReadCharge)
        if size > (stream.dictionary.containsKey("Filter") ? 2 * limit : limit) || charge > read { return nil }
        read -= charge
        do {
            let data = try document.data(stream, limit)
            if data.count > limit { return nil }
            budget -= data.count
            return "\(data.count) bytes, \(ImageLook.toHexString(Array(Sha256.hash(data).prefix(6))))"
        } catch is PdfReadException {
            budget -= limit
            return nil
        }
    }

    /// A name whose stored bytes are equal on both sides is the same file and costs no decoding. Of the others, a file that
    /// one side could not decode is judged by its stored bytes on both sides, so the budget used by other attachments cannot
    /// make the two sides disagree on how to read it. A file stored differently on the two sides and too large to decode on
    /// either is reported as changed.
    func compareAttachments(_ changes: inout [CompareChange]) throws {
        let oldFiles = try attachments(before)
        let newFiles = try attachments(after)
        let storedBefore = try stored(before, oldFiles)
        let storedAfter = try stored(after, newFiles)
        var same = Set<[UInt16]>()
        for (name, text) in storedBefore.entries {
            if let other = storedAfter.lookup(name), Ordinal.equal(other, text) { same.insert(Array(name.utf16)) }
        }
        let decodedBefore = try decoded(before, oldFiles, same)
        let decodedAfter = try decoded(after, newFiles, same)
        func texts(_ stored: InsertionMap<String>, _ decoded: InsertionMap<String?>, _ other: InsertionMap<String?>) -> InsertionMap<String?> {
            var result = InsertionMap<String?>()
            for (name, value) in decoded.entries {
                var otherFailed = false
                if let o = other.lookup(name) { otherFailed = o == nil }
                if let text = value, !otherFailed {
                    result.set(name, text)
                } else {
                    result.set(name, stored.lookup(name))
                }
            }
            return result
        }
        Self.compareValues(texts(storedBefore, decodedBefore, decodedAfter), texts(storedAfter, decodedAfter, decodedBefore),
                           { "\(CompareText.attachment) \($0)" }, &changes)
    }
}
