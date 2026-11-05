import Foundation

// Twin of windows/LazyPDF.Core/Forms/FormScripts.cs: finding the scripts of a form (ISO 32000-1 12.6, 12.7.5.3).

/// A script found in the form. `event` is the /AA key of ISO 32000-1 12.6.3 and 12.7.5.3 (K keystroke, F format, V
/// validate, C calculate, E X D U Fo Bl for the mouse and focus), "A" for a widget's own action, "OpenAction", or "Names/"
/// and the script's name for the document's scripts. `field` is the full name of the field, nil for a script of the
/// document; `builtIn` says the text is only calls of the AF functions, which this layer implements.
public struct FormScript: Equatable {
    public let field: String?
    public let event: String
    public let source: String
    public let builtIn: Bool

    public init(_ field: String?, _ event: String, _ source: String, _ builtIn: Bool) {
        self.field = field
        self.event = event
        self.source = source
        self.builtIn = builtIn
    }

    /// The script is applied by this layer: built-in, and an event that changes a value (K, F, V or C). Other JavaScript is
    /// listed and never run.
    public var ran: Bool { builtIn && (event == "K" || event == "F" || event == "V" || event == "C") }
}

/// What `PdfForm.recalculate` did: fields whose value changed and the calculations it could not run.
public struct FormCalculation {
    public let changed: Int
    public let notRun: [FormScript]

    public init(_ changed: Int, _ notRun: [FormScript]) {
        self.changed = changed
        self.notRun = notRun
    }
}

public enum FormScripts {
    private static let maxScripts = 10_000

    /// Every script of the document and of its fields and widgets, up to 10000.
    public static func list(_ form: PdfForm) -> [FormScript] {
        let document = form.document
        var list: [FormScript] = []
        let all = PdfActions.readDocument(document)
        for script in all.scripts { add(&list, nil, "Names/" + script.name, script.script) }
        if let open = all.openAction { addAction(&list, nil, "OpenAction", open) }
        for trigger in all.triggers { addAction(&list, nil, trigger.event, trigger.action) }

        var seen = Set<ObjectIdentifier>()
        for field in form.fields {
            for d in [field.dictionary] + field.widgets.map({ $0.dictionary }) {
                if list.count >= maxScripts { return list }
                if !seen.insert(ObjectIdentifier(d)).inserted { continue }
                for trigger in PdfActions.triggers(document, d) { addAction(&list, field.name, trigger.event, trigger.action) }
                if d["A"] != nil, let action = PdfActions.read(document, d["A"]) { addAction(&list, field.name, "A", action) }
            }
        }
        return list
    }

    /// The script of one event of a field: the field's own /AA first, then those of its widgets.
    static func sourceOf(_ form: PdfForm, _ field: FormField, _ evt: String) -> String? {
        for d in [field.dictionary] + field.widgets.map({ $0.dictionary }) {
            for trigger in PdfActions.triggers(form.document, d) where trigger.event == evt {
                if let script = scripts(trigger.action).first { return script }
            }
        }
        return nil
    }

    /// The built-in calls of an event, nil when it has no script or one that is not only built-in calls.
    static func callsOf(_ form: PdfForm, _ field: FormField, _ evt: String) -> [FormCall]? {
        guard let source = sourceOf(form, field, evt) else { return nil }
        return FormScriptParser.parse(source)
    }

    private static func addAction(_ list: inout [FormScript], _ field: String?, _ evt: String, _ action: PdfAction) {
        for source in scripts(action) { add(&list, field, evt, source) }
    }

    private static func add(_ list: inout [FormScript], _ field: String?, _ evt: String, _ source: String) {
        if list.count < maxScripts { list.append(FormScript(field, evt, source, FormScriptParser.parse(source) != nil)) }
    }

    // The action's script and those of its /Next chain, in order. The chain is a tree the reader already bounded.
    private static func scripts(_ action: PdfAction) -> [String] {
        var result: [String] = []
        if let js = action as? JavaScriptAction { result.append(js.script) }
        for next in action.next { result.append(contentsOf: scripts(next)) }
        return result
    }
}
