import Foundation

// Twin of windows/LazyPDF.Core/Crypt/PdfSecurity.cs: the standard security handler (ISO 32000-1 7.6, ISO 32000-2
// 7.6 for R 6): opens an /Encrypt dictionary with a password, decrypts and encrypts strings and streams, and makes
// the dictionary of a new file. Read: V 1 R 2 and V 2 R 3 (RC4), V 4 R 4 (crypt filters: RC4, AES-128, identity),
// V 5 R 5 and R 6 (AES-256). Written: R 4 and R 6. An instance holds the file key and no state that changes, so it
// can be shared between threads.
//
// MD5, SHA, AES and RC4 are the engine's own (Digests.swift, Aes.swift, Rc4.swift): the C# takes the first three
// from System.Security.Cryptography, and LazyPDFKit uses no Apple framework, so Linux builds it too. Only the
// public-key handler needs the system (PdfSecurityPublicKey.swift).

public final class PdfSecurity {
    enum Method { case identity, rc4, aes128, aes256 }

    private let key: [UInt8]
    private let strings: Method
    private let streams: Method
    private let embedded: Method
    private let filters: [String: Method]
    private let permissionBits: Int
    private let fill: (Int) -> [UInt8]

    init(dictionary: PdfDictionary, key: [UInt8], revision: Int, permissionBits: Int, openedAsOwner: Bool,
         encryptMetadata: Bool, strings: Method, streams: Method, filters: [String: Method],
         fill: @escaping (Int) -> [UInt8], embedded: Method? = nil, permsMismatch: Bool = false,
         isPublicKey: Bool = false) {
        self.dictionary = dictionary
        self.key = key
        self.revision = revision
        self.permissionBits = permissionBits
        self.openedAsOwner = openedAsOwner
        self.encryptMetadata = encryptMetadata
        self.strings = strings
        self.streams = streams
        self.embedded = embedded ?? streams
        self.filters = filters
        self.fill = fill
        self.permsMismatch = permsMismatch
        self.isPublicKey = isPublicKey
    }

    /// Whether the password was the owner's, so the permissions do not bind this reader.
    public let openedAsOwner: Bool

    /// What the file's /P allows. For a reader that opened as owner these are still the file's flags.
    public var permissions: PdfPermissions {
        PdfPermissions(rawValue: permissionBits & PdfPermissions.all.rawValue)
    }

    /// False when the document's metadata stream is stored in the clear (R 4 and later).
    public let encryptMetadata: Bool

    /// An R 6 file whose /Perms is missing or does not agree with /P and /EncryptMetadata under the
    /// file key: someone changed the permissions without the key. The file still opens; false for
    /// every other revision and for a new handler.
    public let permsMismatch: Bool

    /// Whether this is the public-key handler (`openPublicKey`, `createPublicKey`).
    public let isPublicKey: Bool

    /// The revision; for the public-key handler 4 for V 4 and 6 for V 5, so the version rules of a save treat both handlers alike.
    public let revision: Int

    /// The /Encrypt dictionary: the one given to `open`, or the new one. It is never encrypted itself.
    public let dictionary: PdfDictionary

    /// The handler for `encrypt` (fully resolved) and the first string of the trailer's /ID, or nil when
    /// `password` is neither the user's nor the owner's. A nil or empty password tries the empty user
    /// password. Throws `PdfReadException` for a handler or cipher that is not supported, or values
    /// missing from the dictionary.
    public static func open(_ encrypt: PdfDictionary, _ firstId: [UInt8], _ password: String?) throws -> PdfSecurity? {
        guard let filter = encrypt["Filter"] as? PdfName, filter.value == "Standard" else {
            throw PdfReadException(.unsupported, "The file uses a security handler other than the standard one.")
        }
        let v = number(encrypt, "V", 0), r = number(encrypt, "R", 0)
        let known = ((v == 1 || v == 2 || v == 4) && r >= 2 && r <= 4) || (v == 5 && (r == 5 || r == 6))
        if !known {
            throw PdfReadException(.unsupported, "The encryption version \(v) revision \(r) is not supported.")
        }

        let (strings, streams, filters) = try readFilters(encrypt, v)
        let modern = r >= 5
        let embedded = try checkCiphers(encrypt, v, modern, strings, streams, filters)

        let o = try bytes(encrypt, "O"), u = try bytes(encrypt, "U")
        let p = permissionValue(encrypt)
        let metadata = r < 4 || (encrypt["EncryptMetadata"] as? PdfBoolean)?.value != false
        let password = password ?? ""

        let key: [UInt8]?
        let owner: Bool
        if modern {
            let oe = try bytes(encrypt, "OE"), ue = try bytes(encrypt, "UE")
            if o.count < 48 || u.count < 48 || oe.count < 32 || ue.count < 32 {
                throw PdfReadException.damaged("The encryption dictionary has short password values.")
            }
            let opened = openModern(r, password, o, u, oe, ue)
            key = opened.key
            owner = opened.owner
        } else {
            if o.count < 32 || u.count < 32 {
                throw PdfReadException.damaged("The encryption dictionary has short password values.")
            }
            let length = r == 2 ? 5 : r == 4 ? 16 : min(max(number(encrypt, "Length", 40) / 8, 5), 16)
            let methods = Array(filters.values) + [strings, streams, embedded]
            if length != 16 && methods.contains(.aes128) {
                throw PdfReadException(.unsupported, "AES-128 needs a 128-bit key.")
            }
            let opened = openLegacy(PdfPasswords.legacy(password), o, u, p, firstId, r, length, metadata)
            key = opened.key
            owner = opened.owner
        }
        guard let key else { return nil }
        // R 6 only: the /Perms of R 5 files in the wild are not reliable.
        var matches = false
        if r == 6, let perms = encrypt["Perms"] as? PdfString {
            matches = PdfKeys.permsMatch(key, perms.bytes, p, metadata)
        }
        return PdfSecurity(dictionary: encrypt, key: key, revision: r, permissionBits: p, openedAsOwner: owner,
                           encryptMetadata: metadata, strings: strings, streams: streams, filters: filters,
                           fill: systemRandom, embedded: embedded, permsMismatch: r == 6 && !matches)
    }

    static func systemRandom(_ count: Int) -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8(truncatingIfNeeded: generator.next()) }
    }

    /// /P as the 32-bit value it is, whatever the number was written as. The long conversion saturates, as in .NET 9 and later.
    private static func permissionValue(_ encrypt: PdfDictionary) -> Int {
        guard let number = encrypt["P"] as? PdfNumber else { return 0 }
        let value = number.value
        let long: Int
        if value.isNaN {
            long = 0
        } else if value >= 9.2233720368547758e18 {
            long = Int.max
        } else if value <= -9.2233720368547758e18 {
            long = Int.min
        } else {
            long = Int(value)
        }
        return Int(Int32(truncatingIfNeeded: long))
    }

    /// The method of embedded files, after checking that every cipher in use belongs to the revision.
    static func checkCiphers(_ encrypt: PdfDictionary, _ v: Int, _ modern: Bool, _ strings: Method, _ streams: Method,
                             _ filters: [String: Method]) throws -> Method {
        var embedded = streams
        if v >= 4, let eff = encrypt["EFF"] as? PdfName { embedded = try named(eff, filters) }
        for method in Array(filters.values) + [strings, streams, embedded] {
            if method != .identity && (method == .aes256) != modern {
                throw PdfReadException(.unsupported, "The crypt filter does not match the encryption revision.")
            }
        }
        return embedded
    }

    private static func openLegacy(_ password: [UInt8], _ o: [UInt8], _ u: [UInt8], _ p: Int, _ id: [UInt8], _ r: Int,
                                   _ length: Int, _ metadata: Bool) -> (key: [UInt8]?, owner: Bool) {
        let hidden = PdfKeys.userPasswordFromOwner(password, o, r, length)
        var key = PdfKeys.fileKey(hidden, o, p, id, r, length, metadata)
        if PdfKeys.checkUser(key, u, id, r) { return (key, true) }
        key = PdfKeys.fileKey(PdfKeys.pad(password), o, p, id, r, length, metadata)
        return (PdfKeys.checkUser(key, u, id, r) ? key : nil, false)
    }

    private static func openModern(_ r: Int, _ password: String, _ o: [UInt8], _ u: [UInt8], _ oe: [UInt8],
                                   _ ue: [UInt8]) -> (key: [UInt8]?, owner: Bool) {
        // PDFKit hands on the decomposed form, so files made on a Mac can need it.
        let prepared = PdfPasswords.prepare(password), decomposed = PdfPasswords.decompose(password)
        var opened = PdfKeys.openFileKey(r, prepared, o, u, oe, ue)
        if opened.key == nil && decomposed != prepared {
            opened = PdfKeys.openFileKey(r, decomposed, o, u, oe, ue)
        }
        return (opened.key, opened.asOwner)
    }

    static func readFilters(_ encrypt: PdfDictionary, _ v: Int) throws -> (strings: Method, streams: Method, filters: [String: Method]) {
        var filters: [String: Method] = [:]
        if v < 4 { return (.rc4, .rc4, filters) }
        if let cf = encrypt["CF"] as? PdfDictionary {
            for (name, value) in cf.entries {
                if let filter = value as? PdfDictionary { filters[name] = try methodOf(filter["CFM"]) }
            }
        }
        return (try named(encrypt["StrF"], filters), try named(encrypt["StmF"], filters), filters)
    }

    private static func methodOf(_ cfm: PdfObject?) throws -> Method {
        switch (cfm as? PdfName)?.value {
        case nil, "None": return .identity
        case "V2": return .rc4
        case "AESV2": return .aes128
        case "AESV3": return .aes256
        case let other?: throw PdfReadException(.unsupported, "The crypt filter method \(other) is not supported.")
        }
    }

    private static func named(_ name: PdfObject?, _ filters: [String: Method]) throws -> Method {
        guard let named = name as? PdfName, named.value != "Identity" else { return .identity }
        guard let method = filters[named.value] else {
            throw PdfReadException.damaged("The crypt filter \(named.value) is not defined.")
        }
        return method
    }

    static func number(_ dictionary: PdfDictionary, _ key: String, _ fallback: Int) -> Int {
        guard let n = (dictionary[key] as? PdfNumber)?.integer else { return fallback }
        return min(max(n, Int(Int32.min)), Int(Int32.max))
    }

    private static func bytes(_ dictionary: PdfDictionary, _ key: String) throws -> [UInt8] {
        guard let text = dictionary[key] as? PdfString else {
            throw PdfReadException.damaged("The encryption dictionary has no /\(key) string.")
        }
        return text.bytes
    }

    /// A string of object `number` as stored, decrypted. Identity returns `data` itself.
    public func decryptString(_ number: Int, _ generation: Int, _ data: [UInt8]) -> [UInt8] {
        decrypt(strings, number, generation, data)
    }

    /// A stream of object `number` as stored, decrypted. A cross-reference stream is never encrypted, nor
    /// is a metadata stream when `encryptMetadata` is false, and a /Crypt filter naming Identity (or no
    /// filter name) leaves its stream alone. The dictionary's /Filter and /DecodeParms must be resolved.
    public func decryptStream(_ number: Int, _ generation: Int, _ data: [UInt8], _ streamDictionary: PdfDictionary) -> [UInt8] {
        decrypt(streamMethod(streamDictionary), number, generation, data)
    }

    /// The stored form of a string, with the key `decryptString` reads it with. AES gets a fresh random IV.
    public func encryptString(_ number: Int, _ generation: Int, _ data: [UInt8]) -> [UInt8] {
        encrypt(strings, number, generation, data)
    }

    /// The stored form of a stream, under the same rules as `decryptStream`.
    public func encryptStream(_ number: Int, _ generation: Int, _ data: [UInt8], _ streamDictionary: PdfDictionary) -> [UInt8] {
        encrypt(streamMethod(streamDictionary), number, generation, data)
    }

    private func streamMethod(_ stream: PdfDictionary) -> Method {
        if let type = stream["Type"] as? PdfName, type.value == "XRef" || (type.value == "Metadata" && !encryptMetadata) {
            return .identity
        }
        let index = Self.cryptFilterIndex(stream["Filter"])
        if index < 0 { return (stream["Type"] as? PdfName)?.value == "EmbeddedFile" ? embedded : streams }
        var parms = stream["DecodeParms"] ?? stream["DP"]
        if let array = parms as? PdfArray { parms = index < array.items.count ? array.items[index] : nil }
        let name = ((parms as? PdfDictionary)?["Name"] as? PdfName)?.value ?? "Identity"
        if name == "Identity" { return .identity }
        return filters[name] ?? streams
    }

    private static func cryptFilterIndex(_ filter: PdfObject?) -> Int {
        if let name = filter as? PdfName { return name.value == "Crypt" ? 0 : -1 }
        if let array = filter as? PdfArray {
            return array.items.firstIndex { ($0 as? PdfName)?.value == "Crypt" } ?? -1
        }
        return -1
    }

    private func decrypt(_ method: Method, _ number: Int, _ generation: Int, _ data: [UInt8]) -> [UInt8] {
        switch method {
        case .identity: return data
        case .rc4: return Rc4.apply(objectKey(number, generation, false), data)
        case .aes128: return aesDecrypt(objectKey(number, generation, true), data)
        case .aes256: return aesDecrypt(key, data)
        }
    }

    private func encrypt(_ method: Method, _ number: Int, _ generation: Int, _ data: [UInt8]) -> [UInt8] {
        switch method {
        case .identity: return data
        case .rc4: return Rc4.apply(objectKey(number, generation, false), data)
        case .aes128: return aesEncrypt(objectKey(number, generation, true), data)
        case .aes256: return aesEncrypt(key, data)
        }
    }

    /// Algorithm 1: the file key extended with the object and generation numbers, hashed (ISO 32000-1 7.6.2).
    private func objectKey(_ number: Int, _ generation: Int, _ aes: Bool) -> [UInt8] {
        var input = key
        input.append(UInt8(truncatingIfNeeded: number))
        input.append(UInt8(truncatingIfNeeded: number >> 8))
        input.append(UInt8(truncatingIfNeeded: number >> 16))
        input.append(UInt8(truncatingIfNeeded: generation))
        input.append(UInt8(truncatingIfNeeded: generation >> 8))
        if aes { input += Array("sAlT".utf8) }
        return Array(Md5.hash(input).prefix(min(key.count + 5, 16)))
    }

    // The IV is the first 16 bytes. A bad padding tail is kept rather than rejected, as the files in
    // the wild have them; a trailing partial block is dropped.
    private func aesDecrypt(_ key: [UInt8], _ data: [UInt8]) -> [UInt8] {
        let body = (data.count - 16) & ~15
        if body <= 0 { return [] }
        let plain = Aes(key: key).decryptCbc(Array(data[16..<16 + body]), iv: Array(data[0..<16]))
        return Aes.unpadded(plain) ?? plain
    }

    private func aesEncrypt(_ key: [UInt8], _ data: [UInt8]) -> [UInt8] {
        let iv = fill(16)
        return iv + Aes(key: key).encryptCbc(Aes.padded(data), iv: iv)
    }
}
