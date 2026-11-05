import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Structure/ActionTests.cs: the same cases, and one for an action read from a file
// that cannot be written.

final class ActionTests: XCTestCase {
    private func read(_ body: String, _ more: ((TestPdf) -> Void)? = nil) throws -> PdfAction? {
        let document = try StructureFixtures.file("", { pdf in
            pdf.obj(20, body)
            more?(pdf)
        })
        return PdfActions.read(document, PdfReference(20, 0))
    }

    func test_goToWithExplicitDestination() throws {
        let action = try XCTUnwrap(read("<</S /GoTo /D [4 0 R /XYZ 5 6 null]>>") as? GoToAction)
        XCTAssertEqual(action.destination, PdfDestination(1, .xyz, left: 5, top: 6))
    }

    func test_goToWithoutDestinationIsNull() throws {
        XCTAssertNil(try read("<</S /GoTo>>"))
    }

    func test_goToRemote() throws {
        let action = try XCTUnwrap(read("<</S /GoToR /F (other.pdf) /D [2 /Fit] /NewWindow true>>") as? GoToRemoteAction)
        XCTAssertEqual(action.file, "other.pdf")
        XCTAssertEqual(action.destination?.pageIndex, 2)
        XCTAssertEqual(action.newWindow, true)
    }

    func test_goToRemoteWithFileSpecAndNamedDestination() throws {
        let action = try XCTUnwrap(read("<</S /GoToR /F <</Type /Filespec /F (a.pdf) /UF (b.pdf)>> /D (chapter1)>>") as? GoToRemoteAction)
        XCTAssertEqual(action.file, "b.pdf")
        XCTAssertEqual(action.destination?.name, "chapter1")
    }

    func test_uriIsUtf8WithLatin1Fallback() throws {
        XCTAssertEqual(try XCTUnwrap(read("<</S /URI /URI (https://example.com/a?b=1)>>") as? UriAction).uri, "https://example.com/a?b=1")
        XCTAssertEqual(try XCTUnwrap(read("<</S /URI /URI <687474703A2F2F782FC3A9>>>") as? UriAction).uri, "http://x/\u{E9}")
        XCTAssertEqual(try XCTUnwrap(read("<</S /URI /URI <687474703A2F2F782FE9>>>") as? UriAction).uri, "http://x/\u{E9}")
    }

    func test_launchNamedAndJavaScript() throws {
        let launch = try XCTUnwrap(read("<</S /Launch /F (tool.exe)>>") as? LaunchAction)
        XCTAssertEqual(launch.file, "tool.exe")
        XCTAssertNil(launch.newWindow)
        XCTAssertEqual(try XCTUnwrap(read("<</S /Named /N /NextPage>>") as? NamedAction).name, "NextPage")
        XCTAssertEqual(try XCTUnwrap(read("<</S /JavaScript /JS (app.alert\\(1\\);)>>") as? JavaScriptAction).script, "app.alert(1);")
    }

    func test_javaScriptMayBeAStream() throws {
        let action = try read("<</S /JavaScript /JS 21 0 R>>", { pdf in pdf.stream(21, "", "this.print();") })
        XCTAssertEqual(try XCTUnwrap(action as? JavaScriptAction).script, "this.print();")
    }

    func test_formActionsListFieldNames() throws {
        let submit = try XCTUnwrap(read("<</S /SubmitForm /F <</FS /URL /F (http://x/post)>> /Flags 4 /Fields [(name) 22 0 R]>>",
                                        { pdf in pdf.obj(22, "<</FT /Tx /T (email)>>") }) as? SubmitFormAction)
        XCTAssertEqual(submit.url, "http://x/post")
        XCTAssertEqual(submit.flags, 4)
        XCTAssertEqual(submit.fields, ["name", "email"])
        let reset = try XCTUnwrap(read("<</S /ResetForm>>") as? ResetFormAction)
        XCTAssertTrue(reset.fields.isEmpty)
    }

    func test_unknownKindsAreOther() throws {
        for kind in ["Hide", "SetOCGState", "ImportData", "Rendition", "Whatever"] {
            XCTAssertEqual(try XCTUnwrap(read("<</S /\(kind)>>") as? OtherAction).type, kind)
        }
    }

    func test_nextChainsAreReadInOrder() throws {
        let action = try XCTUnwrap(read("<</S /Named /N /NextPage /Next [<</S /URI /URI (a)>> 21 0 R]>>",
                                        { pdf in pdf.obj(21, "<</S /JavaScript /JS (x) /Next <</S /Named /N /LastPage>>>>") }))
        XCTAssertEqual(action.next.count, 2)
        XCTAssertTrue(action.next[0] is UriAction)
        let js = try XCTUnwrap(action.next[1] as? JavaScriptAction)
        XCTAssertEqual(js.next.count, 1)
        XCTAssertEqual((js.next[0] as? NamedAction)?.name, "LastPage")
    }

    func test_chainThatLoopsStops() throws {
        let action = try XCTUnwrap(read("<</S /Named /N /A /Next 21 0 R>>", { pdf in pdf.obj(21, "<</S /Named /N /B /Next 20 0 R>>") }))
        XCTAssertEqual(action.next.count, 1)
        XCTAssertEqual((action.next[0] as? NamedAction)?.name, "B")
        XCTAssertTrue(action.next[0].next.isEmpty)
    }

    func test_longChainIsCapped() throws {
        let action = try read("<</S /Named /N /A /Next 21 0 R>>", { pdf in
            for i in 0..<500 { pdf.obj(21 + i, "<</S /Named /N /A\(i) /Next \(22 + i) 0 R>>") }
        })
        var depth = 0
        var at = action
        while let current = at, !current.next.isEmpty {
            depth += 1
            at = current.next[0]
        }
        XCTAssertTrue((1...70).contains(depth), "\(depth)")
    }

    func test_wideChainIsCapped() throws {
        let items = String(repeating: "<</S /Named /N /X>> ", count: 1000)
        let action = try XCTUnwrap(read("<</S /Named /N /A /Next [\(items)]>>"))
        XCTAssertTrue((1...64).contains(action.next.count), "\(action.next.count)")
    }

    private func named(_ name: String, _ next: [PdfAction]) -> NamedAction {
        let action = NamedAction(name)
        action.next = next
        return action
    }

    func test_writesAndReadsBack() throws {
        let document = try StructureFixtures.open()
        let actions: [PdfAction] = [
            GoToAction(PdfDestination(2, .fitH, top: 7)),
            GoToRemoteAction("o.pdf", PdfDestination(3), true),
            LaunchAction("x.exe", nil),
            UriAction("https://example.com/\u{E9}"),
            NamedAction("PrevPage"),
            JavaScriptAction("var s = \"\u{E9}\";"),
            SubmitFormAction("http://x", 4, ["a", "b"]),
            ResetFormAction(0, []),
            named("A", [UriAction("u"), named("B", [NamedAction("C")])]),
        ]
        for action in actions {
            let written = try PdfActions.toObject(document, action)
            let back = try XCTUnwrap(PdfActions.read(document, written))
            XCTAssertTrue(type(of: action) == type(of: back), "\(action)")
            XCTAssertEqual(describe(action), describe(back))
        }
    }

    // What a record compares: the values, and the chain of actions that follow.
    private func describe(_ action: PdfAction) -> String {
        let text: String
        switch action {
        case let a as GoToAction: text = "GoTo \(a.destination)"
        case let a as GoToRemoteAction: text = "GoToR \(a.file) \(String(describing: a.destination)) \(String(describing: a.newWindow))"
        case let a as LaunchAction: text = "Launch \(String(describing: a.file)) \(String(describing: a.newWindow))"
        case let a as UriAction: text = "Uri \(a.uri)"
        case let a as NamedAction: text = "Named \(a.name)"
        case let a as JavaScriptAction: text = "JavaScript \(a.script)"
        case let a as SubmitFormAction: text = "Submit \(a.url) \(a.flags) \(a.fields)"
        case let a as ResetFormAction: text = "Reset \(a.flags) \(a.fields)"
        case let a as OtherAction: text = "Other \(a.type)"
        default: text = "?"
        }
        return text + "[" + action.next.map { describe($0) }.joined(separator: ", ") + "]"
    }

    func test_documentActionsAreListed() throws {
        let document = try StructureFixtures.file(
            "/OpenAction 20 0 R /AA <</WC <</S /JavaScript /JS (close\\(\\))>> /DS <</S /Named /N /Print>>>> /Names <</JavaScript <</Names [(init) 21 0 R (zeta) 22 0 R]>>>>",
            { pdf in
                pdf.obj(20, "<</S /GoTo /D [3 0 R /Fit]>>")
                pdf.obj(21, "<</S /JavaScript /JS (var a = 1;)>>")
                pdf.obj(22, "<</S /JavaScript /JS (var b = 2;)>>")
            })
        let all = PdfActions.readDocument(document)
        XCTAssertEqual((all.openAction as? GoToAction)?.destination.pageIndex, 0)
        XCTAssertEqual(all.triggers.map { $0.event }, ["WC", "DS"])
        XCTAssertEqual(all.scripts.map { "\($0.name)=\($0.script)" }, ["init=var a = 1;", "zeta=var b = 2;"])
        XCTAssertTrue(PdfActions.hasJavaScript(document))
    }

    func test_openActionMayBeADestinationArray() throws {
        let document = try StructureFixtures.file("/OpenAction [5 0 R /Fit]")
        XCTAssertEqual((PdfActions.readDocument(document).openAction as? GoToAction)?.destination.pageIndex, 2)
        XCTAssertFalse(PdfActions.hasJavaScript(document))
    }

    func test_javaScriptIsFoundInPagesAndWidgets() throws {
        let plain = try StructureFixtures.file("")
        XCTAssertFalse(PdfActions.hasJavaScript(plain))

        let onPage = try StructureFixtures.file("", pageEntries: "/AA <</O <</S /JavaScript /JS (x)>>>>")
        XCTAssertTrue(PdfActions.hasJavaScript(onPage))

        let widget = try StructureFixtures.file("", { pdf in
            pdf.obj(20, "<</Type /Annot /Subtype /Widget /Rect [0 0 1 1] /AA <</K <</S /JavaScript /JS (y)>>>>>>")
        }, pageEntries: "/Annots [20 0 R]")
        XCTAssertTrue(PdfActions.hasJavaScript(widget))

        let inChain = try StructureFixtures.file("", { pdf in
            pdf.obj(20, "<</Type /Annot /Subtype /Link /Rect [0 0 1 1] /A <</S /Named /N /Print /Next <</S /JavaScript /JS (z)>>>>>>")
        }, pageEntries: "/Annots [20 0 R]")
        XCTAssertTrue(PdfActions.hasJavaScript(inChain))

        let links = try StructureFixtures.file("", { pdf in
            pdf.obj(20, "<</Type /Annot /Subtype /Link /Rect [0 0 1 1] /A <</S /URI /URI (http://x)>>>>")
        }, pageEntries: "/Annots [20 0 R]")
        XCTAssertFalse(PdfActions.hasJavaScript(links))
    }

    func test_triggersOfAnyDictionary() throws {
        let document = try StructureFixtures.file("", pageEntries: "/AA <</O <</S /Named /N /NextPage>> /C <</S /Named /N /PrevPage>>>>")
        let triggers = PdfActions.triggers(document, document.pages[0].dictionary)
        XCTAssertEqual(triggers.map { $0.event }, ["O", "C"])
        XCTAssertTrue(PdfActions.triggers(document, nil).isEmpty)
    }

    func test_otherActionsCannotBeWritten() throws {
        XCTAssertThrowsError(try PdfActions.toObject(StructureFixtures.open(), OtherAction("Hide"))) { XCTAssertTrue($0 is ArgumentException) }
    }

    func test_goToWithAPageThatIsGoneCannotBeWritten() throws {
        XCTAssertThrowsError(try PdfActions.toObject(StructureFixtures.open(), GoToAction(PdfDestination(40)))) { XCTAssertTrue($0 is ArgumentException) }
    }

    func test_anActionReadFromAFileThatCannotBeWrittenIsRefusedOnTheWay() throws {
        let document = try StructureFixtures.file("", { pdf in pdf.obj(20, "<</S /Hide /T (x) /Next <</S /GoTo /D [99 0 R /Fit]>>>>") })
        let action = try XCTUnwrap(PdfActions.read(document, PdfReference(20, 0)))
        XCTAssertThrowsError(try PdfActions.toObject(document, action)) { XCTAssertTrue($0 is ArgumentException) }
    }

    func test_scriptBehindALongChainIsFound() throws {
        let document = try StructureFixtures.file("/OpenAction 20 0 R", { pdf in
            for i in 0..<12 { pdf.obj(20 + i, "<</S /Named /N /NextPage /Next \(21 + i) 0 R>>") }
            pdf.obj(32, "<</S /JavaScript /JS (x)>>")
        })
        XCTAssertTrue(PdfActions.hasJavaScript(document))
    }

    func test_scriptBehindAnActionThatFailsToBuildIsFound() throws {
        for body in ["<</S /URI /URI 5 /Next <</S /JavaScript /JS (x)>>>>", "<</S /GoTo /Next <</S /JavaScript /JS (x)>>>>"] {
            let document = try StructureFixtures.file("/OpenAction 20 0 R", { pdf in pdf.obj(20, body) })
            XCTAssertTrue(PdfActions.hasJavaScript(document), body)
            let open = try XCTUnwrap(PdfActions.readDocument(document).openAction as? OtherAction, body)
            XCTAssertEqual(open.next.count, 1, body)
        }
    }
}
