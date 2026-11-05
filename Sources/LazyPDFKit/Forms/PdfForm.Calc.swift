import Foundation

// Twin of windows/LazyPDF.Core/Forms/PdfForm.Calc.cs: the calculation order, validation and the text a field shows.

extension PdfForm {
    private static let maxCalculations = 10_000

    public var scripts: [FormScript] { FormScripts.list(self) }

    /// The fields of /AcroForm /CO, the order calculations run in (ISO 32000-1 12.7.2).
    public var calculationOrder: [FormField] {
        var order: [FormField] = []
        guard let co = document.array(acroForm, "CO") else { return order }
        for item in co.items.prefix(Self.maxCalculations) {
            if let d = document.resolve(item) as? PdfDictionary, let listed = current(d) { order.append(listed) }
        }
        return order
    }

    /// Runs the calculation order. Only the AFSimple_Calculate calls run (sum, average, product, minimum, maximum of named
    /// fields); any other script is returned in `FormCalculation.notRun` and its field keeps its value.
    @discardableResult
    public func recalculate() throws -> FormCalculation {
        try requireFillable()
        var changed = 0
        var notRun: [FormScript] = []
        for listed in calculationOrder {
            guard let source = FormScripts.sourceOf(self, listed, "C") else { continue }
            guard let calls = FormScriptParser.parse(source) else {
                notRun.append(FormScript(listed.name, "C", source, false))
                continue
            }
            for call in calls {
                guard let field = current(listed.dictionary), let result = FormFunctions.calculate(call, valuesOfFields) else { continue }
                if sameValue(field.value, result) { continue }
                guard let change = prepare(field, [result]) else { continue }
                try commit([change])
                changed += 1
            }
        }
        return FormCalculation(changed, notRun)
    }

    /// What the field's keystroke and validate scripts say about `value`: nil when it passes, else the sentence to show.
    /// Only built-in functions are checked.
    public func validate(_ field: FormField, _ value: String) -> String? {
        for evt in ["K", "V"] {
            guard let calls = FormScripts.callsOf(self, field, evt) else { continue }
            for call in calls {
                if let message = FormFunctions.check(call, value) { return message }
            }
        }
        return nil
    }

    /// The text the field shows: its value through the built-in format script, if it has one.
    public func displayText(_ field: FormField) -> String { displayOf(field).text }

    func current(_ dictionary: PdfDictionary) -> FormField? { byDictionary[ObjectIdentifier(dictionary)] }

    // A name stands for the field of that name and for the fields below it, as in Acrobat's calculations.
    private func valuesOfFields(_ name: String) -> [String?] {
        fields.filter { $0.name.equalsOrdinal(name) || $0.name.hasPrefixOrdinal(name + ".") }.map { $0.value }
    }

    private func sameValue(_ current: String?, _ result: String) -> Bool {
        if current == result { return true }
        if let a = FormFunctions.parseNumber(current ?? ""), let b = FormFunctions.parseNumber(result) { return a == b }
        return false
    }
}
