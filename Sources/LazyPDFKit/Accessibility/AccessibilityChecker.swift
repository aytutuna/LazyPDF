import Foundation

// Twin of windows/LazyPDF.Core/Accessibility/AccessibilityChecker.cs: the Acrobat accessibility check list and the rules of
// ISO 14289-1 (PDF/UA-1) that a program can decide. Colour contrast and whether alt text says the right thing are left to a
// person. Nothing here changes the document except `fix`.
//
// The C# class is partial; the parts are extensions in this folder, so what they share is internal. The C# CancellationToken
// is the task's (`CancellationError`). The one Regex, the language tag, is matched by hand; `$` also stands before a final
// line feed, as in .NET. `fix` throws `ArgumentException` for a title or tag the user typed.

public enum AccessibilityChecker {
    private static let longDocument = 20
    static let maxLocations = 50

    final class Found {
        private(set) var count = 0
        private(set) var `where`: [AccessibilityPlace] = []

        func add(_ pageIndex: Int, _ element: PdfReference?) {
            count += 1
            if `where`.count < AccessibilityChecker.maxLocations { `where`.append(AccessibilityPlace(pageIndex, element)) }
        }
    }

    // ^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$
    static func isLanguageTag(_ text: String) -> Bool {
        var units = Array(text.utf16)
        if units.last == 0x0A { units.removeLast() }
        let parts = units.split(separator: 0x2D, omittingEmptySubsequences: false)
        guard let first = parts.first, first.count >= 2, first.count <= 3, first.allSatisfy({ isAsciiLetter($0) }) else { return false }
        return parts.dropFirst().allSatisfy { $0.count >= 2 && $0.count <= 8 && $0.allSatisfy { isAsciiLetter($0) || isAsciiDigit($0) } }
    }

    private static func isAsciiLetter(_ unit: UInt16) -> Bool {
        (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A)
    }

    private static func isAsciiDigit(_ unit: UInt16) -> Bool {
        unit >= 0x30 && unit <= 0x39
    }

    public static func check(_ document: PdfDocument) throws -> AccessibilityReport {
        let tree = StructureTree.read(document)
        let content = try readContent(document, tree)
        var items = [
            tagged(document, tree),
            title(document),
            language(document),
            security(document),
            bookmarks(document),
            content.searchable,
            content.encoding,
            content.taggedContent,
            tabOrder(document),
            AccessibilityItem(.contrast, AccessibilityText.name(.contrast), .needsPerson, AccessibilityText.contrastNeedsPerson, [], .none),
        ]
        items.append(contentsOf: checkStructure(document, tree))
        return AccessibilityReport(items)
    }

    static func pass(_ rule: AccessibilityRule) -> AccessibilityItem {
        AccessibilityItem(rule, AccessibilityText.name(rule), .passed, AccessibilityText.passed(rule), [], .none)
    }

    static func fail(_ rule: AccessibilityRule, _ found: Found, fix: AccessibilityFix = .none) -> AccessibilityItem {
        let message = AccessibilityText.failed(rule)
            .replacingOccurrences(of: "{0}", with: String(found.count))
            .replacingOccurrences(of: "{1}", with: AccessibilityText.where(found.where.first?.pageIndex ?? -1))
        return AccessibilityItem(rule, AccessibilityText.name(rule), .failed, message, found.where, fix)
    }

    static func fail(_ rule: AccessibilityRule, _ message: String? = nil, fix: AccessibilityFix = .none) -> AccessibilityItem {
        AccessibilityItem(rule, AccessibilityText.name(rule), .failed, message ?? AccessibilityText.failed(rule), [], fix)
    }

    static func noTags(_ rule: AccessibilityRule) -> AccessibilityItem {
        AccessibilityItem(rule, AccessibilityText.name(rule), .needsPerson, AccessibilityText.noTags, [], .none)
    }

    private static func tagged(_ document: PdfDocument, _ tree: StructureTree?) -> AccessibilityItem {
        if document.bool(document.dict(document.catalog, "MarkInfo"), "Suspects") == true { return fail(.tagged, AccessibilityText.suspectTags) }
        return document.isTagged && !(tree?.roots.isEmpty ?? true) ? pass(.tagged) : fail(.tagged)
    }

    private static func title(_ document: PdfDocument) -> AccessibilityItem {
        if DotNetText.isNullOrWhiteSpace(DocumentMetadata.read(document).title) { return fail(.title, fix: .setTitle) }
        if !ViewerSettings.read(document).displayDocTitle { return fail(.title, AccessibilityText.titleNotShown, fix: .showTitle) }
        return pass(.title)
    }

    private static func language(_ document: PdfDocument) -> AccessibilityItem {
        if let language = PdfText.read(document, document.catalog, "Lang"), isLanguageTag(language) { return pass(.language) }
        return fail(.language, fix: .setLanguage)
    }

    // 7.16 of ISO 14289-1: the extraction-for-accessibility permission must not be withheld.
    private static func security(_ document: PdfDocument) -> AccessibilityItem {
        if let security = document.security, !security.permissions.contains(.extractForAccessibility) { return fail(.security) }
        return pass(.security)
    }

    private static func bookmarks(_ document: PdfDocument) -> AccessibilityItem {
        document.pages.count > longDocument && Outline.read(document).items.isEmpty ? fail(.bookmarks) : pass(.bookmarks)
    }

    // 7.18.3: pages with annotations take their tab order from the structure.
    private static func tabOrder(_ document: PdfDocument) -> AccessibilityItem {
        let found = Found()
        for page in document.pages {
            if let annots = document.array(page.dictionary, "Annots"), !annots.items.isEmpty,
               document.name(page.dictionary, "Tabs") != "S" {
                found.add(page.index, page.reference)
            }
        }
        return found.count == 0 ? pass(.tabOrder) : fail(.tabOrder, found, fix: .setTabOrder)
    }
}
