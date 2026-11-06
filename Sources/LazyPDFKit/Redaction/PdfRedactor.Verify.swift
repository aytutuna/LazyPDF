import Foundation

// Twin of windows/LazyPDF.Core/Redaction/PdfRedactor.Verify.cs: the check of the output. ZipArchive and GZipStream are
// `RedactionArchive`; whatever it cannot read counts as InvalidDataException does there.

extension PdfRedactor {
    private static let maxVerifiedStrings = 50_000
    private static let maxStream = 256 << 20
    private static let maxNested = 2
    private static let maxSpoken = 1 << 24

    /// Opens `output` again and looks for what should be gone: text extracted from inside any mark (apart from the `overlay`
    /// texts drawn there), and the `removed` strings, in every object and every decoded stream, in Latin-1, UTF-8 and UTF-16.
    /// The glyphs of page content are checked by the first test only, since they are coded by the font and the same words may
    /// be shown elsewhere. A marked page that `RedactionWalk` cannot follow to its end is a problem too. The problems say
    /// where, not what.
    public static func verify(_ output: [UInt8], _ marks: [RedactionMark], _ removed: [String], _ overlay: [String]? = nil,
                              _ password: String? = nil) -> RedactionVerification {
        var problems: [String] = []
        let document: PdfDocument
        do {
            document = try PdfDocument.open(output, password: password)
        } catch {
            return RedactionVerification([RedactionText.doesNotOpen])
        }
        let texts = (overlay ?? []).map { noSpaces($0) }.filter { !$0.isEmpty }
        // OrderByDescending is stable: the texts of one length keep their order.
        let shown = texts.enumerated().sorted { a, b in
            a.element.utf16.count != b.element.utf16.count ? a.element.utf16.count > b.element.utf16.count : a.offset < b.offset
        }.map { $0.element }
        var grouped: [Int: [RedactionMark]] = [:]
        for mark in marks where mark.page >= 0 && mark.page < document.pages.count { grouped[mark.page, default: []].append(mark) }
        for key in grouped.keys.sorted() {
            let areas = (grouped[key] ?? []).flatMap { $0.quads }.map { MarkArea.of($0) }.filter { $0.isUsable }
            let page = document.pages[key]
            let text = TextPage.create(document, page, TextPageOptions(removeDuplicates: false))
            var inside = noSpaces(text.chars.filter { c in areas.contains { Geometry.glyphMeets(Geometry.corners(c.quad), $0) } }.map { $0.text }.joined())
            for t in shown { inside = replacing(inside, t, "") }
            if !inside.isEmpty { problems.append(RedactionText.stillInside(key)) }
            let walk = RedactionWalk(document)
            if text.isTruncated || !walk.page(page) || !walk.annotations(page) { problems.append(RedactionText.notFollowed(key)) }
        }
        if removed.count > maxVerifiedStrings { problems.append(RedactionText.tooManyStrings) }
        lookForStrings(document, Array(removed.prefix(maxVerifiedStrings)), &problems)
        return RedactionVerification(problems)
    }

    private static func noSpaces(_ text: String) -> String {
        String(decoding: text.utf16.filter { !DotNetText.isWhiteSpace($0) }, as: UTF16.self)
    }

    // string.Replace(old, new, StringComparison.Ordinal) on UTF-16 units.
    private static func replacing(_ text: String, _ old: String, _ new: String) -> String {
        let units = Array(text.utf16), needle = Array(old.utf16), with = Array(new.utf16)
        if needle.isEmpty || units.count < needle.count { return text }
        var output: [UInt16] = []
        var start = 0
        while start < units.count {
            if start + needle.count <= units.count && units[start] == needle[0] && units[start..<start + needle.count].elementsEqual(needle) {
                output.append(contentsOf: with)
                start += needle.count
            } else {
                output.append(units[start])
                start += 1
            }
        }
        return String(decoding: output, as: UTF16.self)
    }

    private static func lookForStrings(_ document: PdfDocument, _ strings: [String], _ problems: inout [String]) {
        var found: [[UInt8]] = []
        var seen = Set<[UInt8]>()
        for s in strings {
            let units = Array(s.utf16)
            let forms: [[UInt8]] = [Latin1.bytes(s), Array(s.utf8), units.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }, units.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }]
            for form in forms where form.count >= 2 && seen.insert(form).inserted { found.append(form) }
        }
        search(document, Needles(found), &problems, 0)
    }

    private static func search(_ document: PdfDocument, _ needles: Needles, _ problems: inout [String], _ nested: Int) {
        var content = RedactionObjects.Identities()
        var painted = Set<Int>()
        for page in document.pages {
            for stream in RedactionResources.contents(document, page) { content.insert(stream) }
            let walk = RedactionWalk(document)
            // A page that cannot be followed may paint any of what it reaches.
            if walk.page(page) {
                if !walk.annotations(page) { RedactionObjects.painted(document, page.dictionary["Annots"], &painted, RedactionObjects.listing) }
                painted.formUnion(walk.used)
            } else {
                RedactionObjects.painted(document, page.dictionary, &painted, RedactionObjects.listing)
            }
        }

        // A page of an attached file is read as a viewer would, with its own fonts: the form-by-form reading below knows none of them.
        if nested > 0 {
            for page in document.pages {
                var unreadPage = false
                if speaks(document, { $0.run(page, $1) }, needles, &unreadPage) {
                    problems.append(RedactionText.stillInFile(RedactionText.pageOf(page.index)))
                } else if unreadPage {
                    problems.append(RedactionText.notChecked(RedactionText.pageOf(page.index)))
                }
            }
        }

        // Font programs and their code maps stay by design; a few letters of text turn up by chance in their binary data and boilerplate.
        var programs = RedactionObjects.Identities()
        var files = RedactionObjects.Identities()
        for number in document.objectNumbers {
            if let value = document.get(number) { collectPrograms(document, (value as? PdfStream)?.dictionary ?? value, &programs, &files, 0) }
        }

        for number in document.objectNumbers {
            guard let value = document.get(number) else { continue }
            let file = value as? PdfStream
            let attached = file.map { document.name($0.dictionary, "Type") == "EmbeddedFile" || files.contains($0) } ?? false
            let place = attached ? RedactionText.attachedFile(number) : L10n.t("object {0}|in a sentence", number)
            var unread = false
            var found = holds(document, (value as? PdfStream)?.dictionary ?? value, needles, 0)
            if !found, let stream = value as? PdfStream, !programs.contains(stream) {
                let isContent = content.contains(stream) || document.name(stream.dictionary, "Subtype") == "Form" || document.integer(stream.dictionary, "PatternType") == 1
                var data: [UInt8]
                do {
                    data = try document.data(stream, maxStream)
                } catch {
                    // A picture in an image codec is looked at as the codec's bytes. What else cannot be decoded, or is longer than is read, may hold the word in a form the raw bytes do not.
                    if let coded = inCodec(document, stream) {
                        data = coded
                    } else {
                        data = document.rawData(stream)
                        unread = true
                    }
                }
                // The element and attribute names of an XMP packet are the format's own, and character references hide a word from a search of the raw bytes, so a packet that reads as XML is searched by what it says.
                let packet = document.name(stream.dictionary, "Type") == "Metadata" || document.name(stream.dictionary, "Subtype") == "XML"
                // A form that nothing paints, or that is painted where the page scan does not look, is not checked against the page, so the text it shows is looked for here.
                let unseen = !content.contains(stream) && !painted.contains(number)
                if isContent {
                    let shows = unseen || nested > 0
                    found = holdsInOperands(document, data, needles, shows, &unread) || (shows && speaks(document, { $0.run(stream, $1) }, needles, &unread))
                } else if attached || container(data) {
                    found = holdsAttached(data, needles, nested, &unread)
                } else {
                    // Character references hide a word from a search of the raw bytes, so a packet that reads as XML is searched by what it says as well as by its bytes.
                    found = needles.contains(data)
                    if !found, packet, let text = RedactionMetadata.plainText(data) { found = needles.contains(Array(text.utf8)) }
                }
            }
            if found {
                problems.append(RedactionText.stillInFile(place))
            } else if unread {
                problems.append(RedactionText.notChecked(place))
            }
        }
    }

    // The text the form would show, as its fonts decode it: a word split over a TJ array or coded by a subset font does not
    // read as one string in the operands.
    private static func speaks(_ document: PdfDocument, _ run: (ContentInterpreter, ContentVisitor) -> Void, _ needles: Needles, _ unread: inout Bool) -> Bool {
        let spoken = Spoken()
        let interpreter = ContentInterpreter(document)
        run(interpreter, spoken)
        unread = unread || interpreter.isTruncated || spoken.units.count >= maxSpoken
        return needles.contains(Array(String(decoding: spoken.units, as: UTF16.self).utf8))
    }

    private final class Spoken: ContentVisitor {
        var units: [UInt16] = []

        override func showGlyph(_ context: ContentContext, _ glyph: GlyphInfo) {
            if units.count < PdfRedactor.maxSpoken, let text = glyph.unicode { units.append(contentsOf: text.utf16) }
        }
    }
    // An attachment can wrap the original in a container the byte search cannot see into. It counts as checked only when
    // everything in it is read: text is searched as it is, a zip or gzip file is read whole and strictly by RedactionArchive,
    // wherever the zip starts, and a PDF is read in every revision. Compressed data, a format not opened here and a file that is
    // not plain text are not known to be clean, whatever their size, and nor is a container deeper than is followed.
    private static func holdsAttached(_ data: [UInt8], _ needles: Needles, _ nested: Int, _ unread: inout Bool) -> Bool {
        if needles.contains(data) { return true }
        let zip = RedactionArchive.hasZipSignature(data)
        let gzip = data.hasPattern([0x1F, 0x8B], at: 0)
        let pdf = !zip && Array(data.prefix(1024)).indexOf(pdfMark) != nil
        if nested >= maxNested {
            unread = unread || !plain(data)
            return false
        }
        if zip || gzip {
            let entries: [[UInt8]]?
            if zip {
                entries = RedactionArchive.unzip(data, maxStream)
            } else {
                entries = RedactionArchive.gunzip(data, maxStream).map { [$0] }
            }
            guard let entries else {
                unread = true
                return false
            }
            for entry in entries where holdsAttached(entry, needles, nested + 1, &unread) { return true }
            return false
        }
        if pdf { return holdsRevisions(data, needles, nested, &unread) }
        unread = unread || !plain(data)
        return false
    }

    // The newest revision of a PDF is what a reader opens; the ones before it are in the same bytes, and a file cut after an
    // earlier end-of-file marker is a PDF that shows what the later ones took out. Each is read, and one that does not read counts as unread.
    private static func holdsRevisions(_ data: [UInt8], _ needles: Needles, _ nested: Int, _ unread: inout Bool) -> Bool {
        var ends: [Int] = []
        var from = 0
        while let at = data.indexOf(eofMark, from: from) {
            var end = at + 5
            while end < data.count && (data[end] == 10 || data[end] == 13) { end += 1 }
            if end < data.count { ends.append(end) }
            from = at + 5
        }
        if ends.count > maxRevisions {
            unread = true
            ends.removeLast(ends.count - maxRevisions)
        }
        for part in ends.map({ Array(data[..<$0]) }) + [data] {
            do {
                var problems: [String] = []
                let inner = try PdfDocument.open(part)
                search(inner, needles, &problems, nested + 1)
                if !problems.isEmpty { return true }
            } catch {
                unread = true
            }
        }
        return false
    }

    private static let maxRevisions = 8
    private static let eofMark = Array("%%EOF".utf8)

    // Formats that are packed and not opened here, whatever stream holds them.
    private static let unopened: [[UInt8]] = [
        [0x42, 0x5A, 0x68], [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0], [0x37, 0x7A, 0xBC, 0xAF], [0x52, 0x61, 0x72, 0x21], [0x28, 0xB5, 0x2F, 0xFD], [0x04, 0x22, 0x4D, 0x18], [0x1F, 0x9D], [0x4C, 0x5A, 0x49, 0x50],
        [0x4D, 0x53, 0x43, 0x46],
    ]

    // Whether the data is something holdsAttached opens or knows it cannot, wherever it is held.
    private static func container(_ data: [UInt8]) -> Bool {
        RedactionArchive.hasZipSignature(data) || data.hasPattern([0x1F, 0x8B], at: 0) || unopened.contains(where: { data.hasPattern($0, at: 0) })
            || Array(data.prefix(1024)).indexOf(pdfMark) != nil
    }

    private static let pdfMark = Array("%PDF-".utf8)

    // Text a reader sees as it is: no byte that a text file does not hold. Compressed and encrypted data has such bytes in the first few dozen.
    private static func plain(_ data: [UInt8]) -> Bool {
        !data.contains { $0 < 9 || $0 == 11 || ($0 > 13 && $0 < 32) || $0 == 127 }
    }

    private static func inCodec(_ document: PdfDocument, _ stream: PdfStream) -> [UInt8]? {
        do {
            let (filter, parameters, _) = document.decodeSpec(stream)
            let decoded = try PdfFilters.decodeToCodec(document.rawData(stream), filter, parameters, maxStream)
            return decoded.codec != nil ? decoded.data : nil
        } catch {
            return nil
        }
    }

    // Looks up every position of the data by its first two bytes, so that many strings cost no more than a few.
    private final class Needles {
        private var starts = [Bool](repeating: false, count: 1 << 16)
        private var byStart: [Int: [[UInt8]]] = [:]

        init(_ strings: [[UInt8]]) {
            for n in strings where n.count >= 2 {
                let key = Int(n[0]) << 8 | Int(n[1])
                starts[key] = true
                byStart[key, default: []].append(n)
            }
        }

        func contains(_ data: [UInt8]) -> Bool {
            var i = 0
            while i + 1 < data.count {
                let key = Int(data[i]) << 8 | Int(data[i + 1])
                if starts[key], let candidates = byStart[key] {
                    for n in candidates where data.hasPattern(n, at: i) { return true }
                }
                i += 1
            }
            return false
        }
    }

    // Strings inside objects: as the bytes they are, and as the text they stand for.
    // Descriptors can be direct dictionaries inside a font.
    // Attached files are named by /EF whether or not their stream says what it is.
    private static func collectPrograms(_ document: PdfDocument, _ value: PdfObject, _ programs: inout RedactionObjects.Identities,
                                        _ files: inout RedactionObjects.Identities, _ depth: Int) {
        if depth > 8 { return }
        switch value {
        case let dictionary as PdfDictionary:
            let font = isFont(document, dictionary)
            for (key, item) in dictionary.entries {
                if font && (key == "FontFile" || key == "FontFile2" || key == "FontFile3" || key == "ToUnicode"), let program = document.resolve(item) as? PdfStream {
                    programs.insert(program)
                } else if key == "EF", let held = document.resolve(item) as? PdfDictionary {
                    for (_, file) in held.entries {
                        if let attached = document.resolve(file) as? PdfStream { files.insert(attached) }
                    }
                } else {
                    collectPrograms(document, item, &programs, &files, depth + 1)
                }
            }
        case let array as PdfArray:
            for item in array.items { collectPrograms(document, item, &programs, &files, depth + 1) }
        default:
            break
        }
    }

    // The keys of a font hold programs and a character set that are exempt; the same keys anywhere else are data like any other.
    private static func isFont(_ document: PdfDocument, _ dictionary: PdfDictionary) -> Bool {
        let type = document.name(dictionary, "Type"), subtype = document.name(dictionary, "Subtype")
        return type == "Font" || type == "FontDescriptor" || ["Type1", "MMType1", "TrueType", "Type3", "Type0", "CIDFontType0", "CIDFontType2"].contains(subtype ?? "")
    }

    private static func holds(_ document: PdfDocument, _ value: PdfObject, _ needles: Needles, _ depth: Int) -> Bool {
        if depth > RedactionMetadata.objectDepth { return false }
        switch value {
        case let s as PdfString:
            if needles.contains(s.bytes) { return true }
            let text = PdfText.decode(s.bytes)
            return needles.contains(Array(text.utf16).flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }) || needles.contains(Array(text.utf8))
        case let n as PdfName:
            return spelled(n.value, needles)
        case let a as PdfArray:
            return a.items.contains { holds(document, $0, needles, depth + 1) }
        case let d as PdfDictionary:
            return d.entries.contains { e in
                !(e.key == "CharSet" && isFont(document, d)) && (spelled(e.key, needles) || (!RedactionMetadata.isFontName(e.key, e.value) && holds(document, e.value, needles, depth + 1)))
            }
        default:
            return false
        }
    }

    // Names that hold words, such as the keys of the old-style destinations, as opposed to the names the format defines.
    private static func spelled(_ name: String, _ needles: Needles) -> Bool {
        RedactionMetadata.isFreeText(name) && needles.contains(Array(RedactionMetadata.nameText(name).utf8))
    }

    // The text shown by the page is checked on the page; what a content stream says besides it
    // (marked content properties, the names of a description) is checked here.
    private static func holdsInOperands(_ document: PdfDocument, _ data: [UInt8], _ needles: Needles, _ shows: Bool, _ unread: inout Bool) -> Bool {
        for op in ContentParser.parse(data) {
            if !shows && (op.operator == "Tj" || op.operator == "TJ" || op.operator == "'" || op.operator == "\"") { continue }
            if op.operands.contains(where: { holds(document, $0, needles, 0) }) { return true }
        }
        return false
    }
}
