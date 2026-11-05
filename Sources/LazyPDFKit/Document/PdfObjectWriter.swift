import Foundation

// Twin of windows/LazyPDF.Core/Document/PdfObjectWriter.cs, after Lazy Scan's PdfObjectWriter.cs: the header,
// numbered objects and streams go into a buffer and the offsets are the caller's to collect. Objects come as
// PdfObject values, and strings and stream data are encrypted on their way out when the file is.
//
// The C# writes to a Stream the caller owns; here the writer holds the bytes (`output`) and the caller takes them.

/// Writes objects as bytes. `position` is the offset of the first byte this writer adds (an update starts after
/// the original). With a `security` the strings and streams of every object are encrypted unless the caller says
/// that object is not (the /Encrypt dictionary).
final class PdfObjectWriter {
    // Text is gathered here and written as Latin-1 once it passes this size, so that an object with a huge
    // array never exists as one string.
    private static let flushAt = 8192

    private let security: PdfSecurity?
    private var text = ""

    private(set) var output: [UInt8] = []

    /// The offset the next byte lands at.
    private(set) var position: Int

    init(position: Int = 0, security: PdfSecurity? = nil) {
        self.position = position
        self.security = security
    }

    /// "%PDF-version" and the comment of four high bytes that tells transfer programs the file is binary.
    func writeHeader(_ version: String) {
        text.append("%PDF-")
        text.append(version)
        text.append("\n")
        flush()
        writeBytes([UInt8(ascii: "%"), 0xE2, 0xE3, 0xCF, 0xD3, UInt8(ascii: "\n")])
    }

    /// A non-stream object; returns the offset it starts at.
    @discardableResult
    func writeObject(_ number: Int, _ generation: Int, _ value: PdfObject, encrypt: Bool = true) -> Int {
        let at = begin(number, generation)
        writeValue(value, number, generation, encrypt && security != nil)
        text.append("\nendobj\n")
        flush()
        return at
    }

    /// A stream object. `stored` is the data as it is to be stored, filters applied and not encrypted; /Length is
    /// written from what is stored. The cipher is chosen from `cryptView`, the dictionary with /Filter and
    /// /DecodeParms resolved, when given.
    @discardableResult
    func writeStream(_ number: Int, _ generation: Int, _ dictionary: PdfDictionary, _ stored: [UInt8], encrypt: Bool = true, cryptView: PdfDictionary? = nil) -> Int {
        var encrypt = encrypt
        var data = stored
        if encrypt, let security {
            data = security.encryptStream(number, generation, stored, cryptView ?? dictionary)
        } else {
            encrypt = false
        }
        let at = begin(number, generation)
        writeDictionary(dictionary, data.count, number, generation, encrypt)
        text.append("\nstream\n")
        flush()
        writeBytes(data)
        text.append("\nendstream\nendobj\n")
        flush()
        return at
    }

    /// A value outside any object (the trailer's); nothing in it is encrypted.
    func writeDirect(_ value: PdfObject) {
        writeValue(value, 0, 0, false)
        flush()
    }

    func writeAscii(_ string: String) {
        text.append(string)
        flush()
    }

    func writeBytes(_ bytes: [UInt8]) {
        output.append(contentsOf: bytes)
        position += bytes.count
    }

    private func begin(_ number: Int, _ generation: Int) -> Int {
        let at = position
        text.append("\(number) \(generation) obj\n")
        return at
    }

    private func writeValue(_ value: PdfObject, _ number: Int, _ generation: Int, _ encrypt: Bool) {
        if let string = value as? PdfString, encrypt, let security {
            PdfString(bytes: security.encryptString(number, generation, string.bytes), isHex: true).writeTo(&text)
        } else if let array = value as? PdfArray {
            text.append("[")
            for (i, item) in array.items.enumerated() {
                if i > 0 { text.append(" ") }
                writeValue(item, number, generation, encrypt)
            }
            text.append("]")
        } else if let dictionary = value as? PdfDictionary {
            writeDictionary(dictionary, nil, number, generation, encrypt)
        } else {
            value.writeTo(&text)
        }
        if text.utf8.count > Self.flushAt { flush() }
    }

    /// A dictionary; with `length` it is a stream's, whose /Length is replaced by that number.
    private func writeDictionary(_ dictionary: PdfDictionary, _ length: Int?, _ number: Int, _ generation: Int, _ encrypt: Bool) {
        // A signature's contents are the signature, not text (ISO 32000-1 7.6.1).
        let signature = PdfDocument.isSignature(dictionary)
        text.append("<<")
        var first = true
        for (key, item) in dictionary.entries {
            // Of repeated keys only the last one counts, as the reader has it.
            if dictionary[key] !== item || (length != nil && key == "Length") { continue }
            if !first { text.append(" ") }
            first = false
            PdfName(key).writeTo(&text)
            text.append(" ")
            writeValue(item, number, generation, encrypt && !(signature && key == "Contents"))
        }
        if let length { text.append("\(first ? "" : " ")/Length \(length)") }
        text.append(">>")
    }

    private func flush() {
        writeBytes(Latin1.bytes(text))
        text.removeAll(keepingCapacity: true)
    }
}
