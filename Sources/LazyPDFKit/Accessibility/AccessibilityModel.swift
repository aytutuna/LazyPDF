import Foundation

// Twin of windows/LazyPDF.Core/Accessibility/AccessibilityModel.cs: what the accessibility check reports.

public enum AccessibilityStatus {
    case passed
    case failed
    case needsPerson
}

/// The checks, in the order of the Acrobat list; the ISO 14289-1 rule each one covers is in `AccessibilityChecker`.
public enum AccessibilityRule: CaseIterable {
    case tagged
    case title
    case language
    case security
    case bookmarks
    case searchable
    case encoding
    case taggedContent
    case tabOrder
    case contrast
    case figureAlt
    case tableStructure
    case tableHeaders
    case listStructure
    case headingOrder
    case roleMap
    case links
    case formNames
    case formTagged
}

/// A repair `AccessibilityChecker.fix` can make.
public enum AccessibilityFix {
    case none

    /// Needs the title as the value.
    case setTitle

    /// The file has a title; make the window show it.
    case showTitle

    /// Needs a BCP 47 tag as the value.
    case setLanguage

    /// /Tabs /S on every page with annotations.
    case setTabOrder
}

/// `pageIndex` is from 0, -1 when the place is not on a page. `element` is the structure element at fault, when there is
/// one; the object of the annotation or field otherwise.
public struct AccessibilityPlace {
    public let pageIndex: Int
    public let element: PdfReference?

    public init(_ pageIndex: Int, _ element: PdfReference?) {
        self.pageIndex = pageIndex
        self.element = element
    }
}

/// `message` is one or two plain sentences: what is wrong and what to do. `where` is up to 50 places; the message counts
/// all of them.
public struct AccessibilityItem {
    public let rule: AccessibilityRule
    public let name: String
    public let status: AccessibilityStatus
    public let message: String
    public let `where`: [AccessibilityPlace]
    public let fix: AccessibilityFix

    public init(_ rule: AccessibilityRule, _ name: String, _ status: AccessibilityStatus, _ message: String,
                _ places: [AccessibilityPlace], _ fix: AccessibilityFix) {
        self.rule = rule
        self.name = name
        self.status = status
        self.message = message
        self.where = places
        self.fix = fix
    }
}

public struct AccessibilityReport {
    public let items: [AccessibilityItem]

    public init(_ items: [AccessibilityItem]) {
        self.items = items
    }

    public var passed: Int { items.filter { $0.status == .passed }.count }
    public var failed: Int { items.filter { $0.status == .failed }.count }
    public var needsPerson: Int { items.filter { $0.status == .needsPerson }.count }

    public subscript(rule: AccessibilityRule) -> AccessibilityItem {
        guard let item = items.first(where: { $0.rule == rule }) else {
            preconditionFailure("The report has no item for \(rule).")
        }
        return item
    }
}
