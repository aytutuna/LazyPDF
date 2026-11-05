import Foundation

// Twin of windows/LazyPDF.Core/Document/PdfDocument.Security.cs: strings are decrypted as their object loads
// (ISO 32000-1 7.6.2), except in object streams, which are encrypted as a whole, and in the /Encrypt dictionary
// itself.

extension PdfDocument {
    /// Opens the /Encrypt dictionary with the password. Everything loaded before it was read without the key,
    /// so it is dropped.
    func openSecurity() throws {
        security = nil
        encryptDictionary = nil
        encryptNumber = 0
        guard let entry = trailer["Encrypt"], !(entry is PdfNull) else { return }
        if let reference = entry as? PdfReference { encryptNumber = reference.number }
        guard let encrypt = flatten(entry, 3, streams: false) as? PdfDictionary else {
            throw PdfReadException.damaged("The /Encrypt entry is not a dictionary.")
        }
        encryptDictionary = encrypt
        securityId = id.first ?? []
        let publicKey = (encrypt["Filter"] as? PdfName)?.value == "Adobe.PubSec"
        if publicKey {
            #if canImport(Security)
            if let certificate { security = try PdfSecurity.openPublicKey(encrypt, certificate) }
            #endif
        } else {
            security = try PdfSecurity.open(encrypt, securityId, password)
        }
        if security == nil {
            throw publicKey
                ? PdfReadException(.certificateRequired, "The file is encrypted for recipients and the certificate does not open it.")
                : PdfReadException(.passwordRequired, "The file is encrypted and the password does not open it.")
        }
        objects.removeAll()
        objectStreams.removeAll()
    }

    /// Changing or removing the encryption of an open file is for whoever holds the owner's rights: the owner
    /// password for the standard handler, a recipient with bit 2 for the public-key one. A reader without them
    /// may still do it when the file restricts nothing, since there is then nothing to protect. Keeping the
    /// file's own handler is always allowed, and so is encrypting a file that has none.
    func requireEncryptionRights(_ target: PdfSecurity?) throws {
        if let current = security, !current.openedAsOwner, current.permissions != .all, target !== current {
            throw PdfPermissionException("The file restricts its permissions and was not opened with the rights to change its encryption.")
        }
    }

    /// The first /ID string a save has to keep: the older handlers make the file key from it, so it is the one
    /// the key was made with (an indirect /ID reads garbled once the file is decrypted). Nil when an
    /// unencrypted file has none.
    var firstId: [UInt8]? {
        security == nil ? id.first : securityId
    }

    func decryptStrings(_ value: PdfObject, _ number: Int, _ generation: Int) {
        guard let security else { return }
        switch value {
        case let text as PdfString:
            text.bytes = security.decryptString(number, generation, text.bytes)
        case let array as PdfArray:
            for item in array.items { decryptStrings(item, number, generation) }
        case let stream as PdfStream:
            decryptStrings(stream.dictionary, number, generation)
        case let dictionary as PdfDictionary:
            // A signature's contents are the signature, not text (7.6.1).
            let signature = Self.isSignature(dictionary)
            for (key, item) in dictionary.entries where !(signature && key == "Contents") {
                decryptStrings(item, number, generation)
            }
        default:
            break
        }
    }

    static func isSignature(_ dictionary: PdfDictionary) -> Bool {
        if let type = dictionary["Type"] as? PdfName, type.value == "Sig" || type.value == "DocTimeStamp" { return true }
        return dictionary.containsKey("ByteRange")
    }
}
