#if canImport(SwiftUI)
import SwiftUI
import XCTest
import LazyPDFApp
@testable import LazyPDFUI
#if canImport(AppKit)
import AppKit
#endif

// The window shows one sheet at a time: which one, and who keeps the keyboard for undo.

final class ModalTests: XCTestCase {
    func test_theWindowHasNoSheetByDefault() {
        XCTAssertNil(Modal.current(passwordAsked: false, local: nil, compact: false, toolOpen: true, panelOpen: true))
    }

    func test_aPasswordQuestionComesBeforeSettings() {
        XCTAssertEqual(Modal.current(passwordAsked: true, local: .settings, compact: false, toolOpen: false, panelOpen: false), .password)
    }

    func test_aPasswordQuestionComesBeforeTheToolSheetOfThePhone() {
        XCTAssertEqual(Modal.current(passwordAsked: true, local: nil, compact: true, toolOpen: true, panelOpen: false), .password)
    }

    func test_settingsComeBeforeTheToolAndPanelSheets() {
        XCTAssertEqual(Modal.current(passwordAsked: false, local: .about, compact: true, toolOpen: true, panelOpen: true), .about)
    }

    func test_aToolIsASheetOnThePhoneOnly() {
        XCTAssertEqual(Modal.current(passwordAsked: false, local: nil, compact: true, toolOpen: true, panelOpen: true), .tool)
        XCTAssertNil(Modal.current(passwordAsked: false, local: nil, compact: false, toolOpen: true, panelOpen: false))
    }

    func test_aPanelIsASheetOnThePhoneOnly() {
        XCTAssertEqual(Modal.current(passwordAsked: false, local: nil, compact: true, toolOpen: false, panelOpen: true), .panel)
        XCTAssertNil(Modal.current(passwordAsked: false, local: nil, compact: false, toolOpen: false, panelOpen: true))
    }
}

#if canImport(AppKit)
@MainActor
final class EditFocusTests: XCTestCase {
    private func window(holding first: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 50, height: 20))
        first.frame = NSRect(x: 0, y: 40, width: 150, height: 40)
        window.contentView?.addSubview(button)
        window.contentView?.addSubview(first)
        return window
    }

    func test_aTextViewWithTheKeyboardKeepsUndo() {
        let text = NSTextView()
        let window = window(holding: text)

        XCTAssertTrue(window.makeFirstResponder(text))

        XCTAssertTrue(EditFocus.text(in: window) === text)
    }

    func test_aReadOnlyTextKeepsNothing() {
        let text = NSTextView()
        text.isEditable = false
        let window = window(holding: text)

        XCTAssertTrue(window.makeFirstResponder(text))

        XCTAssertNil(EditFocus.text(in: window))
    }

    func test_theDocumentGetsUndoWhenNoTextHasTheKeyboard() {
        let text = NSTextView()
        let window = window(holding: text)

        XCTAssertTrue(window.makeFirstResponder(nil))

        XCTAssertNil(EditFocus.text(in: window))
        XCTAssertNil(EditFocus.text(in: nil))
    }
}
#endif
#endif
